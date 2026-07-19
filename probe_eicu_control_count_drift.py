#!/usr/bin/env python3
"""Verify the approved eICU control tie rule; aggregate output only.

Not part of the primary pipeline. Reconstructs the pre-ESKD cardiac cohort,
accepted albumin exposure pool, and control creatinine eligibility, then asks
whether multiple creatinine values at the earliest ICU offset disagree across
the frozen baseline Cr <4 threshold. It never writes patient-level data.
"""

import os
from importlib.util import module_from_spec, spec_from_file_location

import pandas as pd


def load_etl():
    spec = spec_from_file_location(
        "albumin_etl", os.path.join(os.path.dirname(__file__), "01_etl.py")
    )
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    etl = load_etl()
    patient = pd.read_csv(
        etl.gz(os.path.join(etl.EICU_ROOT, "patient.csv.gz")), low_memory=False
    )
    patient.columns = patient.columns.str.lower()
    mask = etl.matches_any(
        patient.apacheadmissiondx, etl.CARDIAC_DX_PATTERNS
    ) | patient.unittype.isin(etl.CARDIAC_UNIT_TYPES)
    cardiac = patient[mask].copy()
    cardiac["age_num"] = pd.to_numeric(
        cardiac.age.astype(str).str.replace(">", ""), errors="coerce"
    ).fillna(90)
    cardiac = cardiac[cardiac.age_num >= etl.MIN_AGE]
    cardiac = (
        cardiac.sort_values("hospitaladmitoffset")
        .groupby("uniquepid")
        .first()
        .reset_index()
    )
    pids = set(cardiac.patientunitstayid)

    lab = etl.load_filtered("lab", etl.EICU_ROOT, pids)
    med = etl.load_filtered("medication", etl.EICU_ROOT, pids)
    diag = etl.load_filtered("diagnosis", etl.EICU_ROOT, pids)
    pasthx = etl.load_filtered("pastHistory", etl.EICU_ROOT, pids)

    eskd = set()
    if len(pasthx) and "pasthistorypath" in pasthx:
        eskd |= set(
            pasthx[
                pasthx.patientunitstayid.isin(pids)
                & etl.matches_any(pasthx.pasthistorypath, etl.ESKD_PATTERNS)
            ].patientunitstayid
        )
    if len(diag):
        eskd |= set(
            diag[
                diag.patientunitstayid.isin(pids)
                & etl.matches_any(diag.diagnosisstring, etl.ESKD_PATTERNS)
            ].patientunitstayid
        )
    cardiac = cardiac[~cardiac.patientunitstayid.isin(eskd)]
    pids = set(cardiac.patientunitstayid)

    cancelled = (
        med.get("drugordercancelled", pd.Series("", index=med.index))
        .astype(str)
        .str.contains("Yes", na=False)
    )
    alb_m = med[
        ~cancelled
        & med.patientunitstayid.isin(pids)
        & etl.matches_any(med.drugname, etl.ALB_INFUSION_PATTERNS)
        & (med.drugstartoffset >= 0)
    ].copy()
    if "routeadmin" in alb_m:
        alb_m = alb_m[
            alb_m.routeadmin.str.lower().str.contains(
                etl.ALB_IV_ROUTE_PATTERNS, na=False
            )
            | alb_m.routeadmin.isna()
        ]
    treated = set(alb_m.patientunitstayid)
    io = etl.load_filtered("intakeOutput", etl.EICU_ROOT, pids)
    for col in ("celllabel", "cellpath"):
        if col in io:
            treated |= set(
                io[
                    io.patientunitstayid.isin(pids)
                    & etl.matches_any(io[col], etl.ALB_IO_PATTERNS)
                    & (io.intakeoutputoffset >= 0)
                ].patientunitstayid
            )
            break
    controls = pids - treated

    cr = lab[
        lab.patientunitstayid.isin(controls)
        & lab.labname.str.lower().str.contains("creatinine", na=False)
        & lab.labresult.between(etl.CR_MIN, etl.CR_MAX)
        & (lab.labresultoffset >= 0)
    ][["patientunitstayid", "labresultoffset", "labresult"]].copy()
    sizes = cr.groupby("patientunitstayid").size()
    eligible = set(sizes[sizes >= 2].index)
    cr = cr[cr.patientunitstayid.isin(eligible)]
    earliest_offset = cr.groupby("patientunitstayid").labresultoffset.min()
    at_earliest = cr.merge(
        earliest_offset.rename("earliest_offset"),
        left_on="patientunitstayid",
        right_index=True,
    )
    at_earliest = at_earliest[
        at_earliest.labresultoffset == at_earliest.earliest_offset
    ]
    summary = at_earliest.groupby("patientunitstayid").agg(
        n=("labresult", "size"),
        min_cr=("labresult", "min"),
        max_cr=("labresult", "max"),
    )
    tied = summary[summary.n > 1]
    discordant = tied[
        (tied.min_cr < etl.BASELINE_CR_MAX) & (tied.max_cr >= etl.BASELINE_CR_MAX)
    ]
    min_rule_controls = int((summary.min_cr < etl.BASELINE_CR_MAX).sum())
    max_rule_controls = int((summary.max_cr < etl.BASELINE_CR_MAX).sum())

    print(f"post_eskd={len(pids):,}")
    print(f"treated_any_iv_albumin={len(treated):,}")
    print(f"control_no_iv_albumin={len(controls):,}")
    print(f"control_has_2cr={len(eligible):,}")
    print(f"earliest_offset_tied_patients={len(tied):,}")
    print(f"threshold_discordant_ties={len(discordant):,}")
    print(f"eligible_if_tie_min_cr={min_rule_controls:,}")
    print(f"eligible_if_tie_max_cr={max_rule_controls:,}")
    assert len(eligible) == 17149, "FAIL: upstream control Cr eligibility drifted"
    assert len(treated) == 3778, "FAIL: post-ESKD exposure count drifted"
    assert min_rule_controls == 16780, "FAIL: min-rule sensitivity count drifted"
    assert max_rule_controls == 16778, "FAIL: approved max-rule count drifted"
    assert len(discordant) == 2, "FAIL: threshold-discordant tie count drifted"
    print(
        "PASS: approved maximum-at-earliest-time rule gives 16,778 controls; "
        "minimum-at-earliest-time sensitivity gives 16,780"
    )


if __name__ == "__main__":
    main()
