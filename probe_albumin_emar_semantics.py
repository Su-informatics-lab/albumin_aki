#!/usr/bin/env python3
"""Audit whether MIMIC inputevents albumin volume identifies administered grams.

This is a verify-before-compute probe. It links the largest raw inputevents
courses to same-admission albumin eMAR rows and suppresses all patient,
admission, stay, order, and pharmacy identifiers in printed/aggregate output.
No patient-level output is written.
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
    parser.add_argument("--aggregate-output", type=Path, required=True)
    parser.add_argument("--n-courses", type=int, default=8)
    return parser.parse_args()


def clean_text(value: object) -> str:
    if pd.isna(value):
        return ""
    return str(value).strip()


def main() -> None:
    args = parse_args()
    dose = pd.read_csv(args.results / "did_albumin_dose_mimic.csv")
    top = dose.nlargest(args.n_courses, "albumin_grams_24h")[["pid"]].copy()
    top["case_id"] = [f"TAIL_{chr(65 + i)}" for i in range(len(top))]

    con = duckdb.connect()
    con.register("top_courses", top)
    for table, folder in [
        ("inputevents", "icu"),
        ("icustays", "icu"),
        ("emar", "hosp"),
        ("emar_detail", "hosp"),
        ("pharmacy", "hosp"),
        ("prescriptions", "hosp"),
    ]:
        path = args.mimic_root / folder / f"{table}.csv.gz"
        con.from_csv_auto(str(path)).create_view(table)

    raw = con.execute("""
        SELECT t.case_id, ie.subject_id, ie.hadm_id, ie.stay_id,
               ie.starttime::TIMESTAMP AS starttime,
               ie.endtime::TIMESTAMP AS endtime,
               ie.itemid, ie.amount, ie.amountuom, ie.rate, ie.rateuom,
               ie.orderid, ie.linkorderid,
               ie.ordercategorydescription, ie.ordercomponenttypedescription
        FROM top_courses t
        JOIN inputevents ie ON ie.stay_id = t.pid
        WHERE ie.itemid IN (220862, 220864)
          AND ie.amount > 0
          AND coalesce(ie.statusdescription, '') NOT ILIKE '%Rewritten%'
        ORDER BY t.case_id, ie.starttime
        """).df()
    con.register(
        "top_admissions",
        raw[["case_id", "subject_id", "hadm_id"]].drop_duplicates(),
    )

    emar = con.execute("""
        SELECT a.case_id, e.subject_id, e.hadm_id, e.emar_id, e.emar_seq,
               e.pharmacy_id, e.charttime::TIMESTAMP AS charttime,
               e.medication, e.event_txt,
               d.administration_type, d.dose_due, d.dose_due_unit,
               d.dose_given, d.dose_given_unit,
               d.product_amount_given, d.product_unit,
               d.product_code, d.product_description,
               d.product_description_other, d.prior_infusion_rate,
               d.infusion_rate, d.infusion_rate_unit, d.route,
               d.new_iv_bag_hung
        FROM top_admissions a
        JOIN emar e
          ON e.subject_id = a.subject_id AND e.hadm_id = a.hadm_id
        LEFT JOIN emar_detail d
          ON d.subject_id = e.subject_id
         AND d.emar_id = e.emar_id AND d.emar_seq = e.emar_seq
        WHERE coalesce(e.medication, '') ILIKE '%albumin%'
           OR coalesce(d.product_description, '') ILIKE '%albumin%'
           OR coalesce(d.product_description_other, '') ILIKE '%albumin%'
        ORDER BY a.case_id, e.charttime, e.emar_id, e.emar_seq,
                 d.parent_field_ordinal
        """).df()

    pharmacy = con.execute("""
        SELECT DISTINCT a.case_id, p.pharmacy_id, p.starttime, p.stoptime,
               p.medication, p.route, p.frequency, p.infusion_type,
               p.dispensation, p.fill_quantity,
               r.prod_strength, r.dose_val_rx, r.dose_unit_rx,
               r.form_val_disp, r.form_unit_disp
        FROM top_admissions a
        JOIN pharmacy p
          ON p.subject_id = a.subject_id AND p.hadm_id = a.hadm_id
        LEFT JOIN prescriptions r
          ON r.subject_id = p.subject_id AND r.hadm_id = p.hadm_id
         AND r.pharmacy_id = p.pharmacy_id
        WHERE coalesce(p.medication, '') ILIKE '%albumin%'
           OR coalesce(r.drug, '') ILIKE '%albumin%'
        ORDER BY a.case_id, p.starttime, p.pharmacy_id
        """).df()

    # Compare each input event with the nearest albumin eMAR administration.
    links: list[dict[str, object]] = []
    for case_id, events in raw.groupby("case_id", sort=True):
        ecase = emar[emar.case_id == case_id]
        for event in events.itertuples(index=False):
            if ecase.empty:
                nearest = None
                delta_min = None
            else:
                delta = (
                    pd.to_datetime(ecase.charttime) - pd.Timestamp(event.starttime)
                ).abs().dt.total_seconds() / 60
                nearest = ecase.loc[delta.idxmin()]
                delta_min = float(delta.min())
            links.append(
                {
                    "case_id": case_id,
                    "item": "25pct" if event.itemid == 220862 else "5pct",
                    "input_amount_ml": event.amount,
                    "input_rate": event.rate,
                    "input_duration_h": (
                        pd.Timestamp(event.endtime) - pd.Timestamp(event.starttime)
                    ).total_seconds()
                    / 3600,
                    "nearest_emar_delta_min": delta_min,
                    "dose_given": None if nearest is None else nearest.dose_given,
                    "dose_given_unit": (
                        "" if nearest is None else clean_text(nearest.dose_given_unit)
                    ),
                    "product_amount_given": (
                        None if nearest is None else nearest.product_amount_given
                    ),
                    "product_unit": (
                        "" if nearest is None else clean_text(nearest.product_unit)
                    ),
                    "product_description": (
                        ""
                        if nearest is None
                        else clean_text(nearest.product_description)
                    ),
                    "medication": (
                        "" if nearest is None else clean_text(nearest.medication)
                    ),
                    "administration_type": (
                        ""
                        if nearest is None
                        else clean_text(nearest.administration_type)
                    ),
                }
            )
    linked = pd.DataFrame(links)

    print("TOP-TAIL INPUTEVENTS TO NEAREST eMAR (all identifiers suppressed)")
    print(linked.to_string(index=False))
    print("\nSAME-ADMISSION ALBUMIN PHARMACY/PRESCRIPTION FIELDS")
    show_pharm = pharmacy.drop(columns=["pharmacy_id"], errors="ignore")
    print(show_pharm.to_string(index=False))

    within_60 = linked.nearest_emar_delta_min.le(60).fillna(False)
    gram_units = linked.dose_given_unit.str.lower().isin(["g", "gm", "gram", "grams"])
    product_ml = linked.product_unit.str.lower().isin(["ml", "milliliter"])
    rows = [
        {
            "probe": "top_tail_inputevents_emar_linkage",
            "n_courses": linked.case_id.nunique(),
            "n_input_events": len(linked),
            "n_emar_albumin_rows": len(emar),
            "events_with_emar_within_60min": int(within_60.sum()),
            "fraction_with_emar_within_60min": float(within_60.mean()),
            "events_with_gram_dose_within_60min": int((within_60 & gram_units).sum()),
            "events_with_product_ml_within_60min": int((within_60 & product_ml).sum()),
            "conclusion": (
                "exact_grams_recoverable_for_top_tail"
                if (within_60 & gram_units).sum() == len(linked)
                else "exact_grams_not_fully_recoverable_for_top_tail"
            ),
        }
    ]
    out = pd.DataFrame(rows)
    args.aggregate_output.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(args.aggregate_output, index=False)
    print("\nAGGREGATE VERDICT")
    print(out.to_string(index=False))


if __name__ == "__main__":
    main()
