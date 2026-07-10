#!/usr/bin/env python3
"""Validation and QC reports for albumin_aki LLM endpoint extraction."""

from __future__ import annotations

import argparse
import csv
import gzip
import os
import textwrap
from pathlib import Path
from typing import Any

import pandas as pd

try:
    from .extract import extract_bhc
    from .schema import ENDPOINTS
except ImportError:  # pragma: no cover - direct script execution
    from extract import extract_bhc
    from schema import ENDPOINTS


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
LLM_OUTPUT = RESULTS / "llm_endpoints_mimic.csv"
DX_INFECTION = RESULTS / "dx_infection_mimic.csv"
CONCORDANCE_REPORT = RESULTS / "llm_qc_concordance.txt"
SPOTCHECK_REPORT = RESULTS / "llm_qc_spotcheck.txt"

ICD_LLM_MAP = [
    ("pneumonia / VAP", "pneumonia_vap", "pneumonia_vap"),
    ("sepsis", "sepsis", "sepsis"),
    ("SSI / mediastinitis", "ssi_mediastinitis", "sternal_wound_inf"),
]

DEFAULT_SPOTCHECK_ENDPOINTS = [
    "return_to_or",
    "reintubation",
    "pneumonia_vap",
    "sepsis",
    "sternal_wound_inf",
    "cardiac_arrest",
]


def clean_id(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    return text[:-2] if text.endswith(".0") else text


def safe_rate(num: float, den: float) -> float:
    return float(num) / float(den) if den else float("nan")


def kappa_from_counts(tp: int, fp: int, fn: int, tn: int) -> float:
    total = tp + fp + fn + tn
    if total == 0:
        return float("nan")
    po = (tp + tn) / total
    p_yes_a = (tp + fn) / total
    p_yes_b = (tp + fp) / total
    p_no_a = (fp + tn) / total
    p_no_b = (fn + tn) / total
    pe = p_yes_a * p_yes_b + p_no_a * p_no_b
    if pe == 1:
        return float("nan")
    return (po - pe) / (1 - pe)


def format_pct(value: float) -> str:
    if pd.isna(value):
        return "NA"
    return f"{100 * value:.1f}%"


def load_llm(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found. Run python -m llm_extract.extract first."
        )
    df = pd.read_csv(path, dtype={"hadm_id": str, "pid": str, "note_id": str})
    df["hadm_id"] = df["hadm_id"].map(clean_id)
    df["pid"] = df["pid"].map(clean_id)
    for endpoint in ENDPOINTS:
        if endpoint not in df.columns:
            raise ValueError(f"missing required LLM column: {endpoint}")
        df[endpoint] = (
            pd.to_numeric(df[endpoint], errors="coerce").fillna(-1).astype(int)
        )
    return df


def concordance_lines(llm: pd.DataFrame, dx_path: Path) -> list[str]:
    lines = ["ICD vs LLM concordance", "=" * 22, ""]
    if not dx_path.exists():
        lines.extend(
            [
                f"SKIPPED: {dx_path} not found.",
                "Run python 01c_endpoints.py before validation to generate ICD infection endpoints.",
                "",
            ]
        )
        return lines

    dx = pd.read_csv(dx_path, dtype={"pid": str})
    dx["pid"] = dx["pid"].map(clean_id)
    if "dx_name" not in dx.columns:
        lines.append("SKIPPED: dx_infection_mimic.csv has no dx_name column.")
        return lines

    for label, dx_name, llm_col in ICD_LLM_MAP:
        valid = llm[llm[llm_col].isin([0, 1])].copy()
        icd_positive = set(dx.loc[dx["dx_name"] == dx_name, "pid"])
        valid["icd"] = valid["pid"].isin(icd_positive).astype(int)

        tp = int(((valid["icd"] == 1) & (valid[llm_col] == 1)).sum())
        fp = int(((valid["icd"] == 0) & (valid[llm_col] == 1)).sum())
        fn = int(((valid["icd"] == 1) & (valid[llm_col] == 0)).sum())
        tn = int(((valid["icd"] == 0) & (valid[llm_col] == 0)).sum())
        sensitivity = safe_rate(tp, tp + fn)
        specificity = safe_rate(tn, tn + fp)
        kappa = kappa_from_counts(tp, fp, fn, tn)

        lines.extend(
            [
                f"{label}: ICD dx_name={dx_name!r}, LLM column={llm_col}",
                f"  n compared: {len(valid):,}",
                "  2x2 table (rows=ICD, columns=LLM):",
                f"                  LLM+      LLM-",
                f"    ICD+     {tp:8d}  {fn:8d}",
                f"    ICD-     {fp:8d}  {tn:8d}",
                f"  sensitivity: {format_pct(sensitivity)}",
                f"  specificity: {format_pct(specificity)}",
                (
                    f"  Cohen kappa: {kappa:.3f}"
                    if not pd.isna(kappa)
                    else "  Cohen kappa: NA"
                ),
                "",
            ]
        )
    return lines


def confidence_lines(llm: pd.DataFrame) -> list[str]:
    lines = ["Confidence distribution", "=" * 23, ""]
    if "confidence" in llm.columns:
        lines.append("Overall confidence:")
        counts = llm["confidence"].fillna("").value_counts(dropna=False)
        for label, count in counts.items():
            lines.append(f"  {label or 'missing'}: {count:,}")
        lines.append("")

    lines.append("Endpoint confidence:")
    for endpoint in ENDPOINTS:
        conf_col = f"{endpoint}_confidence"
        if conf_col not in llm.columns:
            lines.append(f"  {endpoint}: no endpoint confidence column")
            continue
        valid = llm[llm[endpoint].isin([0, 1])]
        counts = valid[conf_col].fillna("").value_counts(dropna=False).to_dict()
        low = int(counts.get("low", 0))
        low_rate = safe_rate(low, len(valid))
        flag = " FLAG_LOW_CONFIDENCE" if low_rate > 0.20 else ""
        parts = ", ".join(
            f"{key or 'missing'}={value}" for key, value in sorted(counts.items())
        )
        lines.append(f"  {endpoint}: {parts}; low={format_pct(low_rate)}{flag}")
    lines.append("")

    failed_rows = int((llm[ENDPOINTS] == -1).any(axis=1).sum())
    lines.append(
        f"Rows with any -1 failed/missing endpoint: {failed_rows:,} / {len(llm):,}"
    )
    lines.append("")
    return lines


def choose_spotcheck_rows(
    llm: pd.DataFrame,
    endpoints: list[str],
    n_each: int,
    random_state: int,
) -> pd.DataFrame:
    rows = []
    for endpoint in endpoints:
        if endpoint not in llm.columns:
            continue
        positives = llm[llm[endpoint] == 1]
        negatives = llm[llm[endpoint] == 0]
        if len(positives) > 0:
            rows.append(
                positives.sample(
                    min(n_each, len(positives)), random_state=random_state
                ).assign(
                    spotcheck_endpoint=endpoint,
                    spotcheck_label="positive",
                )
            )
        if len(negatives) > 0:
            rows.append(
                negatives.sample(
                    min(n_each, len(negatives)), random_state=random_state
                ).assign(
                    spotcheck_endpoint=endpoint,
                    spotcheck_label="negative",
                )
            )
    if not rows:
        return pd.DataFrame()
    return pd.concat(rows, ignore_index=True)


def load_excerpts(note_path: Path, selected: pd.DataFrame) -> dict[str, str]:
    hadms = set(selected["hadm_id"].map(clean_id))
    note_by_hadm = {
        clean_id(row.hadm_id): clean_id(getattr(row, "note_id", ""))
        for row in selected.itertuples(index=False)
    }
    excerpts: dict[str, str] = {}
    opener = gzip.open if note_path.suffix == ".gz" else open
    with opener(
        note_path, "rt", encoding="utf-8", errors="replace", newline=""
    ) as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            hadm = clean_id(row.get("hadm_id"))
            if hadm not in hadms:
                continue
            wanted_note = note_by_hadm.get(hadm)
            note_id = clean_id(row.get("note_id"))
            if wanted_note and note_id != wanted_note and hadm in excerpts:
                continue
            if wanted_note and note_id != wanted_note:
                excerpts.setdefault(hadm, extract_bhc(row.get("text", "")))
                continue
            excerpts[hadm] = extract_bhc(row.get("text", ""))
            if len(excerpts) == len(hadms):
                break
    return excerpts


def write_spotcheck(
    llm: pd.DataFrame,
    note_path: Path,
    report_path: Path,
    endpoints: list[str],
    n_each: int,
    random_state: int,
) -> int:
    selected = choose_spotcheck_rows(llm, endpoints, n_each, random_state)
    if selected.empty:
        report_path.write_text("No spot-check rows available.\n")
        return 0

    excerpts = load_excerpts(note_path, selected)
    lines = [
        "LLM endpoint spot-check sample",
        "=" * 30,
        f"Endpoints: {', '.join(endpoints)}",
        f"Sample: up to {n_each} positive and {n_each} negative per endpoint",
        "",
    ]
    for row in selected.itertuples(index=False):
        endpoint = row.spotcheck_endpoint
        hadm_id = clean_id(row.hadm_id)
        value = getattr(row, endpoint)
        conf = getattr(row, f"{endpoint}_confidence", "")
        evidence = getattr(row, f"{endpoint}_evidence", "")
        excerpt = excerpts.get(hadm_id, "[excerpt not found]")
        excerpt = textwrap.shorten(
            " ".join(str(excerpt).split()), width=1600, placeholder=" ..."
        )
        lines.extend(
            [
                "-" * 78,
                f"endpoint={endpoint} label={row.spotcheck_label} hadm_id={hadm_id} pid={clean_id(row.pid)}",
                f"llm_value={value} confidence={conf}",
                f"evidence={evidence}",
                "",
                excerpt,
                "",
            ]
        )
    report_path.write_text("\n".join(lines) + "\n")
    return len(selected)


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate albumin_aki LLM endpoints.")
    parser.add_argument("--llm", type=Path, default=LLM_OUTPUT)
    parser.add_argument("--dx-infection", type=Path, default=DX_INFECTION)
    parser.add_argument("--note-path", type=Path, default=NOTE_PATH)
    parser.add_argument("--concordance-report", type=Path, default=CONCORDANCE_REPORT)
    parser.add_argument("--spotcheck-report", type=Path, default=SPOTCHECK_REPORT)
    parser.add_argument("--spotcheck-n", type=int, default=5)
    parser.add_argument("--random-state", type=int, default=42)
    parser.add_argument(
        "--spotcheck-endpoints",
        default=",".join(DEFAULT_SPOTCHECK_ENDPOINTS),
        help='Comma-separated endpoint list, or "all". Default gives the 60-case key-endpoint review.',
    )
    args = parser.parse_args()

    llm = load_llm(args.llm)
    lines = []
    lines.extend(concordance_lines(llm, args.dx_infection))
    lines.extend(confidence_lines(llm))
    args.concordance_report.write_text("\n".join(lines) + "\n")

    endpoints = (
        ENDPOINTS
        if args.spotcheck_endpoints == "all"
        else [
            endpoint.strip()
            for endpoint in args.spotcheck_endpoints.split(",")
            if endpoint.strip()
        ]
    )
    bad = [endpoint for endpoint in endpoints if endpoint not in ENDPOINTS]
    if bad:
        raise SystemExit(f"unknown spotcheck endpoints: {bad}")
    n_spot = write_spotcheck(
        llm,
        args.note_path,
        args.spotcheck_report,
        endpoints,
        args.spotcheck_n,
        args.random_state,
    )

    print(f"LLM rows: {len(llm):,}")
    print(f"concordance/confidence report: {args.concordance_report}")
    print(f"spot-check report: {args.spotcheck_report} ({n_spot} cases)")


if __name__ == "__main__":
    main()
