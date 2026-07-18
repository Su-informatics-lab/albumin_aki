#!/usr/bin/env python3
"""Assert that every final treated T0 maps to an accepted raw administration row."""

import os
import sys
from importlib.util import module_from_spec, spec_from_file_location

import pandas as pd


def load_etl():
    spec = spec_from_file_location(
        "albumin_etl", os.path.join(os.path.dirname(__file__), "01_etl.py")
    )
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(db):
    etl = load_etl()
    cohort = pd.read_csv(os.path.join(etl.RESULTS, f"did_all_{db}.csv"))
    cohort["pid"] = pd.to_numeric(cohort.pid)
    pids = set(cohort.pid.astype(int))
    treated = cohort[cohort.treated == 1].set_index("pid")

    if db == "mimic":
        raw = etl.load_filtered("inputevents", etl.MIMIC_ICU, pids, pid_col="stay_id")
        candidate = raw[raw.itemid.isin(etl.ALB_INFUSION_ITEMS_MIMIC)].copy()
        rewritten = int(
            candidate.get(
                "statusdescription", pd.Series(index=candidate.index, dtype=str)
            )
            .str.contains("Rewritten", na=False)
            .sum()
        )
        accepted = candidate[
            ~candidate.get(
                "statusdescription", pd.Series("", index=candidate.index)
            ).str.contains("Rewritten", na=False)
            & candidate.amount.notna()
            & (candidate.amount > 0)
        ].copy()
        accepted["starttime"] = pd.to_datetime(accepted.starttime)
        stays = pd.read_csv(
            etl.gz(f"{etl.MIMIC_ICU}/icustays.csv.gz"), usecols=["stay_id", "intime"]
        )
        stays["intime"] = pd.to_datetime(stays.intime)
        accepted = accepted.merge(stays[stays.stay_id.isin(pids)], on="stay_id")
        accepted["raw_t0_h"] = (
            accepted.starttime - accepted.intime
        ).dt.total_seconds() / 3600
        accepted = accepted[accepted.raw_t0_h >= 0]
        accepted["source"] = accepted.itemid.map(etl.ALB_PRODUCT_MAP)
        id_col = "stay_id"
        print(
            f"candidate_rows={len(candidate):,}; rewritten={rewritten:,}; accepted_rows={len(accepted):,}"
        )
        print(
            "accepted_item_counts="
            + str(accepted.itemid.value_counts().sort_index().to_dict())
        )
    else:
        med = etl.load_filtered("medication", etl.EICU_ROOT, pids)
        io = etl.load_filtered("intakeOutput", etl.EICU_ROOT, pids)
        candidate = med[etl.matches_any(med.drugname, etl.ALB_INFUSION_PATTERNS)].copy()
        cancelled = (
            candidate.get("drugordercancelled", pd.Series("", index=candidate.index))
            .astype(str)
            .str.contains("Yes", na=False)
        )
        accepted_med = candidate[~cancelled & (candidate.drugstartoffset >= 0)].copy()
        if "routeadmin" in accepted_med:
            route_ok = (
                accepted_med.routeadmin.str.lower().str.contains(
                    etl.ALB_IV_ROUTE_PATTERNS, na=False
                )
                | accepted_med.routeadmin.isna()
            )
            route_missing = int(accepted_med.routeadmin.isna().sum())
            accepted_med = accepted_med[route_ok]
        else:
            route_missing = len(accepted_med)
        accepted_med = accepted_med[["patientunitstayid", "drugstartoffset"]].rename(
            columns={"drugstartoffset": "raw_t0_min"}
        )
        accepted_med["source"] = "medication"
        io_frames = []
        for col in ["celllabel", "cellpath"]:
            if col in io:
                hit = io[
                    etl.matches_any(io[col], etl.ALB_IO_PATTERNS)
                    & (io.intakeoutputoffset >= 0)
                ]
                io_frames.append(
                    hit[["patientunitstayid", "intakeoutputoffset"]].rename(
                        columns={"intakeoutputoffset": "raw_t0_min"}
                    )
                )
                break
        accepted_io = (
            io_frames[0]
            if io_frames
            else pd.DataFrame(columns=["patientunitstayid", "raw_t0_min"])
        )
        accepted_io["source"] = "intakeOutput"
        accepted = pd.concat([accepted_med, accepted_io], ignore_index=True)
        accepted["raw_t0_h"] = accepted.raw_t0_min / 60.0
        id_col = "patientunitstayid"
        overlap = len(
            set(accepted_med.patientunitstayid) & set(accepted_io.patientunitstayid)
        )
        print(
            f"candidate_med_rows={len(candidate):,}; cancelled={int(cancelled.sum()):,}; route_missing={route_missing:,}"
        )
        print(f"accepted_rows={len(accepted):,}; source_patient_overlap={overlap:,}")

    first = accepted.sort_values("raw_t0_h").groupby(id_col).first()
    mapped = treated[["alb_offset_h"]].join(first[["raw_t0_h"]], how="left")
    delta = (mapped.alb_offset_h - mapped.raw_t0_h).abs()
    assert (
        mapped.raw_t0_h.notna().all()
    ), "FAIL: final treated T0 without accepted raw row"
    assert (
        float(delta.max()) < 1e-8
    ), "FAIL: final treated T0 differs from raw first administration"
    assert (mapped.raw_t0_h >= 0).all(), "FAIL: negative exposure T0"
    q = mapped.raw_t0_h.quantile([0.25, 0.5, 0.75])
    print(
        f"final_treated={len(mapped):,}; t0_median_h={q.loc[0.5]:.2f}; IQR=[{q.loc[0.25]:.2f},{q.loc[0.75]:.2f}]"
    )
    print(
        f"t0_le_24h={int((mapped.raw_t0_h <= 24).sum()):,}; t0_gt_24h={int((mapped.raw_t0_h > 24).sum()):,}"
    )
    print(
        "PASS: every final treated T0 maps exactly to an accepted raw administration row"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1].lower() not in {"mimic", "eicu"}:
        raise SystemExit("usage: python probe_alb_ascertainment.py {mimic|eicu}")
    main(sys.argv[1].lower())
