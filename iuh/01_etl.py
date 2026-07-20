#!/usr/bin/env python3
"""IUH external-validation ETL for frozen albumin_aki v3.3."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import importlib

cfg = importlib.import_module("00_config")

BASE = Path(
    os.getenv(
        "IUH_BASE",
        "/N/project/Analgesia_management/IUH_DATA_2025/2019_2025",
    )
)
PROCESSED = BASE / "processed"
DERIVED = BASE / "derived"
RESULTS = Path(
    os.path.expanduser(os.getenv("ALBUMIN_AKI_RESULTS", "~/albumin_aki/results"))
)
RESULTS.mkdir(parents=True, exist_ok=True)

KEEP_CVDSC = {
    "Coronary Artery Bypass Graft",
    "Coronary Artery Bypass Graft Off Pump",
    "Coronary Artery Bypass Graft REDO",
    "Coronary Art Bypass Graft W Aortic Valve",
    "Coronary Art Bypass Graft W Aortic Valve REDO",
    "Aortic Valve Replacement",
    "Aortic Valve Replacement REDO",
    "Aortic Valve Replacement Minimally Invasive",
    "Aortic Valve Repair",
    "Aortic Valvulotomy",
    "Ross Procedure",
    "Mitral Valve Replacement",
    "Mitral Valve Replacement REDO",
    "Mitral Valve Repair DaVinci",
    "Mitral Valve Repair",
    "Mitral Valve Repair Minimally Invasive",
    "Mitral Valve Replace Minimally Invasive",
    "Tricuspid Valve Replacement",
    "Tricuspid Valve Repair",
    "Tricuspid Repair Minimally Invasive",
    "Pulmonary Valve Replacement",
    "Aortic Arch Ascending Aneurysm Repair",
    "Aortic Arch Ascend Aneurysm Rep REDO",
    "Aortic Root Reconstruction",
    "Aortic Root Replacement",
    "Bental Procedure",
    "Aortic Arch Augmentation",
    "Aortic Desc Thoracic Aneurysm Repair",
    "Atrial Septal Defect Repair",
    "Ventricular Septal Defect Repair",
    "Atrial Ventricular Canal Repair",
    "Right Ventricle Outflow Tract Recon",
    "Tetralogy Of Fallot Repair",
    "Vascular Ring Division",
    "PAPVR",
    "Coronary Art Anomalous Ligate Transfer",
    "Subaortic Membrane Resection",
    "Myotomy Cardiovascular",
    "Pericardiectomy",
}
CABG = {
    "Coronary Artery Bypass Graft",
    "Coronary Artery Bypass Graft Off Pump",
    "Coronary Artery Bypass Graft REDO",
    "Coronary Art Bypass Graft W Aortic Valve",
    "Coronary Art Bypass Graft W Aortic Valve REDO",
}
VALVE = {
    x for x in KEEP_CVDSC if "Valve" in x or "Valvulotomy" in x or x == "Ross Procedure"
}
AORTIC = {
    x
    for x in KEEP_CVDSC
    if ("Aortic Arch" in x or "Aortic Root" in x or "Thoracic Aneurysm" in x)
}

LAB_EVENTS = {
    "creatinine": {"Creatinine SerPl QN"},
    "egfr_reported": {
        "Estimated GFR (CKD-EPI, no race)",
        "Estimated GFR (CKD-EPI)",
    },
    "albumin": {"Albumin SerPl QN"},
    "lactate": {
        "Lactate Venous Pl QN",
        "Lactate Bld Venous QN",
        "Lactate Arterial, ePOC",
        "Lactate Arterial, POC",
        "Lactate Venous, POC",
        "Lactate Venous, ePOC",
        "Lactate Arterial Pl QN",
        "Lactate Bld Arterial QN",
        "Lactate, GEM POC",
        "Lactate, ePOC",
        "Lactate, POC",
        "Lactic Acid, Plasma",
    },
    "hemoglobin": {"Hemoglobin"},
}


def read_filtered(path: Path, ids: set[str], columns: list[str]) -> pd.DataFrame:
    pf = pq.ParquetFile(path)
    chunks = []
    for i in range(pf.metadata.num_row_groups):
        x = pf.read_row_group(i, columns=columns).to_pandas()
        x = x[x["subject_id"].isin(ids)]
        if not x.empty:
            chunks.append(x)
    return (
        pd.concat(chunks, ignore_index=True)
        if chunks
        else pd.DataFrame(columns=columns)
    )


def compute_egfr(cr: float, age: float, female: int) -> float:
    if pd.isna(cr) or pd.isna(age) or cr <= 0 or age <= 0:
        return np.nan
    k = 0.7 if female else 0.9
    alpha = -0.241 if female else -0.302
    value = 142 * min(cr / k, 1) ** alpha * max(cr / k, 1) ** -1.2 * 0.9938**age
    return value * (1.012 if female else 1)


def matches_icd(code: str, patterns: dict[int, list[str]], version: int) -> bool:
    code = str(code).replace(".", "").upper()
    return any(code.startswith(p.upper()) for p in patterns.get(version, []))


def max_at_time(x: pd.DataFrame, earliest: bool) -> pd.Series | None:
    if x.empty:
        return None
    selected = x["offset_h"].min() if earliest else x["offset_h"].max()
    tied = x[x["offset_h"] == selected]
    row = tied.loc[tied["value"].idxmax()].copy()
    return row


def make_intervals(
    x: pd.DataFrame, time_col: str, group_cols: list[str]
) -> pd.DataFrame:
    if x.empty:
        return pd.DataFrame(columns=["pid", "t_start_h", "t_end_h"])
    rows = []
    for _, g in x.sort_values(time_col).groupby(group_cols, dropna=False):
        times = g[time_col].dropna().sort_values().to_numpy()
        if not len(times):
            continue
        start = prev = float(times[0])
        for current in times[1:]:
            current = float(current)
            if current - prev > 4:
                rows.append((g.iloc[0].subject_id, start, prev + 2))
                start = current
            prev = current
        rows.append((g.iloc[0].subject_id, start, prev + 2))
    return pd.DataFrame(rows, columns=["pid", "t_start_h", "t_end_h"])


def main() -> None:
    consort: dict[str, int] = {}
    proc = pd.read_parquet(PROCESSED / "Procedure.parquet")
    consort["total_procedure_rows"] = len(proc)
    proc = proc[proc.SurgicalProcedureCVDSC.isin(KEEP_CVDSC)].copy()
    consort["accepted_cardiac_procedure_rows"] = len(proc)
    proc["SurgicalStartDTS"] = pd.to_datetime(proc.SurgicalStartDTS, errors="coerce")
    proc["SurgicalStopDTS"] = pd.to_datetime(proc.SurgicalStopDTS, errors="coerce")
    proc = proc.dropna(subset=["subject_id", "hadm_id", "SurgicalStopDTS"])
    cardiac_hadm = proc.sort_values("SurgicalStartDTS").drop_duplicates(
        ["subject_id", "hadm_id"]
    )
    consort["cardiac_admissions"] = len(cardiac_hadm)

    icu = pd.read_parquet(DERIVED / "icustay_hourhrbp.parquet")
    for col in ["unitin", "unitout"]:
        icu[col] = pd.to_datetime(icu[col], errors="coerce")
    cohort = cardiac_hadm.merge(icu, on=["subject_id", "hadm_id"], how="inner")
    cohort = cohort[cohort.unitout > cohort.SurgicalStopDTS].copy()
    cohort["postop_start"] = cohort[["unitin", "SurgicalStopDTS"]].max(axis=1)
    cohort = cohort.sort_values("postop_start").drop_duplicates("subject_id")
    consort["first_postop_icu_patients"] = len(cohort)

    labels = proc.groupby("subject_id").SurgicalProcedureCVDSC.agg(set)
    cohort["surg_cabg"] = cohort.subject_id.map(
        lambda p: int(bool(labels.get(p, set()) & CABG))
    )
    cohort["surg_valve"] = cohort.subject_id.map(
        lambda p: int(bool(labels.get(p, set()) & VALVE))
    )
    cohort["surg_combined"] = (
        (cohort.surg_cabg == 1) & (cohort.surg_valve == 1)
    ).astype(int)
    cohort["surg_aortic"] = cohort.subject_id.map(
        lambda p: int(bool(labels.get(p, set()) & AORTIC))
    )
    cohort["surgery_type"] = np.select(
        [
            cohort.surg_combined == 1,
            cohort.surg_cabg == 1,
            cohort.surg_valve == 1,
            cohort.surg_aortic == 1,
        ],
        ["combined", "cabg", "valve", "aortic"],
        default="other_cardiac",
    )

    demo = pd.read_parquet(DERIVED / "demographics.parquet")
    cohort = cohort.merge(
        demo[
            [
                "subject_id",
                "hadm_id",
                "DOB",
                "Sex",
                "Deceased",
                "ArriveDTS",
                "DischargeDTS",
                "DischargeDisposition",
            ]
        ],
        on=["subject_id", "hadm_id"],
        how="left",
    )
    for col in ["DOB", "Deceased", "ArriveDTS", "DischargeDTS"]:
        cohort[col] = pd.to_datetime(cohort[col], errors="coerce")
    cohort["age"] = (cohort.postop_start - cohort.DOB).dt.days / 365.25
    cohort["is_female"] = (cohort.Sex == "Female").astype(int)
    cohort = cohort[cohort.age >= 18].copy()
    consort["adult"] = len(cohort)
    cohort["hosp_mortality"] = (
        cohort.DischargeDisposition.fillna("").str.lower() == "patient has expired"
    ).astype(int)
    cohort["death_offset_h"] = np.where(
        cohort.hosp_mortality == 1,
        (cohort.Deceased - cohort.postop_start).dt.total_seconds() / 3600,
        np.nan,
    )
    cohort["icu_discharge_h"] = (
        cohort.unitout - cohort.postop_start
    ).dt.total_seconds() / 3600
    cohort["icu_outcome"] = np.where(
        cohort.hosp_mortality == 1, "expired", "discharged"
    )

    ids = set(cohort.subject_id)
    dx = read_filtered(PROCESSED / "Dx.parquet", ids, ["subject_id", "ICD", "DxDate"])
    dx["DxDate"] = pd.to_datetime(dx.DxDate, errors="coerce")
    dx = dx.merge(cohort[["subject_id", "postop_start"]], on="subject_id")
    dx = dx[dx.DxDate < dx.postop_start].copy()
    dx["version"] = np.where(dx.ICD.fillna("").str.match(r"^[A-Za-z]"), 10, 9)
    for name, patterns in cfg.MIMIC_COMORB_ICD.items():
        positive = set(
            dx.loc[
                [
                    matches_icd(code, patterns, version)
                    for code, version in zip(dx.ICD, dx.version)
                ],
                "subject_id",
            ]
        )
        cohort[name] = cohort.subject_id.isin(positive).astype(int)
    eskd = set()
    for version, patterns in cfg.ESKD_ICD.items():
        eskd |= set(
            dx.loc[
                [
                    matches_icd(code, {version: patterns}, ver)
                    for code, ver in zip(dx.ICD, dx.version)
                ],
                "subject_id",
            ]
        )
    crrt = pd.read_parquet(PROCESSED / "CRRT.parquet")
    crrt = crrt[crrt.subject_id.isin(ids)].copy()
    crrt["OrderDate"] = pd.to_datetime(crrt.OrderDate, errors="coerce")
    crrt = crrt.merge(cohort[["subject_id", "postop_start"]], on="subject_id")
    eskd |= set(crrt.loc[crrt.OrderDate < crrt.postop_start, "subject_id"])
    cohort = cohort[~cohort.subject_id.isin(eskd)].copy()
    consort["after_eskd_exclusion"] = len(cohort)
    ids = set(cohort.subject_id)

    hwb = read_filtered(
        PROCESSED / "HWB.parquet",
        ids,
        ["subject_id", "Event", "Result", "EventDT"],
    )
    hwb["value"] = pd.to_numeric(hwb.Result, errors="coerce")
    hwb["EventDT"] = pd.to_datetime(hwb.EventDT, errors="coerce")
    hwb = hwb.merge(cohort[["subject_id", "postop_start"]], on="subject_id")
    hwb["distance"] = (hwb.EventDT - hwb.postop_start).abs()
    wt = (
        hwb[
            hwb.Event.isin(["Weight for Calculation", "Weight Measured"])
            & hwb.value.between(20, 400)
        ]
        .sort_values("distance")
        .drop_duplicates("subject_id")
        .set_index("subject_id")
        .value
    )
    ht = (
        hwb[(hwb.Event == "Height/Length Measured") & hwb.value.between(100, 250)]
        .sort_values("distance")
        .drop_duplicates("subject_id")
        .set_index("subject_id")
        .value
    )
    cohort["bmi"] = cohort.subject_id.map(wt) / (cohort.subject_id.map(ht) / 100) ** 2
    cohort.loc[~cohort.bmi.between(10, 80), "bmi"] = np.nan

    lab = read_filtered(
        PROCESSED / "Lab.parquet",
        ids,
        ["subject_id", "hadm_id", "Event", "Result", "Result_num", "EventDT"],
    )
    lab = lab[lab.Event.isin(set().union(*LAB_EVENTS.values()))].copy()
    lab["EventDT"] = pd.to_datetime(lab.EventDT, errors="coerce")
    lab["value"] = pd.to_numeric(lab.Result_num, errors="coerce")
    report = lab.Event.isin(LAB_EVENTS["egfr_reported"])
    parsed_report = pd.to_numeric(
        lab.loc[report, "Result"].astype(str).str.replace(">", "", regex=False),
        errors="coerce",
    )
    lab.loc[report, "value"] = lab.loc[report, "value"].fillna(parsed_report)
    lab = lab.merge(
        cohort[["subject_id", "hadm_id", "postop_start"]],
        on=["subject_id", "hadm_id"],
    )
    lab["offset_h"] = (lab.EventDT - lab.postop_start).dt.total_seconds() / 3600
    lab["lab_name"] = ""
    for name, events in LAB_EVENTS.items():
        lab.loc[lab.Event.isin(events), "lab_name"] = name

    cr = lab[
        (lab.lab_name == "creatinine") & lab.value.between(cfg.CR_MIN, cfg.CR_MAX)
    ].copy()
    references = []
    for row in cohort.itertuples():
        x = cr[cr.subject_id == row.subject_id]
        post = x[(x.offset_h >= 0) & (x.EventDT <= row.unitout)]
        early = max_at_time(post, earliest=True)
        early_source = "icu_earliest"
        if early is None:
            pre = x[(x.EventDT >= row.ArriveDTS) & (x.offset_h < 0)]
            early = max_at_time(pre, earliest=False)
            early_source = "admit_window_fallback"
        if early is None:
            continue
        references.append(
            {
                "subject_id": row.subject_id,
                "cr_ref_early": early.value,
                "cr_ref_early_offset_h": early.offset_h,
                "cr_ref_early_source": early_source,
            }
        )
    refs = pd.DataFrame(references)
    cohort = cohort.merge(refs, on="subject_id", how="inner")
    consort["with_early_creatinine"] = len(cohort)

    io = read_filtered(
        PROCESSED / "IO.parquet",
        set(cohort.subject_id),
        ["subject_id", "hadm_id", "IO", "Event", "Vol", "IOdate", "Type"],
    )
    io["Vol"] = pd.to_numeric(io.Vol, errors="coerce")
    io["IOdate"] = pd.to_datetime(io.IOdate, errors="coerce")
    io = io[
        io.IO.fillna("").str.contains("albumin", case=False)
        & (io.Event == "MED INTAKE")
        & (io.Vol > 0)
    ].copy()
    io = io.merge(
        cohort[["subject_id", "hadm_id", "postop_start", "unitout"]],
        on=["subject_id", "hadm_id"],
    )
    io["offset_h"] = (io.IOdate - io.postop_start).dt.total_seconds() / 3600
    io = io[(io.offset_h >= 0) & (io.IOdate <= io.unitout)]
    first_alb = io.sort_values(["subject_id", "offset_h"]).drop_duplicates("subject_id")
    cohort["alb_offset_h"] = cohort.subject_id.map(
        first_alb.set_index("subject_id").offset_h
    )
    cohort["treated"] = cohort.alb_offset_h.notna().astype(int)
    cohort["alb_offset_min"] = cohort.alb_offset_h * 60
    product = first_alb.set_index("subject_id").IO.astype(str)
    cohort["alb_product"] = cohort.subject_id.map(product).map(
        lambda x: (
            "25pct"
            if isinstance(x, str) and "25" in x
            else "5pct" if isinstance(x, str) and "5" in x else "unspecified"
        )
    )
    totals = io.merge(
        first_alb[["subject_id", "offset_h"]], on="subject_id", suffixes=("", "_first")
    )
    totals = totals[totals.offset_h <= totals.offset_h_first + 24]
    cohort["alb_total_ml_24h"] = cohort.subject_id.map(
        totals.groupby("subject_id").Vol.sum()
    )
    consort["accepted_iv_albumin_treated"] = int(cohort.treated.sum())

    baseline_rows = []
    report_rows = []
    for row in cohort.itertuples():
        x = cr[cr.subject_id == row.subject_id]
        if row.treated == 1:
            candidate = x[(x.offset_h >= 0) & (x.offset_h < row.alb_offset_h)]
            baseline = max_at_time(candidate, earliest=False)
            source = "icu_latest_strict_pre_albumin"
            if baseline is None:
                candidate = x[(x.offset_h < 0) & (x.EventDT >= row.ArriveDTS)]
                baseline = max_at_time(candidate, earliest=False)
                source = "admit_window_fallback"
        else:
            baseline = (
                x[x.offset_h == row.cr_ref_early_offset_h].sort_values("value").iloc[-1]
            )
            source = row.cr_ref_early_source
        if baseline is None:
            continue
        baseline_rows.append(
            {
                "subject_id": row.subject_id,
                "baseline_cr": baseline.value,
                "baseline_cr_offset_h": baseline.offset_h,
                "baseline_cr_source": source,
            }
        )
        er = lab[
            (lab.subject_id == row.subject_id) & (lab.lab_name == "egfr_reported")
        ].copy()
        if not er.empty:
            er["distance"] = (er.offset_h - baseline.offset_h).abs()
            nearest = er.sort_values(["distance", "offset_h"]).iloc[0]
            if nearest.distance <= 6:
                report_rows.append(
                    {
                        "subject_id": row.subject_id,
                        "egfr_reported": nearest.value,
                        "egfr_reported_offset_h": nearest.offset_h,
                        "egfr_reported_distance_h": nearest.distance,
                    }
                )
    cohort = cohort.merge(pd.DataFrame(baseline_rows), on="subject_id", how="inner")
    cohort = cohort[cohort.baseline_cr < cfg.BASELINE_CR_MAX].copy()
    cohort = cohort.merge(pd.DataFrame(report_rows), on="subject_id", how="left")
    cohort["first_cr"] = cohort.baseline_cr
    cohort["egfr"] = cohort.apply(
        lambda r: compute_egfr(r.baseline_cr, r.age, r.is_female), axis=1
    )
    consort["final_analytic_source"] = len(cohort)
    consort["final_treated"] = int(cohort.treated.sum())
    consort["final_never_treated"] = int((cohort.treated == 0).sum())

    crrt["offset_h"] = (crrt.OrderDate - crrt.postop_start).dt.total_seconds() / 3600
    first_rrt = (
        crrt[crrt.offset_h >= 0]
        .sort_values("offset_h")
        .drop_duplicates("subject_id")
        .set_index("subject_id")
        .offset_h
    )
    cohort["rrt_offset_h"] = cohort.subject_id.map(first_rrt)
    cohort["has_rrt"] = cohort.rrt_offset_h.notna().astype(int)
    cohort["pid"] = cohort.subject_id
    cohort["hadm_id"] = cohort.hadm_id
    cohort["peri_admission_alb"] = np.nan
    cohort["vent_arrhythmia"] = np.nan
    for drug in cfg.CHRONIC_DRUG_CLASSES:
        cohort[drug] = np.nan

    ids = set(cohort.subject_id)
    cr_out = cr[
        cr.subject_id.isin(ids) & (cr.value <= cfg.CR_POST_PLAUSIBLE_MAX)
    ].copy()
    cr_out = cr_out.rename(columns={"subject_id": "stay_id", "value": "labresult"})
    cr_out[["stay_id", "labresult", "offset_h"]].to_csv(
        RESULTS / "did_cr_all_iuh.csv", index=False
    )
    labs_out = lab[
        lab.subject_id.isin(ids)
        & lab.lab_name.isin(["albumin", "lactate", "hemoglobin"])
        & (lab.offset_h >= 0)
    ][["subject_id", "lab_name", "value", "offset_h"]].copy()

    vit = read_filtered(
        PROCESSED / "Vitals.parquet",
        ids,
        ["subject_id", "hadm_id", "Event", "Result", "EventDT"],
    )
    vit = vit[
        vit.Event.isin(
            [
                "Heart Rate Monitored",
                "Mean Arterial Pressure, Cuff",
                "Mean Arterial Pressure #1 Calculated",
            ]
        )
    ].copy()
    vit["value"] = pd.to_numeric(vit.Result, errors="coerce")
    vit["EventDT"] = pd.to_datetime(vit.EventDT, errors="coerce")
    vit = vit.merge(
        cohort[["subject_id", "hadm_id", "postop_start"]],
        on=["subject_id", "hadm_id"],
    )
    vit["offset_h"] = (vit.EventDT - vit.postop_start).dt.total_seconds() / 3600
    hr = vit[(vit.Event == "Heart Rate Monitored") & vit.value.between(20, 300)][
        ["subject_id", "value", "offset_h"]
    ].copy()
    hr["lab_name"] = "heartrate"
    labs_out = pd.concat(
        [labs_out, hr[["subject_id", "lab_name", "value", "offset_h"]]]
    )
    labs_out = labs_out.rename(columns={"subject_id": "stay_id"})
    labs_out.to_csv(RESULTS / "did_labs_all_iuh.csv", index=False)
    map_out = vit[
        vit.Event.str.startswith("Mean Arterial Pressure") & vit.value.between(20, 200)
    ][["subject_id", "offset_h", "value"]].rename(
        columns={"subject_id": "pid", "value": "map"}
    )
    map_out.to_csv(RESULTS / "strm_map_iuh.csv", index=False)

    vaso = read_filtered(
        PROCESSED / "Vasopressor.parquet",
        ids,
        ["subject_id", "hadm_id", "EventDT", "MEDICATION_NAME"],
    )
    vaso["EventDT"] = pd.to_datetime(vaso.EventDT, errors="coerce")
    vaso = vaso.merge(
        cohort[["subject_id", "hadm_id", "postop_start"]],
        on=["subject_id", "hadm_id"],
    )
    vaso["offset_h"] = (vaso.EventDT - vaso.postop_start).dt.total_seconds() / 3600
    make_intervals(vaso, "offset_h", ["subject_id", "MEDICATION_NAME"]).to_csv(
        RESULTS / "strm_vaso_iuh.csv", index=False
    )
    vent = read_filtered(
        PROCESSED / "Vent.parquet",
        ids,
        ["subject_id", "hadm_id", "EventDT"],
    )
    vent["EventDT"] = pd.to_datetime(vent.EventDT, errors="coerce")
    vent = vent.merge(
        cohort[["subject_id", "hadm_id", "postop_start"]],
        on=["subject_id", "hadm_id"],
    )
    vent["offset_h"] = (vent.EventDT - vent.postop_start).dt.total_seconds() / 3600
    make_intervals(vent, "offset_h", ["subject_id"]).to_csv(
        RESULTS / "strm_vent_iuh.csv", index=False
    )
    cohort[["pid", "surg_aortic"]].to_csv(RESULTS / "surg_iuh.csv", index=False)

    for col in cfg.ALL_PATIENTS_COLS:
        if col not in cohort:
            cohort[col] = np.nan
    extra = [
        "egfr_reported",
        "egfr_reported_offset_h",
        "egfr_reported_distance_h",
    ]
    cohort[cfg.ALL_PATIENTS_COLS + extra].to_csv(
        RESULTS / "did_all_iuh.csv", index=False
    )

    # Descriptive own-T0 prevalent-AKI screen.
    prevalent = 0
    for row in cohort[cohort.treated == 1].itertuples():
        x = cr[
            (cr.subject_id == row.subject_id)
            & (cr.offset_h > row.cr_ref_early_offset_h)
            & (cr.offset_h <= row.alb_offset_h)
        ]
        prevalent += int(
            (
                (x.value - row.cr_ref_early >= 0.3)
                | (x.value / row.cr_ref_early >= 1.5)
            ).any()
        )
    consort["treated_prevalent_aki_at_own_t0_descriptive"] = prevalent
    pd.DataFrame([{"step": step, "n": n} for step, n in consort.items()]).to_csv(
        RESULTS / "did_consort_iuh.csv", index=False
    )

    computed = cohort.dropna(subset=["egfr", "egfr_reported"]).copy()
    computed["computed_stratum"] = pd.cut(
        computed.egfr,
        [-np.inf, 60, 90, np.inf],
        labels=["G3plus", "G2", "G1"],
        right=False,
    )
    computed["reported_stratum"] = pd.cut(
        computed.egfr_reported,
        [-np.inf, 60, 90, np.inf],
        labels=["G3plus", "G2", "G1"],
        right=False,
    )
    egfr_summary = pd.DataFrame(
        [
            {
                "n_total": len(cohort),
                "n_paired_within_6h": len(computed),
                "pearson_r": computed.egfr.corr(computed.egfr_reported),
                "median_reported_minus_computed": (
                    computed.egfr_reported - computed.egfr
                ).median(),
                "same_stratum_n": (
                    computed.computed_stratum == computed.reported_stratum
                ).sum(),
                "same_stratum_rate": (
                    computed.computed_stratum == computed.reported_stratum
                ).mean(),
            }
        ]
    )
    egfr_summary.to_csv(RESULTS / "iuh_egfr_concordance_summary.csv", index=False)
    pd.crosstab(
        computed.computed_stratum,
        computed.reported_stratum,
        dropna=False,
    ).to_csv(RESULTS / "iuh_egfr_stratum_crosstab.csv")
    print(pd.DataFrame([consort]).T.to_string(header=False))
    print(egfr_summary.to_string(index=False))


if __name__ == "__main__":
    main()
