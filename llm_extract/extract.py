#!/usr/bin/env python3
"""LLM endpoint extraction from MIMIC-IV discharge summaries via CatChat."""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional, Sequence

import pandas as pd
from pydantic import ValidationError

try:
    from .schema import (
        ENDPOINTS,
        CardiacSurgeryEndpoints,
        Confidence,
        build_format_instructions,
    )
except ImportError:  # pragma: no cover - direct script execution
    from schema import (
        ENDPOINTS,
        CardiacSurgeryEndpoints,
        Confidence,
        build_format_instructions,
    )


logger = logging.getLogger("albumin_aki_llm")

RESULTS = Path(
    os.environ.get("ALBUMIN_AKI_RESULTS", Path.home() / "albumin_aki" / "results")
)
MG_AKI = Path(os.environ.get("MG_AKI", Path.home() / "mg_aki"))
NOTE_PATH = Path(
    os.environ.get(
        "MIMIC_NOTE_DISCHARGE",
        MG_AKI / "physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz",
    )
)
COHORT_PATH = RESULTS / "llm_cardiac_cohort.csv"
CHECKPOINT_PATH = RESULTS / "_llm_checkpoint.csv"
OUTPUT_PATH = RESULTS / "llm_endpoints_mimic.csv"

DEFAULT_CHAT_URL = os.environ.get(
    "CATCHAT_URL", "https://catchat-api.msu.montana.edu/v1/chat/completions"
)
DEFAULT_MODEL = os.environ.get("CATCHAT_MODEL", "gpt-oss:120b")
BATCH_SIZE = 50

SECTION_RE = re.compile(
    r"^([A-Z][A-Z &/\-]{4,}):?\s*$|"
    r"^(Brief Hospital Course|HOSPITAL COURSE|BRIEF HOSPITAL COURSE|Course of Hospitalization)\s*:?\s*$",
    re.MULTILINE | re.IGNORECASE,
)

SYSTEM_PROMPT = """\
You are a clinical data abstractor reviewing cardiac surgery ICU discharge
summaries from MIMIC-IV. For each note, determine whether the listed
postoperative complications occurred during THIS hospitalization.

CRITICAL RULES:
1. Only code events that ACTUALLY HAPPENED, not differential diagnoses or
   ruled-out conditions.
2. Pre-existing conditions such as chronic AF or baseline CHF are NOT
   postoperative events.
3. Expected postoperative course, such as initial intubation after surgery, is
   NOT a complication.
4. When uncertain, code the endpoint value as 0 and use low confidence.
5. Do not infer events from labs or medications unless the note text documents
   the clinical event.

{format_instructions}
"""

USER_PROMPT = "Discharge summary excerpt:\n\n{note_text}"


def normalize_chat_url(url: str) -> tuple[str, str]:
    trimmed = url.rstrip("/")
    if trimmed.endswith("/chat/completions"):
        chat_url = trimmed
        models_url = trimmed[: -len("/chat/completions")] + "/models"
        return chat_url, models_url
    if not trimmed.endswith("/v1"):
        trimmed += "/v1"
    return f"{trimmed}/chat/completions", f"{trimmed}/models"


class CatChatClient:
    def __init__(
        self,
        *,
        chat_url: str,
        model: str,
        api_key: Optional[str],
        timeout: int = 600,
        response_format: bool = True,
    ):
        self.chat_url, self.models_url = normalize_chat_url(chat_url)
        self.model = model
        self.api_key = api_key
        self.timeout = timeout
        self.response_format = response_format

    def headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _post(self, payload: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            self.chat_url,
            data=json.dumps(payload).encode("utf-8"),
            headers=self.headers(),
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"HTTP {exc.code} from {self.chat_url}: {body[:1000]}"
            ) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Cannot reach {self.chat_url}: {exc}") from exc

    def generate(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int = 2048,
        temperature: float = 0.0,
    ) -> str:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": list(messages),
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        if self.response_format:
            payload["response_format"] = {"type": "json_object"}
        try:
            response = self._post(payload)
        except RuntimeError:
            if not self.response_format:
                raise
            payload.pop("response_format", None)
            response = self._post(payload)

        content = response["choices"][0]["message"]["content"]
        if isinstance(content, list):
            return "\n".join(
                item.get("text", str(item)) if isinstance(item, dict) else str(item)
                for item in content
            ).strip()
        return str(content).strip()

    def check_models(self) -> list[str]:
        request = urllib.request.Request(self.models_url, headers=self.headers())
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                data = json.loads(response.read().decode("utf-8"))
            return [str(item.get("id", "?")) for item in data.get("data", [])]
        except Exception as exc:
            logger.warning("could not query models endpoint: %s", exc)
            return []


def strip_json_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```json"):
        text = text[7:]
    elif text.startswith("```"):
        text = text[3:]
    if text.endswith("```"):
        text = text[:-3]
    return text.strip()


def maybe_extract_json(text: str) -> str:
    text = strip_json_fences(text)
    if text.startswith("{") and text.endswith("}"):
        return text
    start, end = text.find("{"), text.rfind("}")
    if start != -1 and end > start:
        return text[start : end + 1]
    return text


def extract_bhc(text: str, max_chars: int = 6000) -> str:
    sections: dict[str, str] = {}
    starts = [
        (match.start(), match.group().strip().rstrip(":").strip())
        for match in SECTION_RE.finditer(text)
    ]
    for i, (pos, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        sections[name.lower()] = text[pos:end]
    for key in (
        "brief hospital course",
        "hospital course",
        "course of hospitalization",
    ):
        if key in sections:
            return sections[key][:max_chars]
    return text[len(text) * 2 // 5 :][:max_chars]


def extract_one(
    note_text: str,
    client: CatChatClient,
    *,
    max_retries: int = 3,
    max_tokens: int = 2048,
) -> CardiacSurgeryEndpoints:
    format_instructions = build_format_instructions(CardiacSurgeryEndpoints)
    base_messages = [
        {
            "role": "system",
            "content": SYSTEM_PROMPT.format(format_instructions=format_instructions),
        },
        {"role": "user", "content": USER_PROMPT.format(note_text=note_text)},
    ]
    messages = list(base_messages)
    last_error: Exception | None = None

    for _attempt in range(1, max_retries + 1):
        raw = client.generate(messages, max_tokens=max_tokens, temperature=0.0)
        try:
            payload = json.loads(maybe_extract_json(raw))
        except json.JSONDecodeError as exc:
            last_error = exc
            messages = list(base_messages) + [
                {"role": "assistant", "content": raw},
                {
                    "role": "user",
                    "content": f"Invalid JSON: {exc}. Return corrected JSON only.",
                },
            ]
            continue

        try:
            return CardiacSurgeryEndpoints.model_validate(payload)
        except ValidationError as exc:
            last_error = exc
            messages = list(base_messages) + [
                {"role": "assistant", "content": raw},
                {
                    "role": "user",
                    "content": f"Schema validation failed:\n{exc}\n\nFix and return corrected JSON only.",
                },
            ]
            continue

    if last_error is None:
        raise RuntimeError("extraction failed without a captured error")
    raise last_error


def load_cohort(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found. Run python -m llm_extract.cardiac_cohort first."
        )
    cohort = pd.read_csv(path, dtype={"hadm_id": str, "pid": str, "note_id": str})
    cohort["hadm_id"] = cohort["hadm_id"].astype(str)
    return cohort


def load_checkpoint(path: Path) -> pd.DataFrame:
    if path.exists():
        return pd.read_csv(path, dtype={"hadm_id": str, "pid": str})
    return pd.DataFrame()


def load_done(path: Path) -> set[str]:
    checkpoint = load_checkpoint(path)
    if checkpoint.empty or "hadm_id" not in checkpoint.columns:
        return set()
    return set(checkpoint["hadm_id"].astype(str))


def stream_note_text(
    note_path: Path, target_hadms: set[str], note_ids: set[str] | None = None
):
    opener = gzip.open if note_path.suffix == ".gz" else open
    seen: set[str] = set()
    with opener(
        note_path, "rt", encoding="utf-8", errors="replace", newline=""
    ) as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            hadm_id = str(row.get("hadm_id", "")).strip()
            note_id = str(row.get("note_id", "")).strip()
            if hadm_id not in target_hadms or hadm_id in seen:
                continue
            if note_ids and note_id not in note_ids:
                continue
            seen.add(hadm_id)
            yield hadm_id, row.get("text", "")


def failed_row(meta: pd.Series, error: str) -> dict[str, Any]:
    row: dict[str, Any] = {
        "hadm_id": str(meta["hadm_id"]),
        "pid": str(meta["pid"]),
        "note_id": meta.get("note_id", ""),
        "resternotomy_reason": "none",
        "confidence": Confidence.low.value,
        "extraction_note": f"EXTRACTION_FAILED: {error}",
    }
    for endpoint in ENDPOINTS:
        row[endpoint] = -1
        row[f"{endpoint}_confidence"] = Confidence.low.value
        row[f"{endpoint}_evidence"] = ""
    return row


def flatten_result(meta: pd.Series, result: CardiacSurgeryEndpoints) -> dict[str, Any]:
    data = result.model_dump(mode="json")
    row: dict[str, Any] = {
        "hadm_id": str(meta["hadm_id"]),
        "pid": str(meta["pid"]),
        "note_id": meta.get("note_id", ""),
        "resternotomy_reason": data["resternotomy_reason"],
        "confidence": data["confidence"],
        "extraction_note": data.get("extraction_note", ""),
    }
    for endpoint in ENDPOINTS:
        ep = data[endpoint]
        row[endpoint] = int(ep["value"])
        row[f"{endpoint}_confidence"] = ep["confidence"]
        row[f"{endpoint}_evidence"] = ep.get("evidence") or ""
    return row


def checkpoint_columns() -> list[str]:
    columns = ["hadm_id", "pid", *ENDPOINTS, "confidence"]
    columns.extend(["note_id", "resternotomy_reason", "extraction_note"])
    for endpoint in ENDPOINTS:
        columns.extend([f"{endpoint}_confidence", f"{endpoint}_evidence"])
    return columns


def write_checkpoint(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(rows)
    if path.exists():
        existing = pd.read_csv(path, dtype={"hadm_id": str, "pid": str})
        df = pd.concat([existing, df], ignore_index=True)
    df["hadm_id"] = df["hadm_id"].astype(str)
    df = df.drop_duplicates("hadm_id", keep="last")
    for column in checkpoint_columns():
        if column not in df.columns:
            df[column] = ""
    df[checkpoint_columns()].to_csv(path, index=False)


def write_final_output(
    cohort: pd.DataFrame, checkpoint_path: Path, output_path: Path
) -> None:
    checkpoint = load_checkpoint(checkpoint_path)
    if checkpoint.empty:
        final = cohort[["hadm_id", "pid", "note_id"]].copy()
    else:
        final = cohort[["hadm_id", "pid", "note_id"]].merge(
            checkpoint.drop(columns=["pid", "note_id"], errors="ignore"),
            on="hadm_id",
            how="left",
        )
    for endpoint in ENDPOINTS:
        if endpoint not in final.columns:
            final[endpoint] = -1
        final[endpoint] = final[endpoint].fillna(-1).astype(int)
        conf_col = f"{endpoint}_confidence"
        evid_col = f"{endpoint}_evidence"
        if conf_col not in final.columns:
            final[conf_col] = ""
        if evid_col not in final.columns:
            final[evid_col] = ""
    if "confidence" not in final.columns:
        final["confidence"] = ""
    final["confidence"] = final["confidence"].fillna(Confidence.low.value)
    if "resternotomy_reason" not in final.columns:
        final["resternotomy_reason"] = ""
    final["resternotomy_reason"] = final["resternotomy_reason"].fillna("none")
    if "extraction_note" not in final.columns:
        final["extraction_note"] = ""
    final["extraction_note"] = final["extraction_note"].fillna("NOT_PROCESSED")

    ordered = checkpoint_columns()
    for column in ordered:
        if column not in final.columns:
            final[column] = ""
    final[ordered].to_csv(output_path, index=False)
    n_failed = int((final[ENDPOINTS] == -1).any(axis=1).sum())
    print(
        f"final output: {output_path} rows={len(final):,} failed_or_missing={n_failed:,}"
    )


def run(args: argparse.Namespace) -> None:
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    cohort = load_cohort(args.cohort)
    done = set() if args.dry_run else load_done(args.checkpoint)
    todo = cohort[~cohort["hadm_id"].isin(done)].copy()
    if args.dry_run:
        todo = todo.head(args.n or 5)
    elif args.n is not None:
        todo = todo.head(args.n)

    print(f"cohort rows: {len(cohort):,}")
    print(f"already processed: {len(done):,}")
    print(f"to process: {len(todo):,}")

    if todo.empty:
        write_final_output(cohort, args.checkpoint, args.output)
        return

    if not args.api_key:
        sys.exit("ERROR: set CATCHAT_API_KEY or pass --api-key")

    client = CatChatClient(
        chat_url=args.url,
        model=args.model,
        api_key=args.api_key,
        timeout=args.timeout,
        response_format=not args.no_response_format,
    )
    if not args.skip_model_check:
        models = client.check_models()
        print(f"api: {client.chat_url}")
        print(f"model: {args.model}")
        if models:
            print(f"available models: {models}")
            if args.model not in models:
                print(f"WARNING: {args.model!r} not listed by /models")

    meta_by_hadm = {str(row.hadm_id): row for row in todo.itertuples(index=False)}
    target_hadms = set(meta_by_hadm)
    note_ids = set(todo["note_id"].astype(str)) if "note_id" in todo.columns else None
    batch: list[dict[str, Any]] = []
    processed = 0
    ok = 0
    failed = 0
    t0 = time.time()

    for hadm_id, full_text in stream_note_text(args.note_path, target_hadms, note_ids):
        meta = pd.Series(meta_by_hadm[hadm_id]._asdict())
        bhc = extract_bhc(full_text, max_chars=args.max_chars)
        try:
            result = extract_one(
                bhc,
                client,
                max_retries=args.max_retries,
                max_tokens=args.max_tokens,
            )
            row = flatten_result(meta, result)
            ok += 1
        except Exception as exc:
            logger.error("failed hadm_id=%s: %s", hadm_id, exc)
            row = failed_row(meta, str(exc))
            failed += 1

        processed += 1
        batch.append(row)

        if args.dry_run:
            print(json.dumps(row, ensure_ascii=False, indent=2))
        elif len(batch) >= args.batch_size:
            write_checkpoint(args.checkpoint, batch)
            batch = []

        if processed % 10 == 0 or processed == len(todo):
            elapsed = max(time.time() - t0, 1.0)
            print(
                f"{processed}/{len(todo)} ok={ok} failed={failed} "
                f"rate={processed / elapsed * 60:.1f}/min"
            )
        if args.delay > 0:
            time.sleep(args.delay)

    missing = target_hadms - set(str(row["hadm_id"]) for row in batch)
    if not args.dry_run:
        if batch:
            write_checkpoint(args.checkpoint, batch)
        write_final_output(cohort, args.checkpoint, args.output)
    elif missing:
        print(f"dry run note stream did not find {len(missing)} requested notes")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract albumin_aki cardiac-surgery endpoints with CatChat."
    )
    parser.add_argument("--cohort", type=Path, default=COHORT_PATH)
    parser.add_argument("--note-path", type=Path, default=NOTE_PATH)
    parser.add_argument("--checkpoint", type=Path, default=CHECKPOINT_PATH)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    parser.add_argument("--url", default=DEFAULT_CHAT_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--api-key", default=os.environ.get("CATCHAT_API_KEY"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--n", type=int, default=None, help="Limit number of notes.")
    parser.add_argument("--batch-size", type=int, default=BATCH_SIZE)
    parser.add_argument("--delay", type=float, default=0.5)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--max-retries", type=int, default=3)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--max-chars", type=int, default=6000)
    parser.add_argument("--skip-model-check", action="store_true")
    parser.add_argument("--no-response-format", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--workers",
        type=int,
        default=1,
        help="Accepted for CLI compatibility; extraction runs sequentially for CSV checkpoint safety.",
    )
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
