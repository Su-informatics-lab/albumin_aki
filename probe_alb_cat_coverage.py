#!/usr/bin/env python3
"""Audit treated own-T0 albumin coverage without creating a static PS covariate."""

import os
import sys
from importlib.util import module_from_spec, spec_from_file_location

import pandas as pd


def config():
    spec = spec_from_file_location(
        "config", os.path.join(os.path.dirname(__file__), "00_config.py")
    )
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(db):
    cfg = config()
    cohort = pd.read_csv(os.path.join(cfg.RESULTS, f"did_all_{db}.csv"))
    assert "alb_cat" not in cohort.columns, "FAIL: static alb_cat exists in ETL cohort"
    labs = pd.read_csv(os.path.join(cfg.RESULTS, f"did_labs_all_{db}.csv"))
    labs = labs.rename(columns={"stay_id": "pid", "patientunitstayid": "pid"})
    treated = cohort[cohort.treated == 1][["pid", "alb_offset_h", "peri_admission_alb"]]
    alb = labs[labs.lab_name == "albumin"][["pid", "value", "offset_h"]].merge(
        treated, on="pid"
    )
    pre = (
        alb[alb.offset_h < alb.alb_offset_h]
        .sort_values("offset_h")
        .groupby("pid")
        .last()
    )
    assert (
        pre.offset_h < pre.alb_offset_h
    ).all(), "FAIL: selected albumin is not strictly pre-T0"
    low = int((pre.value < cfg.ALB_LOW_CUT).sum())
    normal = int((pre.value >= cfg.ALB_LOW_CUT).sum())
    missing = len(treated) - len(pre)
    assert low + normal + missing == len(treated)
    peri = alb[alb.offset_h.between(-48, 6)]
    after = set(peri[peri.offset_h >= peri.alb_offset_h].pid)
    print(
        f"cut_g_dl={cfg.ALB_LOW_CUT}; treated={len(treated):,}; low={low:,}; normal={normal:,}; missing={missing:,}"
    )
    print(f"current_peri_admission_window_post_infusion_patients={len(after):,}")
    print(
        "PASS: category audit uses most recent albumin strictly before own T0; no static alb_cat emitted"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1].lower() not in {"mimic", "eicu"}:
        raise SystemExit("usage: python probe_alb_cat_coverage.py {mimic|eicu}")
    main(sys.argv[1].lower())
