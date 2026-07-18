#!/usr/bin/env python
"""
10_nlp.py -- LLM-based NLP endpoint extraction from MIMIC-IV-Note discharge summaries.

Uses CatChat (OpenAI-compatible API) to extract clinical endpoints from the
"Brief Hospital Course" section of discharge summaries.

Endpoints extracted (all as binary flags):
  - return_to_or        : reoperation / resternotomy for bleeding
  - reintubation        : reintubation after initial extubation
  - pneumonia           : new pneumonia or VAP
  - sternal_wound_inf   : sternal wound infection / mediastinitis
  - sepsis              : new sepsis or septic shock
  - cardiac_arrest      : cardiac arrest or CPR

Features:
  - Section extraction (Brief Hospital Course) to reduce token usage
  - Checkpoint/resume: saves every BATCH_SIZE notes; safe to Ctrl-C and restart
  - Configurable rate limiting
  - Structured JSON output from LLM

Usage (Tempest or local with internet):
  export CATCHAT_API_KEY="sk-..."          # your CatChat API key
  export CATCHAT_MODEL="gpt-4o-mini"       # or whatever model is available
  python 10_nlp.py                         # full run with resume
  python 10_nlp.py --dry-run               # test with 5 notes, print results
"""

import argparse
import json
import os
import re
import sys
import time

import numpy as np
import pandas as pd

RESULTS = os.path.expanduser("~/albumin_aki/results")
NOTE_PATH = os.path.expanduser(
    "~/mg_aki/physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz"
)
CHECKPOINT = os.path.join(RESULTS, "_nlp_checkpoint.csv")
OUTPUT = os.path.join(RESULTS, "nlp_endpoints_mimic.csv")

API_URL = os.environ.get(
    "CATCHAT_URL", "https://catchat-api.msu.montana.edu/v1/chat/completions"
)
API_KEY = os.environ.get("CATCHAT_API_KEY", "")
MODEL = os.environ.get("CATCHAT_MODEL", "gpt-4o-mini")
BATCH_SIZE = 50  # save checkpoint every N notes
DELAY = 0.5  # seconds between API calls
MAX_RETRIES = 3
TIMEOUT = 60

ENDPOINTS = [
    "return_to_or",
    "reintubation",
    "pneumonia",
    "sternal_wound_inf",
    "sepsis",
    "cardiac_arrest",
]

SYSTEM_PROMPT = """You are a clinical data abstractor reviewing cardiac surgery ICU discharge summaries.

For each note, determine whether the following postoperative complications occurred during THIS hospitalization (not pre-existing or historical). Respond ONLY with a JSON object, no other text.

{
  "return_to_or": 0 or 1,
  "reintubation": 0 or 1,
  "pneumonia": 0 or 1,
  "sternal_wound_inf": 0 or 1,
  "sepsis": 0 or 1,
  "cardiac_arrest": 0 or 1
}

Definitions:
- return_to_or: Patient was taken back to the operating room for bleeding, tamponade, or surgical re-exploration after the initial cardiac surgery. Do NOT count planned staged procedures.
- reintubation: Patient was reintubated after being initially extubated. Do NOT count the initial postoperative intubation.
- pneumonia: New pneumonia or ventilator-associated pneumonia (VAP) diagnosed during this ICU stay. Do NOT count pre-existing pneumonia.
- sternal_wound_inf: Sternal wound infection, mediastinitis, or deep surgical site infection. Do NOT count superficial redness.
- sepsis: New sepsis or septic shock during this hospitalization. Do NOT count the initial postoperative inflammatory response or SIRS from surgery.
- cardiac_arrest: Cardiac arrest requiring CPR or code blue during this hospitalization. Do NOT count intraoperative events.

If the note does not mention a complication, code it as 0. When uncertain, code 0."""

# ── Section extraction ────────────────────────────────────────────
SECTION_PAT = re.compile(
    r"^([A-Z][A-Z &/\-]{4,}):?\s*$|"
    r"^(Brief Hospital Course|HOSPITAL COURSE|BRIEF HOSPITAL COURSE)\s*:?\s*$",
    re.MULTILINE | re.IGNORECASE,
)


def extract_bhc(text):
    """Extract 'Brief Hospital Course' or similar section."""
    sections = {}
    starts = [
        (m.start(), m.group().strip().rstrip(":").strip())
        for m in SECTION_PAT.finditer(text)
    ]
    for i, (pos, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        sections[name.lower()] = text[pos:end]
    for key in ["brief hospital course", "hospital course"]:
        if key in sections:
            return sections[key][:6000]  # cap at ~1500 tokens
    # fallback: return last 60% of note (course is usually toward the end)
    return text[len(text) * 2 // 5 :][:6000]


# ── LLM call ──────────────────────────────────────────────────────
def call_llm(note_text):
    """Send note to CatChat, return dict of endpoint flags."""
    import urllib.error
    import urllib.request

    body = json.dumps(
        {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": f"Discharge summary excerpt:\n\n{note_text}",
                },
            ],
            "temperature": 0.0,
            "max_tokens": 200,
        }
    ).encode("utf-8")

    headers = {"Content-Type": "application/json"}
    if API_KEY:
        headers["Authorization"] = f"Bearer {API_KEY}"

    req = urllib.request.Request(API_URL, data=body, headers=headers, method="POST")

    for attempt in range(MAX_RETRIES):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            content = data["choices"][0]["message"]["content"].strip()
            # strip markdown fences if present
            content = re.sub(r"^```(?:json)?\s*", "", content)
            content = re.sub(r"\s*```$", "", content)
            result = json.loads(content)
            return {ep: int(result.get(ep, 0)) for ep in ENDPOINTS}
        except (urllib.error.URLError, json.JSONDecodeError, KeyError, ValueError) as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(2**attempt)
            else:
                print(f"      FAILED after {MAX_RETRIES} attempts: {e}")
                return {ep: -1 for ep in ENDPOINTS}  # -1 = extraction failed
    return {ep: -1 for ep in ENDPOINTS}


# ── Main ──────────────────────────────────────────────────────────
def run(dry_run=False):
    print("=" * 74)
    print("  10_nlp -- LLM endpoint extraction (CatChat)")
    print("=" * 74)
    print(f"  API: {API_URL}")
    print(f"  Model: {MODEL}")
    print(f"  Key: {'set' if API_KEY else 'NOT SET (will fail)'}")

    # load cohort
    d = pd.read_csv(os.path.join(RESULTS, "did_all_mimic.csv"), low_memory=False)
    icu = pd.read_csv(
        os.path.join(
            os.path.expanduser("~/mg_aki/mimic-iv-3.1/icu"), "icustays.csv.gz"
        ),
        usecols=["stay_id", "hadm_id"],
    )
    icu = icu[icu.stay_id.isin(set(d.pid))].copy()
    target_hadms = set(icu.hadm_id.astype(int))
    hadm2stay = dict(zip(icu.hadm_id, icu.stay_id))
    print(f"  cohort hadm_ids: {len(target_hadms):,}")

    # load discharge notes
    print("  loading discharge notes ...")
    notes = pd.read_csv(NOTE_PATH, usecols=["hadm_id", "text"], low_memory=False)
    notes = notes[notes.hadm_id.isin(target_hadms)].copy()
    notes = notes.drop_duplicates("hadm_id")  # one note per admission
    print(f"  matched notes: {len(notes):,} / {len(target_hadms):,} hadm_ids")

    # load checkpoint
    done = set()
    if os.path.exists(CHECKPOINT) and not dry_run:
        ck = pd.read_csv(CHECKPOINT)
        done = set(ck.hadm_id)
        print(f"  checkpoint: {len(done):,} already processed")

    todo = notes[~notes.hadm_id.isin(done)]
    if dry_run:
        todo = todo.head(5)
    print(f"  to process: {len(todo):,}")

    if not API_KEY:
        sys.exit("  ERROR: set CATCHAT_API_KEY environment variable")

    # process
    results = []
    for i, row in enumerate(todo.itertuples()):
        bhc = extract_bhc(str(row.text))
        flags = call_llm(bhc)
        flags["hadm_id"] = int(row.hadm_id)
        flags["pid"] = hadm2stay.get(row.hadm_id, np.nan)
        results.append(flags)

        if (i + 1) % 10 == 0 or dry_run:
            print(
                f"    [{i+1}/{len(todo)}] hadm={row.hadm_id}  "
                + "  ".join(f"{k}={v}" for k, v in flags.items() if k in ENDPOINTS)
            )

        # checkpoint
        if (i + 1) % BATCH_SIZE == 0 and not dry_run:
            _flush(results, done)
            results = []

        time.sleep(DELAY)

    # final flush
    if results:
        _flush(results, done)

    # assemble final output
    if os.path.exists(CHECKPOINT):
        final = pd.read_csv(CHECKPOINT)
        final.to_csv(OUTPUT, index=False)
        print(f"\n  -> {OUTPUT}  rows={len(final):,}")
        for ep in ENDPOINTS:
            pos = (final[ep] == 1).sum()
            fail = (final[ep] == -1).sum()
            print(
                f"     {ep:<20} positive={pos:>5} ({100*pos/len(final):.1f}%)  "
                f"failed={fail}"
            )
    print("\nDONE.")


def _flush(results, done):
    """Append batch to checkpoint CSV."""
    batch = pd.DataFrame(results)
    if os.path.exists(CHECKPOINT):
        existing = pd.read_csv(CHECKPOINT)
        batch = pd.concat([existing, batch], ignore_index=True)
    batch.to_csv(CHECKPOINT, index=False)
    done.update(batch.hadm_id)
    print(f"    [checkpoint] {len(batch):,} total saved")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Test with 5 notes")
    args = parser.parse_args()
    run(dry_run=args.dry_run)
