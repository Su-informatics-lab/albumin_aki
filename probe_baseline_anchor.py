#!/usr/bin/env python3
"""Assert canonical Phase 1 baseline value, tier, timestamp, and eGFR."""

import os
import sys
from importlib.util import module_from_spec, spec_from_file_location

import numpy as np
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
    cr = pd.read_csv(os.path.join(cfg.RESULTS, f"did_cr_all_{db}.csv"))
    cr = cr.rename(columns={"stay_id": "pid", "patientunitstayid": "pid"})
    required = {
        "baseline_cr",
        "baseline_cr_offset_h",
        "baseline_cr_source",
        "cr_ref_early",
        "cr_ref_early_offset_h",
        "cr_ref_early_source",
        "egfr",
    }
    assert required.issubset(
        cohort.columns
    ), f"FAIL: missing {sorted(required - set(cohort.columns))}"
    assert cohort.pid.is_unique, "FAIL: more than one cohort row per patient"
    assert (
        cohort[list(required)].notna().all().all()
    ), "FAIL: missing canonical baseline field"
    assert cohort.baseline_cr.between(
        cfg.CR_MIN, cfg.BASELINE_CR_MAX, inclusive="left"
    ).all(), "FAIL: baseline outside accepted range"
    treated = cohort[cohort.treated == 1]
    assert (
        treated.baseline_cr_offset_h < treated.alb_offset_h
    ).all(), "FAIL: treated baseline at/after own T0"
    assert set(treated.baseline_cr_source) <= {
        "icu_last_pre_albumin",
        "admit_window_fallback",
    }
    controls = cohort[cohort.treated == 0]
    assert set(controls.baseline_cr_source) == {
        "icu_first_reference"
    }, "FAIL: controls mislabeled as preoperative"
    assert set(cohort.cr_ref_early_source) <= {
        "icu_earliest",
        "admit_window_fallback",
    }, "FAIL: unexpected early-reference tier"
    assert (
        treated.cr_ref_early_offset_h <= treated.alb_offset_h
    ).all(), "FAIL: treated early reference after own T0"

    expected = (
        cfg.compute_egfr(cohort.baseline_cr, cohort.age, cohort.is_female)
        if hasattr(cfg, "compute_egfr")
        else None
    )
    if expected is None:
        crv, age, fem = (
            cohort.baseline_cr.to_numpy(float),
            cohort.age.to_numpy(float),
            cohort.is_female.to_numpy(bool),
        )
        kappa = np.where(fem, 0.7, 0.9)
        alpha = np.where(fem, -0.241, -0.302)
        ratio = crv / kappa
        expected = (
            142
            * np.minimum(ratio, 1) ** alpha
            * np.maximum(ratio, 1) ** -1.2
            * 0.9938**age
            * np.where(fem, 1.012, 1)
        )
    assert np.allclose(
        cohort.egfr, expected, rtol=1e-10, atol=1e-10
    ), "FAIL: eGFR not derived from baseline_cr"

    merged = cohort[["pid", "baseline_cr", "baseline_cr_offset_h"]].merge(
        cr[["pid", "labresult", "offset_h"]], on="pid", how="left"
    )
    exact = np.isclose(merged.baseline_cr, merged.labresult) & np.isclose(
        merged.baseline_cr_offset_h, merged.offset_h
    )
    found = set(merged.loc[exact, "pid"])
    assert found == set(
        cohort.pid
    ), "FAIL: baseline value/timestamp not traceable to timestamped Cr"
    early_merged = cohort[["pid", "cr_ref_early", "cr_ref_early_offset_h"]].merge(
        cr[["pid", "labresult", "offset_h"]], on="pid", how="left"
    )
    early_exact = np.isclose(
        early_merged.cr_ref_early, early_merged.labresult
    ) & np.isclose(early_merged.cr_ref_early_offset_h, early_merged.offset_h)
    assert set(early_merged.loc[early_exact, "pid"]) == set(
        cohort.pid
    ), "FAIL: early reference not traceable to timestamped Cr"

    for value_col, time_col, label in (
        ("baseline_cr", "baseline_cr_offset_h", "baseline"),
        ("cr_ref_early", "cr_ref_early_offset_h", "early reference"),
    ):
        selected = cohort[["pid", value_col, time_col]].merge(
            cr[["pid", "labresult", "offset_h"]], on="pid", how="left"
        )
        at_selected_time = selected[np.isclose(selected[time_col], selected.offset_h)]
        max_at_selected_time = (
            at_selected_time.groupby("pid").labresult.max().rename("expected_max")
        )
        checked = cohort[["pid", value_col]].merge(
            max_at_selected_time, left_on="pid", right_index=True, how="left"
        )
        assert (
            checked.expected_max.notna().all()
        ), f"FAIL: {label} selected timestamp absent from raw Cr"
        assert np.isclose(
            checked[value_col], checked.expected_max
        ).all(), f"FAIL: {label} is not maximum Cr at selected timestamp"

    treated_cr = cr.merge(
        treated[
            [
                "pid",
                "alb_offset_h",
                "cr_ref_early",
                "cr_ref_early_offset_h",
            ]
        ],
        on="pid",
    )
    pre = treated_cr[
        (treated_cr.offset_h > treated_cr.cr_ref_early_offset_h)
        & (treated_cr.offset_h <= treated_cr.alb_offset_h)
    ]
    prevalent = set(
        pre[
            (pre.labresult - pre.cr_ref_early >= 0.3)
            | (pre.labresult / pre.cr_ref_early >= 1.5)
        ].pid
    )
    print(
        "source_counts="
        + str(cohort.groupby(["treated", "baseline_cr_source"]).size().to_dict())
    )
    print(
        "baseline_cr="
        + str(
            cohort.baseline_cr.describe(percentiles=[0.25, 0.5, 0.75])
            .round(3)
            .to_dict()
        )
    )
    print(
        "baseline_offset_h="
        + str(
            cohort.baseline_cr_offset_h.describe(percentiles=[0.25, 0.5, 0.75])
            .round(3)
            .to_dict()
        )
    )
    print(
        f"prevalent_severe_renal_screen_baseline_ge_4=0; fallback_n={(cohort.baseline_cr_source == 'admit_window_fallback').sum():,}"
    )
    print(
        "early_reference_source_counts="
        + str(cohort.cr_ref_early_source.value_counts().to_dict())
    )
    print(
        f"treated_prevalent_aki_at_own_t0={len(prevalent):,}/{len(treated):,} "
        "(descriptive only; not excluded)"
    )
    print(
        "PASS: two-reference values, max-at-selected-time tie rule, tiers, "
        "timing, raw-stream trace, and eGFR invariants"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1].lower() not in {"mimic", "eicu"}:
        raise SystemExit("usage: python probe_baseline_anchor.py {mimic|eicu}")
    main(sys.argv[1].lower())
