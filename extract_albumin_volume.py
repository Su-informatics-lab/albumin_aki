#!/usr/bin/env python3
"""Extract validated MIMIC albumin infusion volume for Entry 42.

This is a volume-only secondary analysis.  ``inputevents.amount`` was
source-audited in Entry 25 and is usable when ``amountuom == mL``.  Product
labels are deliberately not read or converted to grams.

Patient-level output remains in the HPC-only results directory.  Only the
aggregate provenance file is eligible for commit.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def delivered_volume(events: pd.DataFrame) -> pd.Series:
    """Allocate each event's amount to (T0, T0+24h] by time overlap.

    For time-resolved infusions, amount is prorated by the fraction of the
    event duration overlapping the window.  A zero-duration event is counted
    only when its timestamp is strictly after T0 and no later than T0+24h.
    Thus an infusion beginning at T0 contributes its post-T0 delivered
    volume, without treating the item label as a concentration.
    """
    start = pd.to_datetime(events.starttime, errors="coerce")
    end = pd.to_datetime(events.endtime, errors="coerce")
    t0 = pd.to_datetime(events.t0, errors="coerce")
    t1 = t0 + pd.Timedelta(hours=24)
    duration = (end - start).dt.total_seconds()
    overlap_start = pd.concat([start, t0], axis=1).max(axis=1)
    overlap_end = pd.concat([end, t1], axis=1).min(axis=1)
    overlap = (overlap_end - overlap_start).dt.total_seconds().clip(lower=0)
    timed = duration > 0
    instant = (~timed) & (start > t0) & (start <= t1)
    fraction = pd.Series(0.0, index=events.index)
    fraction.loc[timed] = (overlap.loc[timed] / duration.loc[timed]).clip(0, 1)
    fraction.loc[instant] = 1.0
    return pd.to_numeric(events.amount, errors="coerce") * fraction


def self_test() -> None:
    x = pd.DataFrame(
        {
            "starttime": [
                "2026-01-01 00:00", "2026-01-01 23:00",
                "2026-01-02 01:00", "2026-01-01 00:00",
            ],
            "endtime": [
                "2026-01-01 02:00", "2026-01-02 01:00",
                "2026-01-02 01:00", "2026-01-01 00:00",
            ],
            "t0": ["2026-01-01 00:00"] * 4,
            "amount": [100.0, 100.0, 50.0, 50.0],
        }
    )
    got = delivered_volume(x).to_numpy()
    expected = np.array([100.0, 50.0, 0.0, 0.0])
    if not np.allclose(got, expected):
        raise AssertionError(f"volume-overlap fixture failed: {got} != {expected}")
    print("extract_albumin_volume.py self-test: PASS")


def extract(args: argparse.Namespace) -> None:
    con = duckdb.connect()
    con.from_csv_auto(
        str(args.data_root / "icu" / "inputevents.csv.gz")
    ).create_view("inputevents")
    con.from_csv_auto(
        str(args.data_root / "icu" / "icustays.csv.gz")
    ).create_view("icustays")
    all_pts = pd.read_csv(args.results / "did_all_mimic.csv")
    treated = all_pts.loc[
        (all_pts.treated == 1) & all_pts.alb_offset_h.notna(),
        ["pid", "alb_offset_h"],
    ].copy()
    con.register("treated", treated)
    events = con.execute(
        """
        SELECT ie.stay_id AS pid, ie.starttime, ie.endtime,
               ie.amount, ie.amountuom, ie.statusdescription,
               icu.intime, t.alb_offset_h,
               icu.intime::TIMESTAMP
                 + t.alb_offset_h * INTERVAL '1 hour' AS t0
        FROM inputevents ie
        JOIN icustays icu USING (stay_id)
        JOIN treated t ON t.pid = ie.stay_id
        WHERE ie.itemid IN (220862, 220864)
          AND ie.amount > 0
          AND coalesce(ie.statusdescription, '') NOT ILIKE '%Rewritten%'
        """
    ).df()
    units = set(events.amountuom.dropna().astype(str).unique())
    if units != {"mL"}:
        raise RuntimeError(f"albumin amount includes non-mL units: {sorted(units)}")

    first = (
        pd.to_datetime(events.starttime) - pd.to_datetime(events.intime)
    ).dt.total_seconds().div(3600).groupby(events.pid).min()
    expected = treated.set_index("pid").alb_offset_h
    delta_seconds = (first - expected.loc[first.index]).abs() * 3600
    if len(first) != len(expected) or delta_seconds.max() > 1:
        raise RuntimeError("raw first albumin does not reconcile to frozen T0")

    events["volume_ml_24h"] = delivered_volume(events)
    totals = events.groupby("pid").agg(
        albumin_volume_ml_24h=("volume_ml_24h", "sum"),
        n_albumin_events=("amount", "size"),
        n_contributing_events=("volume_ml_24h", lambda z: int((z > 0).sum())),
    )
    totals = treated[["pid"]].merge(totals, on="pid", how="left")
    totals[["albumin_volume_ml_24h", "n_albumin_events", "n_contributing_events"]] = (
        totals[["albumin_volume_ml_24h", "n_albumin_events", "n_contributing_events"]]
        .fillna(0)
    )
    args.results.mkdir(parents=True, exist_ok=True)
    totals.to_csv(args.results / "did_albumin_volume_24h_mimic.csv", index=False)

    start = pd.to_datetime(events.starttime, errors="coerce")
    end = pd.to_datetime(events.endtime, errors="coerce")
    duration = (end - start).dt.total_seconds()
    provenance = pd.DataFrame(
        [
            {
                "database": "MIMIC",
                "window": "delivered volume in (T0,T0+24h]",
                "source": "inputevents.amount with amountuom=mL",
                "treated_source_n": len(treated),
                "treated_with_positive_volume_n": int(
                    (totals.albumin_volume_ml_24h > 0).sum()
                ),
                "raw_albumin_event_n": len(events),
                "contributing_event_n": int((events.volume_ml_24h > 0).sum()),
                "time_resolved_event_n": int((duration > 0).sum()),
                "zero_or_missing_duration_event_n": int(
                    (duration.fillna(0) <= 0).sum()
                ),
                "max_t0_reconciliation_seconds": float(delta_seconds.max()),
                "grams_computed": False,
                "product_label_used": False,
            }
        ]
    )
    provenance.to_csv(
        args.results / "volume_24h_provenance_mimic.csv", index=False
    )
    print(provenance.to_string(index=False))


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return
    extract(args)


if __name__ == "__main__":
    main()
