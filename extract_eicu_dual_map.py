#!/usr/bin/env python3
"""Extract one dual-source MAP value at the frozen patient-specific eICU T0.

Patient-level output remains on Tempest and is default-deny ignored.  This is
an input to the labeled +MAP sensitivity, not a change to frozen v3.3.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import pandas as pd


def resolve(root: Path, stem: str) -> Path:
    for suffix in (".csv.gz", ".csv"):
        path = root / f"{stem}{suffix}"
        if path.exists():
            return path
    raise FileNotFoundError(stem)


def update_best(
    best: pd.DataFrame,
    chunk: pd.DataFrame,
    t0_min: pd.Series,
    value_col: str,
    source: str,
    priority: int,
) -> pd.DataFrame:
    pid = pd.to_numeric(chunk.patientunitstayid, errors="coerce")
    offset = pd.to_numeric(chunk.observationoffset, errors="coerce")
    value = pd.to_numeric(chunk[value_col], errors="coerce")
    candidate = pd.DataFrame(
        {
            "pid": pid,
            "offset_min": offset,
            "map_before_t0": value,
            "map_source": source,
            "source_priority": priority,
        }
    ).dropna(subset=["pid", "offset_min", "map_before_t0"])
    candidate.pid = candidate.pid.astype("int64")
    candidate = candidate[
        candidate.pid.isin(t0_min.index)
        & candidate.map_before_t0.between(20, 200, inclusive="both")
    ]
    candidate = candidate[candidate.offset_min < candidate.pid.map(t0_min)]
    if candidate.empty:
        return best
    candidate = candidate.sort_values(
        ["pid", "offset_min", "source_priority", "map_before_t0"],
        ascending=[True, False, False, False],
    ).drop_duplicates("pid")
    combined = pd.concat([best, candidate], ignore_index=True)
    return combined.sort_values(
        ["pid", "offset_min", "source_priority", "map_before_t0"],
        ascending=[True, False, False, False],
    ).drop_duplicates("pid")


def scan(
    path: Path,
    usecols: list[str],
    value_col: str,
    source: str,
    priority: int,
    t0_min: pd.Series,
    best: pd.DataFrame,
) -> pd.DataFrame:
    for chunk in pd.read_csv(
        path,
        usecols=usecols,
        chunksize=2_000_000,
        low_memory=False,
        compression="infer",
    ):
        best = update_best(best, chunk, t0_min, value_col, source, priority)
    return best


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--results",
        type=Path,
        default=Path(os.path.expanduser("~/albumin_aki/results")),
    )
    parser.add_argument(
        "--eicu-root",
        type=Path,
        default=Path(os.path.expanduser("~/mg_aki/eicu-crd-2.0")),
    )
    args = parser.parse_args()

    cohort = pd.read_csv(
        args.results / "did_all_eicu.csv",
        usecols=["pid", "treated", "alb_offset_h", "cr_ref_early_offset_h"],
        low_memory=False,
    )
    cohort.pid = pd.to_numeric(cohort.pid, errors="raise").astype("int64")
    index_h = pd.to_numeric(cohort.alb_offset_h, errors="coerce").where(
        cohort.treated.eq(1),
        pd.to_numeric(cohort.cr_ref_early_offset_h, errors="coerce"),
    )
    if index_h.isna().any():
        raise RuntimeError("Missing frozen patient-specific index")
    t0_min = pd.Series((index_h * 60).values, index=cohort.pid)
    best = pd.DataFrame(
        columns=[
            "pid",
            "offset_min",
            "map_before_t0",
            "map_source",
            "source_priority",
        ]
    )
    best = scan(
        resolve(args.eicu_root, "vitalPeriodic"),
        ["patientunitstayid", "observationoffset", "systemicmean"],
        "systemicmean",
        "vitalPeriodic.systemicmean",
        2,
        t0_min,
        best,
    )
    best = scan(
        resolve(args.eicu_root, "vitalAperiodic"),
        ["patientunitstayid", "observationoffset", "noninvasivemean"],
        "noninvasivemean",
        "vitalAperiodic.noninvasivemean",
        1,
        t0_min,
        best,
    )

    out = cohort[["pid", "treated"]].merge(
        best.drop(columns="source_priority"), on="pid", how="left"
    )
    out["map_offset_h"] = out.offset_min / 60.0
    out["map_missing"] = out.map_before_t0.isna().astype("int64")
    out = out.drop(columns="offset_min")
    out.to_csv(args.results / "eicu_map_at_t0_dual.csv", index=False)
    coverage = out.groupby("treated").map_before_t0.apply(lambda x: x.notna().mean())
    print(
        "extract_eicu_dual_map.py | COMPLETE | "
        f"treated={coverage.get(1, float('nan')):.4f} "
        f"control={coverage.get(0, float('nan')):.4f} | patient-level remote only"
    )


if __name__ == "__main__":
    main()
