#!/usr/bin/env python3
"""Probe raw MIMIC albumin amount semantics; not part of the primary pipeline.

Patient identifiers are used only in memory to choose five distinct courses.
The printed hand-check suppresses all identifiers, and the optional CSV is an
aggregate item/unit summary suitable for commit.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import duckdb
import pandas as pd

ITEMS = (220862, 220864)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mimic-root", type=Path, required=True)
    parser.add_argument("--aggregate-output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    con = duckdb.connect()
    con.from_csv_auto(str(args.mimic_root / "icu" / "inputevents.csv.gz")).create_view(
        "inputevents"
    )
    con.from_csv_auto(str(args.mimic_root / "icu" / "d_items.csv.gz")).create_view(
        "d_items"
    )
    con.execute("""
        CREATE TEMP VIEW albumin_events AS
        SELECT *,
               date_diff('second', starttime::TIMESTAMP,
                         endtime::TIMESTAMP) / 3600.0 AS duration_h
        FROM inputevents
        WHERE itemid IN (220862, 220864)
          AND amount > 0
          AND coalesce(statusdescription, '') NOT ILIKE '%Rewritten%'
        """)

    definitions = con.execute("""
        SELECT itemid, label, abbreviation, unitname, param_type
        FROM d_items
        WHERE itemid IN (220862, 220864)
        ORDER BY itemid
        """).df()
    print("ITEM DEFINITIONS")
    print(definitions.to_string(index=False))

    courses = con.execute("""
        SELECT stay_id, count(*) AS n_events,
               count(DISTINCT itemid) AS n_products,
               min(itemid) AS min_item,
               max(CASE WHEN ordercategorydescription ILIKE '%continuous%'
                        THEN 1 ELSE 0 END) AS has_continuous
        FROM albumin_events
        GROUP BY stay_id
        ORDER BY stay_id
        """).df()
    selectors = [
        ("A_25pct_single", lambda x: x.n_events == 1 and x.min_item == 220862),
        ("B_5pct_single", lambda x: x.n_events == 1 and x.min_item == 220864),
        ("C_mixed_course", lambda x: x.n_products == 2),
        (
            "D_25pct_multi",
            lambda x: x.n_events >= 3 and x.n_products == 1 and x.min_item == 220862,
        ),
        ("E_continuous", lambda x: x.has_continuous == 1),
    ]
    used: set[int] = set()
    picks: list[dict[str, object]] = []
    for case_id, predicate in selectors:
        candidates = courses[
            courses.apply(predicate, axis=1) & ~courses.stay_id.isin(used)
        ]
        if candidates.empty:
            raise RuntimeError(f"No distinct raw course found for {case_id}")
        stay_id = int(candidates.iloc[0].stay_id)
        used.add(stay_id)
        picks.append({"case_id": case_id, "stay_id": stay_id})

    con.register("case_picks", pd.DataFrame(picks))
    handcheck = con.execute("""
        SELECT p.case_id, a.itemid,
               CASE a.itemid WHEN 220862 THEN 'Albumin 25%'
                             ELSE 'Albumin 5%' END AS product,
               round(a.amount, 3) AS amount, a.amountuom,
               round(a.duration_h, 3) AS duration_h,
               round(a.rate, 3) AS rate, a.rateuom,
               round(a.totalamount, 3) AS totalamount, a.totalamountuom,
               round(a.originalamount, 3) AS originalamount,
               round(a.originalrate, 3) AS originalrate,
               a.ordercategoryname, a.ordercomponenttypedescription,
               a.ordercategorydescription, a.statusdescription
        FROM case_picks p
        JOIN albumin_events a USING (stay_id)
        ORDER BY p.case_id, a.starttime, a.itemid
        """).df()
    print("\nFIVE-PATIENT HAND CHECK (patient/stay IDs suppressed)")
    print(handcheck.to_string(index=False))

    summary = con.execute("""
        SELECT a.itemid, d.label, a.amountuom, a.rateuom,
               count(*) AS n_events,
               count(DISTINCT a.stay_id) AS n_stays,
               quantile_cont(a.amount, 0.10) AS p10_amount,
               quantile_cont(a.amount, 0.50) AS median_amount,
               quantile_cont(a.amount, 0.90) AS p90_amount,
               median(
                 CASE WHEN a.rate > 0 AND a.duration_h > 0
                      THEN a.amount / (a.rate * a.duration_h) END
               ) AS median_amount_over_rate_duration,
               avg(
                 CASE WHEN a.rate > 0 AND a.duration_h > 0
                           AND abs(a.amount - a.rate * a.duration_h)
                               <= greatest(1.0, 0.05 * a.amount)
                      THEN 1.0 ELSE 0.0 END
               ) AS fraction_amount_matches_rate_duration
        FROM albumin_events a
        LEFT JOIN d_items d USING (itemid)
        GROUP BY a.itemid, d.label, a.amountuom, a.rateuom
        ORDER BY a.itemid, n_events DESC
        """).df()
    print("\nAMOUNT/UNIT SUMMARY")
    print(summary.to_string(index=False))
    if args.aggregate_output:
        args.aggregate_output.parent.mkdir(parents=True, exist_ok=True)
        summary.to_csv(args.aggregate_output, index=False)


if __name__ == "__main__":
    main()
