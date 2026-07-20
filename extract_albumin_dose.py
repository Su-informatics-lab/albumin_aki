#!/usr/bin/env python3
"""Build corrected 0-24h albumin grams/volume for salvage analyses.

The patient-level output remains on Tempest/Quartz. The aggregate distribution
and provenance outputs contain no identifiers and are suitable for commit.
The dose window is [first accepted albumin T0, T0 + 24 hours].
"""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import pyarrow.parquet as pq


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", choices=["mimic", "iuh"])
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    return parser.parse_args()


def summarize(dose: pd.DataFrame, database: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    rows: list[dict[str, object]] = []
    for metric in ["albumin_grams_24h", "albumin_volume_ml_24h", "n_events"]:
        x = pd.to_numeric(dose[metric], errors="coerce").dropna()
        rows.append(
            {
                "database": database.upper(),
                "window": "first_albumin_T0_to_T0_plus_24h",
                "metric": metric,
                "n": len(x),
                "mean": x.mean(),
                "sd": x.std(),
                "min": x.min(),
                "p05": x.quantile(0.05),
                "p25": x.quantile(0.25),
                "p50": x.quantile(0.50),
                "p75": x.quantile(0.75),
                "p95": x.quantile(0.95),
                "max": x.max(),
            }
        )
    provenance = pd.DataFrame(
        [
            {
                "database": database.upper(),
                "window": "first_albumin_T0_to_T0_plus_24h",
                "treated_with_dose": len(dose),
                "mixed_product_courses": int(dose.mixed_product.sum()),
                "events_5pct": int(dose.n_5pct.sum()),
                "events_25pct": int(dose.n_25pct.sum()),
                "events_total": int(dose.n_events.sum()),
                "courses_volume_gt_2000ml": int(
                    (dose.albumin_volume_ml_24h > 2000).sum()
                ),
                "courses_grams_gt_250g": int((dose.albumin_grams_24h > 250).sum()),
                "max_t0_difference_seconds": float(
                    dose.t0_difference_seconds.abs().max()
                ),
            }
        ]
    )
    return pd.DataFrame(rows), provenance


def extract_mimic(args: argparse.Namespace) -> pd.DataFrame:
    con = duckdb.connect()
    con.from_csv_auto(str(args.data_root / "icu" / "inputevents.csv.gz")).create_view(
        "inputevents"
    )
    con.from_csv_auto(str(args.data_root / "icu" / "icustays.csv.gz")).create_view(
        "icustays"
    )
    all_pts = pd.read_csv(args.results / "did_all_mimic.csv")
    con.register(
        "analysis_cohort",
        all_pts.loc[all_pts.treated == 1, ["pid", "alb_offset_h"]],
    )
    events = con.execute("""
        SELECT ie.stay_id AS pid, ie.itemid, ie.amount, ie.amountuom,
               date_diff('second', icu.intime::TIMESTAMP,
                         ie.starttime::TIMESTAMP) / 3600.0 AS offset_h,
               c.alb_offset_h
        FROM inputevents ie
        JOIN icustays icu USING (stay_id)
        JOIN analysis_cohort c ON c.pid = ie.stay_id
        WHERE ie.itemid IN (220862, 220864)
          AND ie.amount > 0
          AND coalesce(ie.statusdescription, '') NOT ILIKE '%Rewritten%'
        """).df()
    if set(events.amountuom.dropna().unique()) != {"mL"}:
        raise RuntimeError("MIMIC albumin amount has a non-mL unit")
    first = events.groupby("pid").offset_h.min()
    expected = all_pts.loc[all_pts.treated == 1].set_index("pid").alb_offset_h
    difference_seconds = (first - expected.loc[first.index]) * 3600
    if len(first) != len(expected) or difference_seconds.abs().max() > 1:
        raise RuntimeError("Raw MIMIC first albumin does not reconcile to frozen T0")
    events = events[
        (events.offset_h >= events.alb_offset_h - 1 / 3600)
        & (events.offset_h <= events.alb_offset_h + 24)
    ].copy()
    events["grams"] = events.amount * np.where(events.itemid == 220862, 0.25, 0.05)
    dose = (
        events.groupby("pid")
        .agg(
            albumin_grams_24h=("grams", "sum"),
            albumin_volume_ml_24h=("amount", "sum"),
            n_events=("itemid", "size"),
            n_5pct=("itemid", lambda x: int((x == 220864).sum())),
            n_25pct=("itemid", lambda x: int((x == 220862).sum())),
        )
        .reset_index()
    )
    dose["mixed_product"] = ((dose.n_5pct > 0) & (dose.n_25pct > 0)).astype(int)
    dose["t0_difference_seconds"] = dose.pid.map(difference_seconds)
    return dose


def load_iuh_module(repo: Path):
    path = repo / "iuh" / "01_etl.py"
    spec = importlib.util.spec_from_file_location("iuh_etl", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_iuh_io(path: Path, ids: set[str]) -> pd.DataFrame:
    pf = pq.ParquetFile(path)
    chunks = []
    for i in range(pf.metadata.num_row_groups):
        x = pf.read_row_group(
            i,
            columns=["subject_id", "hadm_id", "IO", "Event", "Vol", "IOdate"],
        ).to_pandas()
        x = x[
            x.subject_id.isin(ids)
            & x.IO.fillna("").str.contains("albumin", case=False)
            & (x.Event == "MED INTAKE")
            & (x.Vol > 0)
        ]
        if not x.empty:
            chunks.append(x)
    if not chunks:
        raise RuntimeError("No IUH albumin IO rows found")
    return pd.concat(chunks, ignore_index=True)


def extract_iuh(args: argparse.Namespace) -> pd.DataFrame:
    iuh = load_iuh_module(args.repo)
    all_pts = pd.read_csv(args.results / "did_all_iuh.csv")
    treated = all_pts[all_pts.treated == 1].copy()
    proc = pd.read_parquet(args.data_root / "processed" / "Procedure.parquet")
    proc = proc[proc.SurgicalProcedureCVDSC.isin(iuh.KEEP_CVDSC)].copy()
    proc["SurgicalStartDTS"] = pd.to_datetime(proc.SurgicalStartDTS, errors="coerce")
    proc["SurgicalStopDTS"] = pd.to_datetime(proc.SurgicalStopDTS, errors="coerce")
    proc = proc.dropna(subset=["subject_id", "hadm_id", "SurgicalStopDTS"])
    cardiac = proc.sort_values("SurgicalStartDTS").drop_duplicates(
        ["subject_id", "hadm_id"]
    )
    icu = pd.read_parquet(args.data_root / "derived" / "icustay_hourhrbp.parquet")
    for col in ["unitin", "unitout"]:
        icu[col] = pd.to_datetime(icu[col], errors="coerce")
    cohort = cardiac.merge(icu, on=["subject_id", "hadm_id"], how="inner")
    cohort = cohort[cohort.unitout > cohort.SurgicalStopDTS].copy()
    cohort["postop_start"] = cohort[["unitin", "SurgicalStopDTS"]].max(axis=1)
    cohort = cohort.sort_values("postop_start").drop_duplicates("subject_id")
    cohort = cohort[
        cohort.subject_id.isin(set(treated.pid))
        & cohort.hadm_id.isin(set(treated.hadm_id))
    ]
    io = read_iuh_io(args.data_root / "processed" / "IO.parquet", set(treated.pid))
    io["IOdate"] = pd.to_datetime(io.IOdate, errors="coerce")
    io = io.merge(
        cohort[["subject_id", "hadm_id", "postop_start", "unitout"]],
        on=["subject_id", "hadm_id"],
        how="inner",
    )
    io["offset_h"] = (io.IOdate - io.postop_start).dt.total_seconds() / 3600
    io = io[(io.offset_h >= 0) & (io.IOdate <= io.unitout)].copy()
    expected = treated.set_index("pid").alb_offset_h
    first = io.groupby("subject_id").offset_h.min()
    difference_seconds = (first - expected.loc[first.index]) * 3600
    if len(first) != len(expected) or difference_seconds.abs().max() > 1:
        raise RuntimeError("Raw IUH first albumin does not reconcile to frozen T0")
    io["alb_offset_h"] = io.subject_id.map(expected)
    io = io[
        (io.offset_h >= io.alb_offset_h - 1 / 3600)
        & (io.offset_h <= io.alb_offset_h + 24)
    ].copy()
    is_25 = io.IO.str.contains("25", na=False)
    is_5 = io.IO.str.contains("5", na=False)
    if (~(is_25 | is_5)).any():
        raise RuntimeError("IUH albumin row lacks a product concentration")
    io["grams"] = io.Vol * np.where(is_25, 0.25, 0.05)
    io["item"] = np.where(is_25, "25pct", "5pct")
    dose = (
        io.groupby("subject_id")
        .agg(
            albumin_grams_24h=("grams", "sum"),
            albumin_volume_ml_24h=("Vol", "sum"),
            n_events=("item", "size"),
            n_5pct=("item", lambda x: int((x == "5pct").sum())),
            n_25pct=("item", lambda x: int((x == "25pct").sum())),
        )
        .reset_index()
        .rename(columns={"subject_id": "pid"})
    )
    dose["mixed_product"] = ((dose.n_5pct > 0) & (dose.n_25pct > 0)).astype(int)
    dose["t0_difference_seconds"] = dose.pid.map(difference_seconds)
    return dose


def main() -> None:
    args = parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    dose = extract_mimic(args) if args.database == "mimic" else extract_iuh(args)
    dose.to_csv(args.results / f"did_albumin_dose_{args.database}.csv", index=False)
    distribution, provenance = summarize(dose, args.database)
    distribution.to_csv(
        args.results / f"albumin_dose_distribution_{args.database}.csv", index=False
    )
    provenance.to_csv(
        args.results / f"albumin_dose_provenance_{args.database}.csv", index=False
    )
    print(distribution.to_string(index=False))
    print(provenance.to_string(index=False))


if __name__ == "__main__":
    main()
