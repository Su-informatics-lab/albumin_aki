#!/usr/bin/env python3
"""Identify MIMIC-IV cardiac-surgery admissions for LLM extraction."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import pandas as pd

RESULTS = Path(
    os.environ.get("ALBUMIN_AKI_RESULTS", Path.home() / "albumin_aki" / "results")
)
MG_AKI = Path(os.environ.get("MG_AKI", Path.home() / "mg_aki"))
MIMIC_ROOT = Path(os.environ.get("MIMIC_ROOT", MG_AKI / "mimic-iv-3.1"))
NOTE_PATH = Path(
    os.environ.get(
        "MIMIC_NOTE_DISCHARGE",
        MG_AKI / "physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz",
    )
)
OUTPUT = RESULTS / "llm_cardiac_cohort.csv"
SUMMARY = RESULTS / "llm_cardiac_cohort_summary.json"

MIN_AGE = 18

ICD9_CARDIAC = [
    "3510",
    "3511",
    "3512",
    "3513",
    "3514",
    "3521",
    "3522",
    "3523",
    "3524",
    "3525",
    "3526",
    "3527",
    "3528",
    "3541",
    "3542",
    "3611",
    "3612",
    "3613",
    "3614",
    "3615",
    "3616",
    "3617",
    "3619",
    "3631",
    "3632",
    "3834",
    "3844",
    "3845",
    "3761",
]
ICD10_CARDIAC_PREFIX = ["02", "021"]


def resolve_csv(root: Path, table: str) -> Path:
    for suffix in (".csv.gz", ".csv"):
        path = root / f"{table}{suffix}"
        if path.exists():
            return path
    raise FileNotFoundError(f"{table}.csv[.gz] not found under {root}")


def normalize_code(series: pd.Series) -> pd.Series:
    return series.astype(str).str.strip().str.upper().str.replace(".", "", regex=False)


def startswith_any(series: pd.Series, prefixes: list[str]) -> pd.Series:
    cleaned = normalize_code(series)
    prefixes = [prefix.upper().replace(".", "") for prefix in prefixes]
    return cleaned.str.startswith(tuple(prefixes), na=False)


def load_discharge_note_index(note_path: Path) -> pd.DataFrame:
    """Return one discharge-note metadata row per hadm_id.

    MIMIC can contain addenda. Prefer the highest note_seq and latest charttime
    so extraction uses the most complete discharge summary.
    """

    usecols = ["note_id", "subject_id", "hadm_id", "note_seq", "charttime", "storetime"]
    notes = pd.read_csv(note_path, usecols=usecols, low_memory=False)
    notes = notes.dropna(subset=["hadm_id"]).copy()
    notes["hadm_id"] = pd.to_numeric(notes["hadm_id"], errors="coerce")
    notes = notes.dropna(subset=["hadm_id"]).copy()
    notes["hadm_id"] = notes["hadm_id"].astype(int)
    notes["note_seq"] = pd.to_numeric(notes["note_seq"], errors="coerce").fillna(0)
    notes["charttime"] = pd.to_datetime(notes["charttime"], errors="coerce")
    notes["storetime"] = pd.to_datetime(notes["storetime"], errors="coerce")
    notes = notes.sort_values(["hadm_id", "note_seq", "charttime", "storetime"])
    return notes.groupby("hadm_id", as_index=False).tail(1)


def build_cohort(
    mimic_root: Path, note_path: Path
) -> tuple[pd.DataFrame, dict[str, object]]:
    hosp = mimic_root / "hosp"
    icu = mimic_root / "icu"

    procedures = pd.read_csv(
        resolve_csv(hosp, "procedures_icd"),
        usecols=["subject_id", "hadm_id", "icd_code", "icd_version"],
        low_memory=False,
    )
    procedures = procedures.dropna(subset=["hadm_id"]).copy()
    procedures["hadm_id"] = procedures["hadm_id"].astype(int)
    procedures["icd_version"] = pd.to_numeric(
        procedures["icd_version"], errors="coerce"
    )
    procedures["icd_code_norm"] = normalize_code(procedures["icd_code"])

    mask9 = (procedures["icd_version"] == 9) & startswith_any(
        procedures["icd_code_norm"], ICD9_CARDIAC
    )
    mask10 = (procedures["icd_version"] == 10) & startswith_any(
        procedures["icd_code_norm"], ICD10_CARDIAC_PREFIX
    )
    cardiac_px = procedures[mask9 | mask10].copy()
    cardiac_hadms = set(cardiac_px["hadm_id"].astype(int))

    icustays = pd.read_csv(
        resolve_csv(icu, "icustays"),
        usecols=[
            "subject_id",
            "hadm_id",
            "stay_id",
            "intime",
            "outtime",
            "first_careunit",
            "last_careunit",
        ],
        low_memory=False,
    )
    icustays = icustays.dropna(subset=["hadm_id", "stay_id"]).copy()
    icustays["hadm_id"] = icustays["hadm_id"].astype(int)
    icustays["stay_id"] = icustays["stay_id"].astype(int)
    icustays["intime"] = pd.to_datetime(icustays["intime"], errors="coerce")
    icustays["outtime"] = pd.to_datetime(icustays["outtime"], errors="coerce")
    first_stay = (
        icustays.sort_values(["hadm_id", "intime"])
        .groupby("hadm_id", as_index=False)
        .first()
    )

    patients = pd.read_csv(
        resolve_csv(hosp, "patients"),
        usecols=["subject_id", "gender", "anchor_age"],
        low_memory=False,
    )

    notes = load_discharge_note_index(note_path)

    cohort = pd.DataFrame({"hadm_id": sorted(cardiac_hadms)})
    cohort = cohort.merge(first_stay, on="hadm_id", how="inner", suffixes=("", "_icu"))
    cohort = cohort.merge(patients, on="subject_id", how="left")
    cohort = cohort[cohort["anchor_age"].fillna(-1) >= MIN_AGE].copy()
    cohort = cohort.merge(
        notes[["hadm_id", "note_id", "note_seq", "charttime", "storetime"]],
        on="hadm_id",
        how="inner",
    )

    cohort = cohort.rename(columns={"stay_id": "pid", "anchor_age": "age"})
    cohort["is_female"] = (cohort["gender"] == "F").astype(int)

    code_summary = (
        cardiac_px.groupby("hadm_id")["icd_code_norm"]
        .apply(lambda codes: ";".join(sorted(set(codes))))
        .reset_index()
        .rename(columns={"icd_code_norm": "cardiac_procedure_codes"})
    )
    cohort = cohort.merge(code_summary, on="hadm_id", how="left")

    keep = [
        "hadm_id",
        "pid",
        "subject_id",
        "note_id",
        "note_seq",
        "charttime",
        "storetime",
        "age",
        "gender",
        "is_female",
        "intime",
        "outtime",
        "first_careunit",
        "last_careunit",
        "cardiac_procedure_codes",
    ]
    cohort = cohort[keep].sort_values(["subject_id", "hadm_id"]).reset_index(drop=True)

    summary = {
        "mimic_root": str(mimic_root),
        "note_path": str(note_path),
        "cardiac_hadms_from_procedures": len(cardiac_hadms),
        "cardiac_hadms_with_icu_stay": int(
            len(
                pd.DataFrame({"hadm_id": sorted(cardiac_hadms)}).merge(
                    first_stay, on="hadm_id", how="inner"
                )
            )
        ),
        "adult_cardiac_hadms_with_discharge_note": int(len(cohort)),
        "unique_subjects": int(cohort["subject_id"].nunique()),
        "icd9_prefixes": ICD9_CARDIAC,
        "icd10_prefixes": ICD10_CARDIAC_PREFIX,
    }
    return cohort, summary


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build all cardiac-surgery MIMIC-IV hadm_ids for LLM extraction."
    )
    parser.add_argument("--mimic-root", type=Path, default=MIMIC_ROOT)
    parser.add_argument("--note-path", type=Path, default=NOTE_PATH)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--summary", type=Path, default=SUMMARY)
    args = parser.parse_args()

    cohort, summary = build_cohort(args.mimic_root, args.note_path)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    cohort.to_csv(args.output, index=False)
    args.summary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

    print(f"cardiac surgery hadm_ids with notes: {len(cohort):,}")
    print(f"unique subjects: {cohort.subject_id.nunique():,}")
    print(f"output: {args.output}")
    print(f"summary: {args.summary}")


if __name__ == "__main__":
    main()
