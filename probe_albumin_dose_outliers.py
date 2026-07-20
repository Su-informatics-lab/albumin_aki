#!/usr/bin/env python3
"""Probe corrected MIMIC dose tails; not part of the primary pipeline.

The top courses are relabeled A, B, ... before printing. No patient or stay
identifier is written to the aggregate output or stdout.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import duckdb
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mimic-root", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    dose = pd.read_csv(args.results / "did_albumin_dose_mimic.csv")
    top = dose.nlargest(8, "albumin_grams_24h").copy()
    top["case_id"] = [f"TAIL_{chr(65 + i)}" for i in range(len(top))]

    con = duckdb.connect()
    con.from_csv_auto(str(args.mimic_root / "icu" / "inputevents.csv.gz")).create_view(
        "inputevents"
    )
    con.from_csv_auto(str(args.mimic_root / "icu" / "icustays.csv.gz")).create_view(
        "icustays"
    )
    all_pts = pd.read_csv(args.results / "did_all_mimic.csv")
    con.register(
        "tail_cases",
        top[["pid", "case_id", "albumin_grams_24h", "albumin_volume_ml_24h"]],
    )
    con.register(
        "analysis_cohort",
        all_pts.loc[all_pts.treated == 1, ["pid", "alb_offset_h"]],
    )
    events = con.execute("""
        SELECT t.case_id, t.albumin_grams_24h, t.albumin_volume_ml_24h,
               ie.itemid,
               CASE ie.itemid WHEN 220862 THEN 'Albumin 25%'
                              ELSE 'Albumin 5%' END AS product,
               round(ie.amount, 3) AS amount_ml,
               round(date_diff('second', ie.starttime::TIMESTAMP,
                               ie.endtime::TIMESTAMP) / 3600.0, 3) AS duration_h,
               round(ie.rate, 3) AS rate, ie.rateuom,
               ie.orderid, ie.linkorderid, ie.statusdescription,
               ie.ordercategorydescription,
               date_diff('second', icu.intime::TIMESTAMP,
                         ie.starttime::TIMESTAMP) / 3600.0 AS offset_h,
               c.alb_offset_h
        FROM inputevents ie
        JOIN icustays icu USING (stay_id)
        JOIN analysis_cohort c ON c.pid = ie.stay_id
        JOIN tail_cases t ON t.pid = ie.stay_id
        WHERE ie.itemid IN (220862, 220864)
          AND ie.amount > 0
          AND coalesce(ie.statusdescription, '') NOT ILIKE '%Rewritten%'
          AND date_diff('second', icu.intime::TIMESTAMP,
                        ie.starttime::TIMESTAMP) / 3600.0
              BETWEEN c.alb_offset_h - 1.0 / 3600.0 AND c.alb_offset_h + 24
        ORDER BY t.case_id, ie.starttime, ie.itemid
        """).df()
    print("TOP EIGHT CORRECTED-DOSE COURSES (IDs suppressed)")
    print(events.to_string(index=False))

    pairs = pd.read_csv(
        args.results / "did_pairs_primary_yet_untreated_pooled_mimic.csv",
        usecols=["trt_pid"],
    )
    matched = dose[dose.pid.isin(set(pairs.trt_pid))].copy()
    rows = []
    for population, x in [("all_treated", dose), ("matched_treated", matched)]:
        rows.append(
            {
                "population": population,
                "n": len(x),
                "grams_gt_100": int((x.albumin_grams_24h > 100).sum()),
                "grams_gt_150": int((x.albumin_grams_24h > 150).sum()),
                "grams_gt_250": int((x.albumin_grams_24h > 250).sum()),
                "volume_gt_2000ml": int((x.albumin_volume_ml_24h > 2000).sum()),
                "max_grams": x.albumin_grams_24h.max(),
                "max_volume_ml": x.albumin_volume_ml_24h.max(),
            }
        )
    duplicate_key = [
        "case_id",
        "itemid",
        "amount_ml",
        "duration_h",
        "rate",
        "orderid",
        "linkorderid",
    ]
    aggregate = pd.DataFrame(rows)
    aggregate["top8_exact_duplicate_event_rows"] = int(
        events.duplicated(duplicate_key, keep=False).sum()
    )
    aggregate.to_csv(
        args.results / "probe_albumin_dose_outliers_mimic.csv", index=False
    )
    print("\nTAIL SUMMARY")
    print(aggregate.to_string(index=False))


if __name__ == "__main__":
    main()
