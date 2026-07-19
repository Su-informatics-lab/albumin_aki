#!/usr/bin/env python3
"""
01_etl.py — Cohort construction for Albumin -> CSA-AKI study
Adapted from mg_aki/01_etl.py v6.0 (risk-set design)

Outputs per database:
  did_all_{db}.csv       — All patients, time-invariant covariates
  did_labs_all_{db}.csv  — All lab/vital measurements with timestamps
  did_cr_all_{db}.csv    — All creatinine measurements with timestamps
  did_consort_{db}.csv   — Ordered aggregate CONSORT flow

Usage:
  python 01_etl.py              # both databases
  python 01_etl.py eicu         # eICU only
  python 01_etl.py mimic        # MIMIC only
"""

import os
import sys
from importlib.util import module_from_spec, spec_from_file_location

import duckdb
import numpy as np
import pandas as pd

_spec = spec_from_file_location(
    "config", os.path.join(os.path.dirname(__file__), "00_config.py")
)
cfg = module_from_spec(_spec)
_spec.loader.exec_module(cfg)
for _k in dir(cfg):
    if not _k.startswith("_"):
        globals()[_k] = getattr(cfg, _k)

_BMI_ITEMS = {226730, 226512}
_BMI_MAP = [(226730, "_ht"), (226512, "_wt")]


# ═══════════════════════════════════════════════════════════════════
# HELPERS (identical to mg_aki)
# ═══════════════════════════════════════════════════════════════════
def _resolve(root, name):
    for ext in [".csv.gz", ".csv"]:
        p = os.path.join(root, name + ext)
        if os.path.exists(p):
            return p
    return None


def load_filtered(name, root, pids=None, pid_col="patientunitstayid", extra_where=None):
    p = _resolve(root, name)
    if p is None:
        print(f"  WARN: {name} not found in {root}")
        return pd.DataFrame()
    con = duckdb.connect()
    try:
        clauses = []
        if pids is not None:
            pid_df = pd.DataFrame({"_pid": pd.array(list(pids), dtype="int64")})
            con.register("_pf", pid_df)
            clauses.append(f'"{pid_col}" IN (SELECT _pid FROM _pf)')
        if extra_where:
            clauses.append(f"({extra_where})")
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        df = con.execute(
            f"SELECT * FROM read_csv_auto('{p}', header=true, ignore_errors=true){where}"
        ).df()
        df.columns = df.columns.str.lower()
        print(f"  {name}: {len(df):,} rows")
        return df
    finally:
        con.close()


def gz(p):
    return p if os.path.exists(p) else p.replace(".csv.gz", ".csv")


def matches_any(series, patterns):
    s = series.astype(str).str.lower()
    mask = pd.Series(False, index=series.index)
    for p in patterns:
        mask |= s.str.contains(p.lower(), na=False)
    return mask


def compute_egfr(cr, age, is_female):
    cr, age, fem = (
        np.asarray(cr, float),
        np.asarray(age, float),
        np.asarray(is_female, bool),
    )
    kappa = np.where(fem, 0.7, 0.9)
    alpha = np.where(fem, -0.241, -0.302)
    r = cr / kappa
    return (
        142
        * np.power(np.minimum(r, 1.0), alpha)
        * np.power(np.maximum(r, 1.0), -1.200)
        * np.power(0.9938, age)
        * np.where(fem, 1.012, 1.0)
    )


def matches_icd(dx_df, hadm_ids, code_map):
    sub = dx_df[dx_df.hadm_id.isin(hadm_ids)]
    hits = set()
    for ver, prefixes in code_map.items():
        v = sub[sub.icd_version == ver]
        for p in prefixes:
            hits |= set(v[v.icd_code.str.startswith(p)].hadm_id)
    return hits


def pct(n, total):
    return f"{n:,} ({100*n/max(total,1):.1f}%)"


def desc(s, name):
    v = s.dropna()
    if len(v) == 0:
        print(f"    {name}: all missing")
        return
    print(
        f"    {name}: n={len(v)}, median={v.median():.2f}, IQR=[{v.quantile(.25):.2f}-{v.quantile(.75):.2f}]"
    )


def _compute_bmi_from_chartevents(ce_df, target_df, id_col="stay_id"):
    if len(ce_df) == 0:
        return target_df
    ce_df = ce_df.copy()
    ce_df["charttime"] = pd.to_datetime(ce_df.charttime)
    for item, col in _BMI_MAP:
        sub = (
            ce_df[ce_df.itemid == item]
            .sort_values("charttime")
            .groupby(id_col)
            .first()
            .reset_index()
        )
        target_df = target_df.merge(
            sub[[id_col, "valuenum"]].rename(columns={"valuenum": col}),
            on=id_col,
            how="left",
        )
    if "_ht" in target_df.columns and "_wt" in target_df.columns:
        target_df["bmi"] = target_df._wt / ((target_df._ht / 100) ** 2)
        target_df.loc[~target_df.bmi.between(10, 80), "bmi"] = np.nan
        target_df.drop(columns=["_ht", "_wt"], inplace=True, errors="ignore")
    return target_df


def save_all_patients(treated, control, db_tag):
    pid_col = (
        "patientunitstayid" if "patientunitstayid" in treated.columns else "stay_id"
    )
    for df in [treated, control]:
        df["surg_cabg"] = (df.surgery_type == "cabg").astype(int)
        df["surg_valve"] = (df.surgery_type == "valve").astype(int)
        df["surg_combined"] = (df.surgery_type == "combined").astype(int)
    treated["treated"] = 1
    control["treated"] = 0
    for c in ["alb_offset_h", "alb_offset_min", "alb_product", "alb_total_ml_24h"]:
        if c not in control.columns:
            control[c] = np.nan
    treated = treated.rename(columns={pid_col: "pid"})
    control = control.rename(columns={pid_col: "pid"})
    keep = [
        c for c in ALL_PATIENTS_COLS if c in treated.columns and c in control.columns
    ]
    all_pts = pd.concat([treated[keep], control[keep]], ignore_index=True)
    path = os.path.join(RESULTS, f"did_all_{db_tag.lower()}.csv")
    all_pts.to_csv(path, index=False)
    n_trt = int(all_pts.treated.sum())
    print(
        f"\n  \u2713 did_all_{db_tag.lower()}.csv: {len(all_pts):,} pts ({n_trt} treated + {len(all_pts)-n_trt} control)"
    )
    return all_pts


def save_consort(consort, db_tag):
    """Write one long-form, aggregate-only flow per database."""
    specs = [
        ("overall", "all_icu_stays", "total_icu", None),
        (
            "overall",
            "adult_first_cardiac_surgery_stay",
            "cardiac_adult_first",
            "total_icu",
        ),
        ("overall", "after_eskd_exclusion", "post_eskd", "cardiac_adult_first"),
        ("treated", "any_accepted_iv_albumin", "treated_any_iv_alb", None),
        (
            "treated",
            "icu_cr_strictly_before_own_t0",
            "treated_has_cr_pre",
            "treated_any_iv_alb",
        ),
        (
            "treated",
            "baseline_after_admit_window_fallback",
            "treated_has_cr_pre_with_fallback",
            "treated_has_cr_pre",
        ),
        (
            "treated",
            "final_after_baseline_cr_lt_4",
            "treated_final",
            "treated_has_cr_pre_with_fallback",
        ),
        ("control", "never_accepted_iv_albumin", "control_no_iv_alb", None),
        ("control", "at_least_two_post_icu_cr", "control_has_2cr", "control_no_iv_alb"),
        (
            "control",
            "final_after_reference_cr_lt_4",
            "control_final",
            "control_has_2cr",
        ),
    ]
    rows = []
    for order, (branch, step, key, previous_key) in enumerate(specs, start=1):
        n = int(consort[key])
        previous_n = int(consort[previous_key]) if previous_key else None
        rows.append(
            {
                "db": db_tag,
                "step_order": order,
                "branch": branch,
                "step": step,
                "n": n,
                "change_from_previous": (
                    n - previous_n if previous_n is not None else np.nan
                ),
                "excluded_from_previous": (
                    max(previous_n - n, 0) if previous_n is not None else np.nan
                ),
            }
        )
    path = os.path.join(RESULTS, f"did_consort_{db_tag.lower()}.csv")
    pd.DataFrame(rows).to_csv(path, index=False)
    print(f"  ✓ did_consort_{db_tag.lower()}.csv: {len(rows)} aggregate rows")


# ═══════════════════════════════════════════════════════════════════
# RRT HELPERS (identical to mg_aki)
# ═══════════════════════════════════════════════════════════════════
def get_rrt_mimic(stay_ids, icu_root, cardiac_df):
    frames = []
    for src, items, time_col in [
        ("procedureevents", RRT_PROCEDURE_ITEMS_MIMIC, "starttime"),
        ("inputevents", RRT_INPUT_ITEMS_MIMIC, "starttime"),
    ]:
        p = _resolve(icu_root, src)
        if not p:
            continue
        con = duckdb.connect()
        try:
            pid_df = pd.DataFrame({"_pid": pd.array(list(stay_ids), dtype="int64")})
            con.register("_pf", pid_df)
            istr = ",".join(str(i) for i in items)
            df = con.execute(
                f"SELECT stay_id, {time_col} AS starttime FROM read_csv_auto('{p}', header=true, ignore_errors=true) WHERE stay_id IN (SELECT _pid FROM _pf) AND itemid IN ({istr})"
            ).df()
            df.columns = df.columns.str.lower()
            if len(df) > 0:
                frames.append(df[["stay_id", "starttime"]])
            print(f"    RRT {src}: {len(df):,} rows")
        finally:
            con.close()
    # chartevents HD Output
    ce_path = _resolve(icu_root, "chartevents")
    if ce_path and RRT_CHART_ITEMS_MIMIC:
        con = duckdb.connect()
        try:
            pid_df = pd.DataFrame({"_pid": pd.array(list(stay_ids), dtype="int64")})
            con.register("_pf", pid_df)
            istr = ",".join(str(i) for i in RRT_CHART_ITEMS_MIMIC)
            df = con.execute(
                f"SELECT stay_id, charttime AS starttime FROM read_csv_auto('{ce_path}', header=true, ignore_errors=true) WHERE stay_id IN (SELECT _pid FROM _pf) AND itemid IN ({istr})"
            ).df()
            df.columns = df.columns.str.lower()
            if len(df) > 0:
                frames.append(df[["stay_id", "starttime"]])
            print(f"    RRT chartevents: {len(df):,} rows")
        finally:
            con.close()
    if not frames:
        return pd.DataFrame(columns=["stay_id", "rrt_offset_h"])
    rrt = pd.concat(frames).drop_duplicates()
    rrt["starttime"] = pd.to_datetime(rrt["starttime"])
    rrt = rrt.merge(cardiac_df[["stay_id", "intime"]], on="stay_id")
    rrt["rrt_offset_h"] = (rrt.starttime - rrt.intime).dt.total_seconds() / 3600
    rrt_first = (
        rrt[rrt.rrt_offset_h >= 0]
        .sort_values("rrt_offset_h")
        .groupby("stay_id")
        .first()
        .reset_index()[["stay_id", "rrt_offset_h"]]
    )
    print(f"    RRT patients: {len(rrt_first):,}")
    return rrt_first


def get_rrt_eicu(stay_ids, eicu_root):
    frames = []
    tx = load_filtered("treatment", eicu_root, stay_ids)
    if len(tx) > 0 and "treatmentstring" in tx.columns:
        rrt_mask = matches_any(tx.treatmentstring, EICU_RRT_TREATMENT_PATTERNS)
        tx_rrt = tx[rrt_mask][["patientunitstayid", "treatmentoffset"]].copy()
        tx_rrt["rrt_offset_h"] = tx_rrt.treatmentoffset / 60.0
        frames.append(tx_rrt[["patientunitstayid", "rrt_offset_h"]])
    io = load_filtered("intakeOutput", eicu_root, stay_ids)
    if len(io) > 0 and "dialysistotal" in io.columns:
        io_rrt = io[io.dialysistotal.fillna(0) != 0]
        if len(io_rrt) > 0:
            io_rrt = io_rrt[["patientunitstayid", "intakeoutputoffset"]].copy()
            io_rrt["rrt_offset_h"] = io_rrt.intakeoutputoffset / 60.0
            frames.append(io_rrt[["patientunitstayid", "rrt_offset_h"]])
    if not frames:
        return pd.DataFrame(columns=["patientunitstayid", "rrt_offset_h"])
    rrt = pd.concat(frames).drop_duplicates()
    rrt_first = (
        rrt[rrt.rrt_offset_h >= 0]
        .sort_values("rrt_offset_h")
        .groupby("patientunitstayid")
        .first()
        .reset_index()[["patientunitstayid", "rrt_offset_h"]]
    )
    print(f"    RRT patients: {len(rrt_first):,}")
    return rrt_first


# ═══════════════════════════════════════════════════════════════════
#  eICU-CRD
# ═══════════════════════════════════════════════════════════════════
def run_eicu():
    SEP = "=" * 70
    print(f"\n{SEP}\n01_etl.py - eICU-CRD (Albumin -> CSA-AKI)\n{SEP}")
    consort = {}

    patient = pd.read_csv(
        gz(os.path.join(EICU_ROOT, "patient.csv.gz")), low_memory=False
    )
    patient.columns = patient.columns.str.lower()
    consort["total_icu"] = len(patient)
    mask = matches_any(
        patient.apacheadmissiondx, CARDIAC_DX_PATTERNS
    ) | patient.unittype.isin(CARDIAC_UNIT_TYPES)
    cardiac = patient[mask].copy()
    cardiac["age"] = pd.to_numeric(
        cardiac["age"].astype(str).str.replace(">", ""), errors="coerce"
    ).fillna(90)
    cardiac = cardiac[cardiac.age >= MIN_AGE]
    cardiac = (
        cardiac.sort_values("hospitaladmitoffset")
        .groupby("uniquepid")
        .first()
        .reset_index()
    )
    cardiac["is_female"] = (cardiac.gender.str.lower() == "female").astype(int)
    cardiac["surgery_type"] = cardiac.apacheadmissiondx.apply(
        lambda s: (
            "combined"
            if any(p in str(s).lower() for p in ["cabg", "coronary artery bypass"])
            and "valve" in str(s).lower()
            else (
                "cabg"
                if any(p in str(s).lower() for p in ["cabg", "coronary artery bypass"])
                else "valve" if "valve" in str(s).lower() else "other_cardiac"
            )
        )
    )
    pids = set(cardiac.patientunitstayid)
    consort["cardiac_adult_first"] = len(cardiac)
    print(f"  Cardiac surgery, adult, 1st stay: {len(cardiac):,}")

    print(f"\n  Loading tables via DuckDB ({len(pids):,} pids)...")
    lab = load_filtered("lab", EICU_ROOT, pids)
    med = load_filtered("medication", EICU_ROOT, pids)
    diag = load_filtered("diagnosis", EICU_ROOT, pids)
    pasthx = load_filtered("pastHistory", EICU_ROOT, pids)
    vital = load_filtered("vitalPeriodic", EICU_ROOT, pids)
    admDrug = load_filtered("admissionDrug", EICU_ROOT, pids)

    # ESKD exclusion
    eskd = set()
    if len(pasthx) > 0 and "pasthistorypath" in pasthx.columns:
        eskd |= set(
            pasthx[
                pasthx.patientunitstayid.isin(pids)
                & matches_any(pasthx.pasthistorypath, ESKD_PATTERNS)
            ].patientunitstayid
        )
    if len(diag) > 0:
        eskd |= set(
            diag[
                diag.patientunitstayid.isin(pids)
                & matches_any(diag.diagnosisstring, ESKD_PATTERNS)
            ].patientunitstayid
        )
    cardiac = cardiac[~cardiac.patientunitstayid.isin(eskd)]
    pids = set(cardiac.patientunitstayid)
    consort["post_eskd"] = len(cardiac)
    print(f"  ESKD excluded: {len(eskd):,} -> {len(cardiac):,}")

    # ── IV Albumin identification ─────────────────────────────────
    print("\n  IV Albumin identification...")
    med_ok = (
        med[
            ~med.get("drugordercancelled", "").astype(str).str.contains("Yes", na=False)
        ]
        if len(med) > 0
        else pd.DataFrame()
    )
    frames = []
    if len(med_ok) > 0:
        alb_m = med_ok[
            matches_any(med_ok.drugname, ALB_INFUSION_PATTERNS)
            & (med_ok.drugstartoffset >= 0)
        ]
        if "routeadmin" in alb_m.columns:
            alb_m = alb_m[
                alb_m.routeadmin.str.lower().str.contains(
                    ALB_IV_ROUTE_PATTERNS, na=False
                )
                | alb_m.routeadmin.isna()
            ]
        if len(alb_m) > 0:
            frames.append(
                alb_m[["patientunitstayid", "drugstartoffset"]].rename(
                    columns={"drugstartoffset": "alb_offset_min"}
                )
            )
            print(f"    medication: {alb_m.patientunitstayid.nunique():,} patients")
    # intakeOutput (confirmed administration)
    io_tab = load_filtered("intakeOutput", EICU_ROOT, pids)
    if len(io_tab) > 0:
        for col in ["celllabel", "cellpath"]:
            if col in io_tab.columns:
                io_alb = io_tab[
                    io_tab.patientunitstayid.isin(pids)
                    & matches_any(io_tab[col], ALB_IO_PATTERNS)
                    & (io_tab.intakeoutputoffset >= 0)
                ]
                if len(io_alb) > 0:
                    frames.append(
                        io_alb[["patientunitstayid", "intakeoutputoffset"]].rename(
                            columns={"intakeoutputoffset": "alb_offset_min"}
                        )
                    )
                    print(
                        f"    intakeOutput: {io_alb.patientunitstayid.nunique():,} patients"
                    )
                break
    if not frames:
        print("  ERROR: no IV albumin found")
        return None
    alb_all = pd.concat(frames, ignore_index=True)
    first_alb = (
        alb_all.sort_values("alb_offset_min")
        .groupby("patientunitstayid")
        .first()
        .reset_index()
    )
    first_alb["alb_offset_h"] = first_alb.alb_offset_min / 60.0
    first_alb["alb_product"] = "unknown"
    first_alb["alb_total_ml_24h"] = np.nan

    treated_pids = set(first_alb.patientunitstayid)
    control_pids = pids - treated_pids
    consort["treated_any_iv_alb"] = len(treated_pids)
    consort["control_no_iv_alb"] = len(control_pids)
    print(f"  Treated (any IV Albumin): {pct(len(treated_pids), len(pids))}")
    desc(first_alb.alb_offset_h, "Onset (h)")

    # ── Peri-admission serum albumin ──────────────────────────────
    print("\n  Peri-admission serum albumin...")
    alb_lab = lab[
        lab.patientunitstayid.isin(pids)
        & lab.labname.str.lower().str.contains("albumin", na=False)
        & ~lab.labname.str.lower().str.contains(
            "urine|micro|ratio|creatinine", na=False
        )
        & lab.labresult.between(0.5, 8.0)
    ].copy()
    alb_lab["offset_h"] = alb_lab.labresultoffset / 60.0
    peri_alb = alb_lab[(alb_lab.offset_h >= -48) & (alb_lab.offset_h <= 6)]
    first_peri_alb = (
        peri_alb.sort_values("labresultoffset")
        .groupby("patientunitstayid")
        .first()
        .reset_index()[["patientunitstayid", "labresult"]]
        .rename(columns={"labresult": "peri_admission_alb"})
    )
    print(
        f"    Peri-admission albumin: {pct(first_peri_alb.patientunitstayid.nunique(), len(pids))}"
    )

    # ── Creatinine ────────────────────────────────────────────────
    cr = lab[
        lab.patientunitstayid.isin(pids)
        & lab.labname.str.lower().str.contains("creatinine", na=False)
        & lab.labresult.between(CR_MIN, CR_MAX)
    ].copy()
    cr_first = (
        cr[cr.labresultoffset >= 0]
        .sort_values("labresultoffset")
        .groupby("patientunitstayid")
        .first()
        .reset_index()
    )

    # Cr baseline: primary = last before T0; fallback = hospital admission
    cr_t = cr[cr.patientunitstayid.isin(treated_pids)].merge(
        first_alb[["patientunitstayid", "alb_offset_min"]], on="patientunitstayid"
    )
    cr_pre_t = cr_t[
        (cr_t.labresultoffset >= 0) & (cr_t.labresultoffset < cr_t.alb_offset_min)
    ]
    cr_pre_last = (
        cr_pre_t.sort_values("labresultoffset")
        .groupby("patientunitstayid")
        .last()
        .reset_index()
    )
    has_cr_pre = set(cr_pre_last.patientunitstayid)
    consort["treated_has_cr_pre"] = len(has_cr_pre)

    # Hospital admission fallback
    hosp_off = cardiac.set_index("patientunitstayid")["hospitaladmitoffset"].to_dict()
    cr_t["hosp_off"] = cr_t.patientunitstayid.map(hosp_off)
    cr_h = cr_t[
        (cr_t.labresultoffset >= cr_t.hosp_off - 360)
        & (cr_t.labresultoffset <= cr_t.hosp_off + 360)
        & (cr_t.labresultoffset < 0)
    ].copy()
    cr_h["_dist"] = (cr_h.labresultoffset - cr_h.hosp_off).abs()
    cr_hosp = (
        cr_h.sort_values(["patientunitstayid", "_dist"])
        .groupby("patientunitstayid")
        .first()
        .reset_index()
    )
    rescue_pids = set(cr_hosp.patientunitstayid) - has_cr_pre
    n_rescue = len(rescue_pids & treated_pids)
    consort["treated_hosp_fallback"] = n_rescue
    has_cr_pre |= rescue_pids
    consort["treated_has_cr_pre_with_fallback"] = len(has_cr_pre & treated_pids)
    print(f"  Cr_pre: ICU={consort['treated_has_cr_pre']}, +fallback={n_rescue}")

    treated_baseline = pd.concat(
        [
            cr_pre_last[["patientunitstayid", "labresult", "labresultoffset"]].assign(
                baseline_cr_source="icu_last_pre_albumin"
            ),
            cr_hosp[cr_hosp.patientunitstayid.isin(rescue_pids)][
                ["patientunitstayid", "labresult", "labresultoffset"]
            ].assign(baseline_cr_source="admit_window_fallback"),
        ],
        ignore_index=True,
    ).rename(
        columns={
            "labresult": "baseline_cr",
            "labresultoffset": "baseline_cr_offset_min",
        }
    )
    treated_baseline["baseline_cr_offset_h"] = (
        treated_baseline.baseline_cr_offset_min / 60.0
    )
    high_cr = set(
        treated_baseline[
            treated_baseline.baseline_cr >= BASELINE_CR_MAX
        ].patientunitstayid
    )
    keep_treated = (has_cr_pre & treated_pids) - high_cr
    consort["treated_final"] = len(keep_treated)

    cr_ctrl = cr[(cr.patientunitstayid.isin(control_pids)) & (cr.labresultoffset >= 0)]
    c2 = set(
        cr_ctrl.groupby("patientunitstayid").size().pipe(lambda s: s[s >= 2]).index
    )
    consort["control_has_2cr"] = len(c2)
    control_baseline = cr_first[cr_first.patientunitstayid.isin(c2)][
        ["patientunitstayid", "labresult", "labresultoffset"]
    ].rename(
        columns={
            "labresult": "baseline_cr",
            "labresultoffset": "baseline_cr_offset_min",
        }
    )
    control_baseline["baseline_cr_offset_h"] = (
        control_baseline.baseline_cr_offset_min / 60.0
    )
    control_baseline["baseline_cr_source"] = "icu_first_reference"
    c_excl = set(
        control_baseline[
            control_baseline.baseline_cr >= BASELINE_CR_MAX
        ].patientunitstayid
    )
    keep_control = c2 - c_excl
    consort["control_final"] = len(keep_control)

    # ── Build treated ─────────────────────────────────────────────
    print(f"\n  Building treated: {len(keep_treated):,}")
    treated = cardiac[cardiac.patientunitstayid.isin(keep_treated)].copy()
    treated = treated.merge(
        first_alb[
            [
                "patientunitstayid",
                "alb_offset_min",
                "alb_offset_h",
                "alb_product",
                "alb_total_ml_24h",
            ]
        ],
        on="patientunitstayid",
    )
    treated = treated.merge(first_peri_alb, on="patientunitstayid", how="left")
    treated = treated.merge(
        treated_baseline[
            [
                "patientunitstayid",
                "baseline_cr",
                "baseline_cr_offset_h",
                "baseline_cr_source",
            ]
        ],
        on="patientunitstayid",
        how="left",
    )
    treated["first_cr"] = treated.baseline_cr
    treated["egfr"] = compute_egfr(treated.baseline_cr, treated.age, treated.is_female)

    if "admissionweight" in cardiac.columns and "admissionheight" in cardiac.columns:
        wt = cardiac.set_index("patientunitstayid")["admissionweight"].to_dict()
        ht = cardiac.set_index("patientunitstayid")["admissionheight"].to_dict()
        for df_name, df in [("treated", treated)]:
            df["bmi"] = df.patientunitstayid.apply(
                lambda x: (
                    wt.get(x, np.nan) / ((ht.get(x, np.nan) / 100) ** 2)
                    if pd.notna(wt.get(x)) and pd.notna(ht.get(x)) and ht.get(x, 0) > 0
                    else np.nan
                )
            )
            df.loc[~df.bmi.between(10, 80), "bmi"] = np.nan

    for como, pats in EICU_COMORB.items():
        cp = set()
        if len(pasthx) > 0 and "pasthistorypath" in pasthx.columns:
            cp = set(
                pasthx[
                    pasthx.patientunitstayid.isin(keep_treated)
                    & matches_any(pasthx.pasthistorypath, pats)
                ].patientunitstayid
            )
        treated[como] = treated.patientunitstayid.isin(cp).astype(int)

    if len(admDrug) > 0 and "drugname" in admDrug.columns:
        ad = admDrug[admDrug.patientunitstayid.isin(keep_treated)]
        for col, pats in CHRONIC_DRUG_CLASSES.items():
            hits = (
                set(ad[matches_any(ad.drugname, pats)].patientunitstayid)
                if len(ad) > 0
                else set()
            )
            treated[col] = treated.patientunitstayid.isin(hits).astype(int)
    else:
        for col in CHRONIC_DRUG_CLASSES:
            treated[col] = 0

    treated["icu_discharge_h"] = treated.patientunitstayid.map(
        (cardiac.set_index("patientunitstayid")["unitdischargeoffset"] / 60).to_dict()
    )
    treated["icu_outcome"] = treated.patientunitstayid.map(
        cardiac.set_index("patientunitstayid")["unitdischargestatus"]
        .str.lower()
        .to_dict()
    )
    hosp_status_col = (
        "hospitaldischargestatus"
        if "hospitaldischargestatus" in cardiac.columns
        else "unitdischargestatus"
    )
    treated["hosp_mortality"] = (
        treated.patientunitstayid.map(
            cardiac.set_index("patientunitstayid")[hosp_status_col]
            .str.lower()
            .eq("expired")
            .to_dict()
        )
        .fillna(0)
        .astype(int)
    )

    # ── Build control ─────────────────────────────────────────────
    print(f"  Building control: {len(keep_control):,}")
    control = cardiac[cardiac.patientunitstayid.isin(keep_control)].copy()
    control = control.merge(first_peri_alb, on="patientunitstayid", how="left")
    control = control.merge(
        control_baseline[
            [
                "patientunitstayid",
                "baseline_cr",
                "baseline_cr_offset_h",
                "baseline_cr_source",
            ]
        ],
        on="patientunitstayid",
        how="left",
    )
    control["first_cr"] = control.baseline_cr
    control["egfr"] = compute_egfr(control.baseline_cr, control.age, control.is_female)

    if "admissionweight" in cardiac.columns:
        control["bmi"] = control.patientunitstayid.apply(
            lambda x: (
                wt.get(x, np.nan) / ((ht.get(x, np.nan) / 100) ** 2)
                if pd.notna(wt.get(x)) and pd.notna(ht.get(x)) and ht.get(x, 0) > 0
                else np.nan
            )
        )
        control.loc[~control.bmi.between(10, 80), "bmi"] = np.nan

    for como, pats in EICU_COMORB.items():
        cp = set()
        if len(pasthx) > 0 and "pasthistorypath" in pasthx.columns:
            cp = set(
                pasthx[
                    pasthx.patientunitstayid.isin(keep_control)
                    & matches_any(pasthx.pasthistorypath, pats)
                ].patientunitstayid
            )
        control[como] = control.patientunitstayid.isin(cp).astype(int)

    if len(admDrug) > 0 and "drugname" in admDrug.columns:
        ad_c = admDrug[admDrug.patientunitstayid.isin(keep_control)]
        for col, pats in CHRONIC_DRUG_CLASSES.items():
            hits = (
                set(ad_c[matches_any(ad_c.drugname, pats)].patientunitstayid)
                if len(ad_c) > 0
                else set()
            )
            control[col] = control.patientunitstayid.isin(hits).astype(int)
    else:
        for col in CHRONIC_DRUG_CLASSES:
            control[col] = 0

    control["icu_discharge_h"] = control.patientunitstayid.map(
        (cardiac.set_index("patientunitstayid")["unitdischargeoffset"] / 60).to_dict()
    )
    control["icu_outcome"] = control.patientunitstayid.map(
        cardiac.set_index("patientunitstayid")["unitdischargestatus"]
        .str.lower()
        .to_dict()
    )
    control["hosp_mortality"] = (
        control.patientunitstayid.map(
            cardiac.set_index("patientunitstayid")[hosp_status_col]
            .str.lower()
            .eq("expired")
            .to_dict()
        )
        .fillna(0)
        .astype(int)
    )

    # ── Secondary outcomes + RRT + death offset ───────────────────
    all_p = keep_treated | keep_control
    # Ventricular arrhythmia
    varr_pats = [
        "ventricular tachycardia",
        "ventricular fibrillation",
        "v-tach",
        "v-fib",
        "cardiac arrest",
    ]
    varr = (
        set(
            diag[
                diag.patientunitstayid.isin(all_p)
                & matches_any(diag.diagnosisstring, varr_pats)
                & (diag.diagnosisoffset > 0)
            ].patientunitstayid
        )
        if len(diag) > 0
        else set()
    )
    for df in [treated, control]:
        df["vent_arrhythmia"] = df.patientunitstayid.isin(varr).astype(int)

    # RRT
    print("\n  RRT detection...")
    rrt_eicu = get_rrt_eicu(all_p, EICU_ROOT)
    for df in [treated, control]:
        df_m = df.merge(rrt_eicu, on="patientunitstayid", how="left")
        df["rrt_offset_h"] = df_m["rrt_offset_h"].values
        df["has_rrt"] = df_m["rrt_offset_h"].notna().astype(int).values

    # Death offset
    hosp_dis_off = (
        cardiac.set_index("patientunitstayid")
        .get(
            "hospitaldischargeoffset",
            cardiac.set_index("patientunitstayid")["unitdischargeoffset"],
        )
        .to_dict()
    )
    hosp_dis_status = (
        cardiac.set_index("patientunitstayid")
        .get(
            "hospitaldischargestatus",
            cardiac.set_index("patientunitstayid")["unitdischargestatus"],
        )
        .str.lower()
        .to_dict()
    )
    for df in [treated, control]:
        df["death_offset_h"] = df.patientunitstayid.apply(
            lambda x: (
                hosp_dis_off.get(x, np.nan) / 60.0
                if hosp_dis_status.get(x) == "expired"
                else np.nan
            )
        )

    # ── Export ────────────────────────────────────────────────────
    save_all_patients(treated, control, "eicu")

    all_ids = keep_treated | keep_control
    cr_exp = cr[
        cr.patientunitstayid.isin(all_ids) & (cr.labresult <= CR_POST_PLAUSIBLE_MAX)
    ][["patientunitstayid", "labresult", "labresultoffset"]].copy()
    cr_exp["offset_h"] = cr_exp.labresultoffset / 60.0
    cr_exp.to_csv(os.path.join(RESULTS, "did_cr_all_eicu.csv"), index=False)
    print(f"  \u2713 did_cr_all_eicu.csv: {len(cr_exp):,} Cr")

    lab_rows = []
    for lab_name, patterns in {**EICU_LAB_PATTERNS, **EICU_TABLE1_LAB_PATTERNS}.items():
        sub = lab[
            lab.patientunitstayid.isin(all_ids) & matches_any(lab.labname, patterns)
        ]
        if lab_name != "albumin":
            sub = sub[sub.labresultoffset >= 0]
        if len(sub) > 0:
            lab_rows.append(
                pd.DataFrame(
                    {
                        "patientunitstayid": sub.patientunitstayid,
                        "lab_name": lab_name,
                        "value": sub.labresult,
                        "offset_h": sub.labresultoffset / 60.0,
                    }
                )
            )
    if len(vital) > 0 and "heartrate" in vital.columns:
        hr = vital[
            vital.patientunitstayid.isin(all_ids)
            & vital.heartrate.notna()
            & vital.heartrate.between(20, 250)
            & (vital.observationoffset >= 0)
        ]
        if len(hr) > 0:
            lab_rows.append(
                pd.DataFrame(
                    {
                        "patientunitstayid": hr.patientunitstayid,
                        "lab_name": "heartrate",
                        "value": hr.heartrate,
                        "offset_h": hr.observationoffset / 60.0,
                    }
                )
            )
    labs_all = pd.concat(lab_rows, ignore_index=True) if lab_rows else pd.DataFrame()
    labs_all.to_csv(os.path.join(RESULTS, "did_labs_all_eicu.csv"), index=False)
    print(f"  \u2713 did_labs_all_eicu.csv: {len(labs_all):,} measurements")
    for ln in labs_all.lab_name.unique():
        print(
            f"    {ln}: {(labs_all.lab_name==ln).sum():,} values across {labs_all[labs_all.lab_name==ln].patientunitstayid.nunique():,} pts"
        )

    consort["db"] = "eICU"
    print(f"\n  CONSORT: {consort}")
    save_consort(consort, "eICU")
    return consort


# ═══════════════════════════════════════════════════════════════════
#  MIMIC-IV
# ═══════════════════════════════════════════════════════════════════
def run_mimic():
    SEP = "=" * 70
    print(f"\n{SEP}\n01_etl.py - MIMIC-IV (Albumin -> CSA-AKI)\n{SEP}")
    consort = {}

    patients = pd.read_csv(gz(f"{MIMIC_HOSP}/patients.csv.gz"))
    admissions = pd.read_csv(gz(f"{MIMIC_HOSP}/admissions.csv.gz"))
    icustays = pd.read_csv(gz(f"{MIMIC_ICU}/icustays.csv.gz"))
    dx = pd.read_csv(gz(f"{MIMIC_HOSP}/diagnoses_icd.csv.gz"))
    px = pd.read_csv(gz(f"{MIMIC_HOSP}/procedures_icd.csv.gz"))
    presc = pd.read_csv(
        gz(f"{MIMIC_HOSP}/prescriptions.csv.gz"),
        usecols=["subject_id", "hadm_id", "drug", "starttime", "stoptime", "route"],
    )
    consort["total_icu"] = len(icustays)

    px["icd_code"] = px.icd_code.astype(str).str.strip()
    dx["icd_code"] = dx.icd_code.astype(str).str.strip()
    icu = icustays.merge(
        patients[["subject_id", "gender", "anchor_age"]], on="subject_id"
    )
    icu = icu.merge(
        admissions[["hadm_id", "admittime", "dischtime", "hospital_expire_flag"]],
        on="hadm_id",
    )
    icu["intime"] = pd.to_datetime(icu.intime)
    icu["outtime"] = pd.to_datetime(icu.outtime)

    cardiac_hadms = set()
    for ver, codes in [(9, CABG_ICD9 + VALVE_ICD9), (10, CABG_ICD10 + VALVE_ICD10)]:
        v = px[px.icd_version == ver]
        for c in codes:
            cardiac_hadms |= set(v[v.icd_code.str.startswith(c)].hadm_id)
    cvicu_stays = set(icu[icu.first_careunit == CVICU].stay_id)
    cardiac = icu[
        icu.stay_id.isin(
            set(icu[icu.hadm_id.isin(cardiac_hadms)].stay_id) | cvicu_stays
        )
    ].copy()
    cardiac = cardiac[cardiac.anchor_age >= MIN_AGE]
    cardiac = cardiac.sort_values("intime").groupby("subject_id").first().reset_index()
    cardiac["age"] = cardiac.anchor_age
    cardiac["is_female"] = (cardiac.gender == "F").astype(int)

    def classify_mimic(hadm_id):
        codes = set(px[px.hadm_id == hadm_id].icd_code)
        has_cabg = any(codes & set(c) for c in [CABG_ICD9, CABG_ICD10])
        has_valve = any(codes & set(c) for c in [VALVE_ICD9, VALVE_ICD10])
        if has_cabg and has_valve:
            return "combined"
        if has_cabg:
            return "cabg"
        if has_valve:
            return "valve"
        return "other_cardiac"

    cardiac["surgery_type"] = cardiac.hadm_id.apply(classify_mimic)
    stays = set(cardiac.stay_id)
    hadms = set(cardiac.hadm_id.dropna().astype(int))
    consort["cardiac_adult_first"] = len(cardiac)
    print(f"  Cardiac surgery, adult, 1st stay: {len(cardiac):,}")

    # ESKD
    eskd_hadms = set()
    for pat in ESKD_PATTERNS:
        eskd_hadms |= set(
            dx[
                dx.hadm_id.isin(hadms)
                & dx.icd_code.str.lower().str.contains(pat.replace(" ", ""), na=False)
            ].hadm_id
        )
    for ver, codes in ESKD_ICD.items():
        v = dx[(dx.hadm_id.isin(hadms)) & (dx.icd_version == ver)]
        for c in codes:
            eskd_hadms |= set(v[v.icd_code.str.startswith(c)].hadm_id)
    eskd_stays = set(cardiac[cardiac.hadm_id.isin(eskd_hadms)].stay_id)
    cardiac = cardiac[~cardiac.stay_id.isin(eskd_stays)]
    stays = set(cardiac.stay_id)
    hadms = set(cardiac.hadm_id.dropna().astype(int))
    consort["post_eskd"] = len(cardiac)
    print(f"  ESKD excluded: {len(eskd_stays):,} -> {len(cardiac):,}")

    # DuckDB big tables
    item_list = ",".join(str(i) for i in ALL_LAB_ITEMS_MIMIC | TABLE1_LAB_ITEMS_MIMIC)
    print(f"\n  Loading big tables via DuckDB ({len(hadms):,} hadm_ids)...")
    labs = load_filtered(
        "labevents",
        MIMIC_HOSP,
        hadms,
        pid_col="hadm_id",
        extra_where=f"itemid IN ({item_list})",
    )
    ie = load_filtered("inputevents", MIMIC_ICU, stays, pid_col="stay_id")
    hr_items = ",".join(str(i) for i in VITAL_HR_MIMIC)
    ce_hr = load_filtered(
        "chartevents",
        MIMIC_ICU,
        stays,
        pid_col="stay_id",
        extra_where=f"itemid IN ({hr_items})",
    )

    # ── IV Albumin identification ─────────────────────────────────
    print("\n  IV Albumin identification...")
    ie_alb = ie[
        (ie.stay_id.isin(stays)) & (ie.itemid.isin(ALB_INFUSION_ITEMS_MIMIC))
    ].copy()
    if "statusdescription" in ie_alb.columns:
        ie_alb = ie_alb[~ie_alb.statusdescription.str.contains("Rewritten", na=False)]
    ie_alb = ie_alb[ie_alb.amount.notna() & (ie_alb.amount > 0)]
    ie_alb["starttime"] = pd.to_datetime(ie_alb.starttime)
    ie_alb = ie_alb.merge(cardiac[["stay_id", "intime"]], on="stay_id")
    ie_alb["alb_offset_h"] = (
        ie_alb.starttime - ie_alb.intime
    ).dt.total_seconds() / 3600
    ie_alb = ie_alb[ie_alb.alb_offset_h >= 0]

    first_alb = (
        ie_alb.sort_values("alb_offset_h").groupby("stay_id").first().reset_index()
    )
    first_alb["alb_offset_min"] = first_alb.alb_offset_h * 60
    first_alb["alb_product"] = first_alb.itemid.map(ALB_PRODUCT_MAP).fillna("unknown")
    alb_24h = (
        ie_alb[ie_alb.alb_offset_h <= 24]
        .groupby("stay_id")
        .amount.sum()
        .rename("alb_total_ml_24h")
    )
    first_alb = first_alb.merge(alb_24h, on="stay_id", how="left")

    treated_stays = set(first_alb.stay_id)
    control_stays = stays - treated_stays
    consort["treated_any_iv_alb"] = len(treated_stays)
    consort["control_no_iv_alb"] = len(control_stays)
    print(f"  Treated: {pct(len(treated_stays), len(stays))}")
    desc(first_alb.alb_offset_h, "Onset (h)")
    print(f"  Product: {first_alb.alb_product.value_counts().to_dict()}")

    # ── Peri-admission serum albumin ──────────────────────────────
    print("\n  Peri-admission serum albumin...")
    alb_labs = labs[
        labs.itemid.isin(LAB_ALB_MIMIC) & labs.valuenum.between(0.5, 8.0)
    ].copy()
    alb_labs["charttime"] = pd.to_datetime(alb_labs.charttime)
    alb_labs = alb_labs.merge(cardiac[["stay_id", "hadm_id", "intime"]], on="hadm_id")
    alb_labs["offset_h"] = (
        alb_labs.charttime - alb_labs.intime
    ).dt.total_seconds() / 3600
    peri_alb = alb_labs[(alb_labs.offset_h >= -48) & (alb_labs.offset_h <= 6)]
    first_peri_alb = (
        peri_alb.sort_values("offset_h")
        .groupby("stay_id")
        .first()
        .reset_index()[["stay_id", "valuenum"]]
        .rename(columns={"valuenum": "peri_admission_alb"})
    )
    print(
        f"    Peri-admission albumin: {pct(first_peri_alb.stay_id.nunique(), len(stays))}"
    )

    # ── Creatinine ────────────────────────────────────────────────
    cr = labs[
        labs.itemid.isin(LAB_CR_MIMIC) & labs.valuenum.between(CR_MIN, CR_MAX)
    ].copy()
    cr["charttime"] = pd.to_datetime(cr.charttime)
    cr = cr.merge(cardiac[["stay_id", "hadm_id", "intime"]], on="hadm_id")
    cr["offset_h"] = (cr.charttime - cr.intime).dt.total_seconds() / 3600
    cr["offset_min"] = cr.offset_h * 60
    cr_first = (
        cr[cr.offset_h >= 0]
        .sort_values("offset_h")
        .groupby("stay_id")
        .first()
        .reset_index()
    )

    # Cr baseline: primary = last before T0; fallback = hospital admission
    cr_t = cr[cr.stay_id.isin(treated_stays)].merge(
        first_alb[["stay_id", "alb_offset_h", "alb_offset_min"]], on="stay_id"
    )
    cr_pre_t = cr_t[(cr_t.offset_h >= 0) & (cr_t.offset_min < cr_t.alb_offset_min)]
    cr_pre_last = (
        cr_pre_t.sort_values("offset_h").groupby("stay_id").last().reset_index()
    )
    has_cr = set(cr_pre_last.stay_id)
    consort["treated_has_cr_pre"] = len(has_cr)

    adm_times = admissions[["hadm_id", "admittime"]].copy()
    adm_times.admittime = pd.to_datetime(adm_times.admittime)
    cr_hadm = cr.merge(adm_times, on="hadm_id", how="left")
    cr_hadm["pre_adm"] = cr_hadm.charttime < cr_hadm.admittime
    hosp_cr = (
        cr_hadm[cr_hadm.pre_adm & cr_hadm.stay_id.isin(treated_stays - has_cr)]
        .sort_values("charttime", ascending=False)
        .groupby("stay_id")
        .first()
        .reset_index()
    )
    rescue = set(hosp_cr.stay_id)
    consort["treated_hosp_fallback"] = len(rescue)
    has_cr |= rescue
    consort["treated_has_cr_pre_with_fallback"] = len(has_cr)
    print(f"  Cr_pre: ICU={consort['treated_has_cr_pre']}, +fallback={len(rescue)}")

    treated_baseline = pd.concat(
        [
            cr_pre_last[["stay_id", "valuenum", "offset_h"]].assign(
                baseline_cr_source="icu_last_pre_albumin"
            ),
            hosp_cr[hosp_cr.stay_id.isin(rescue)][
                ["stay_id", "valuenum", "offset_h"]
            ].assign(baseline_cr_source="admit_window_fallback"),
        ],
        ignore_index=True,
    ).rename(columns={"valuenum": "baseline_cr", "offset_h": "baseline_cr_offset_h"})
    high_cr = set(
        treated_baseline[treated_baseline.baseline_cr >= BASELINE_CR_MAX].stay_id
    )
    keep_treated = (has_cr & treated_stays) - high_cr
    consort["treated_final"] = len(keep_treated)
    cr_ctrl = cr[(cr.stay_id.isin(control_stays)) & (cr.offset_h >= 0)]
    c2 = set(cr_ctrl.groupby("stay_id").size().pipe(lambda s: s[s >= 2]).index)
    consort["control_has_2cr"] = len(c2)
    control_baseline = cr_first[cr_first.stay_id.isin(c2)][
        ["stay_id", "valuenum", "offset_h"]
    ].rename(columns={"valuenum": "baseline_cr", "offset_h": "baseline_cr_offset_h"})
    control_baseline["baseline_cr_source"] = "icu_first_reference"
    c_excl = set(
        control_baseline[control_baseline.baseline_cr >= BASELINE_CR_MAX].stay_id
    )
    keep_control = c2 - c_excl
    consort["control_final"] = len(keep_control)

    # ── Build treated ─────────────────────────────────────────────
    print(f"\n  Building treated: {len(keep_treated):,}")
    treated = cardiac[cardiac.stay_id.isin(keep_treated)].copy()
    treated = treated.merge(
        first_alb[
            [
                "stay_id",
                "alb_offset_min",
                "alb_offset_h",
                "alb_product",
                "alb_total_ml_24h",
            ]
        ],
        on="stay_id",
    )
    treated = treated.merge(first_peri_alb, on="stay_id", how="left")
    treated = treated.merge(
        treated_baseline[
            ["stay_id", "baseline_cr", "baseline_cr_offset_h", "baseline_cr_source"]
        ],
        on="stay_id",
        how="left",
    )
    treated["first_cr"] = treated.baseline_cr
    treated["egfr"] = compute_egfr(treated.baseline_cr, treated.age, treated.is_female)

    for como, code_map in MIMIC_COMORB_ICD.items():
        treated[como] = treated.hadm_id.isin(
            matches_icd(dx, set(treated.hadm_id.dropna().astype(int)), code_map)
        ).astype(int)

    presc["starttime"] = pd.to_datetime(presc.starttime, errors="coerce")
    adm_t = admissions[["hadm_id", "admittime"]].copy()
    adm_t.admittime = pd.to_datetime(adm_t.admittime)
    p = presc[presc.hadm_id.isin(set(treated.hadm_id.dropna().astype(int)))].merge(
        adm_t, on="hadm_id"
    )
    p = p.merge(
        treated[["hadm_id", "stay_id", "intime"]].drop_duplicates("hadm_id"),
        on="hadm_id",
        how="left",
    )
    p_chronic = p[
        (p.starttime < p.admittime)
        | (
            (p.starttime < p.intime)
            & p.route.str.lower().str.contains(ORAL_ROUTE_RE, na=False)
        )
    ]
    for col, pats in CHRONIC_DRUG_CLASSES.items():
        hits = set(
            p_chronic[
                p_chronic.drug.str.lower().str.contains(
                    "|".join(x.lower() for x in pats), na=False
                )
            ].stay_id
        )
        treated[col] = treated.stay_id.isin(hits).astype(int)

    ce_bmi = load_filtered(
        "chartevents",
        MIMIC_ICU,
        keep_treated,
        pid_col="stay_id",
        extra_where=f"itemid IN ({','.join(str(i) for i in _BMI_ITEMS)})",
    )
    treated = _compute_bmi_from_chartevents(ce_bmi, treated)
    treated["icu_discharge_h"] = (
        treated.outtime - treated.intime
    ).dt.total_seconds() / 3600
    treated["icu_outcome"] = treated.hospital_expire_flag.map(
        {1: "expired", 0: "alive"}
    ).fillna("unknown")
    treated["hosp_mortality"] = treated.hospital_expire_flag.fillna(0).astype(int)

    # ── Build control ─────────────────────────────────────────────
    print(f"  Building control: {len(keep_control):,}")
    control = cardiac[cardiac.stay_id.isin(keep_control)].copy()
    control = control.merge(first_peri_alb, on="stay_id", how="left")
    control = control.merge(
        control_baseline[
            ["stay_id", "baseline_cr", "baseline_cr_offset_h", "baseline_cr_source"]
        ],
        on="stay_id",
        how="left",
    )
    control["first_cr"] = control.baseline_cr
    control["egfr"] = compute_egfr(control.baseline_cr, control.age, control.is_female)

    for como, code_map in MIMIC_COMORB_ICD.items():
        control[como] = control.hadm_id.isin(
            matches_icd(dx, set(control.hadm_id.dropna().astype(int)), code_map)
        ).astype(int)

    p_c = presc[presc.hadm_id.isin(set(control.hadm_id.dropna().astype(int)))].merge(
        adm_t, on="hadm_id"
    )
    p_c = p_c.merge(
        control[["hadm_id", "stay_id", "intime"]].drop_duplicates("hadm_id"),
        on="hadm_id",
        how="left",
    )
    pc_chr = p_c[
        (p_c.starttime < p_c.admittime)
        | (
            (p_c.starttime < p_c.intime)
            & p_c.route.str.lower().str.contains(ORAL_ROUTE_RE, na=False)
        )
    ]
    for col, pats in CHRONIC_DRUG_CLASSES.items():
        hits = set(
            pc_chr[
                pc_chr.drug.str.lower().str.contains(
                    "|".join(x.lower() for x in pats), na=False
                )
            ].stay_id
        )
        control[col] = control.stay_id.isin(hits).astype(int)

    ce_bmi_c = load_filtered(
        "chartevents",
        MIMIC_ICU,
        keep_control,
        pid_col="stay_id",
        extra_where=f"itemid IN ({','.join(str(i) for i in _BMI_ITEMS)})",
    )
    control = _compute_bmi_from_chartevents(ce_bmi_c, control)
    control["icu_discharge_h"] = (
        control.outtime - control.intime
    ).dt.total_seconds() / 3600
    control["icu_outcome"] = control.hospital_expire_flag.map(
        {1: "expired", 0: "alive"}
    ).fillna("unknown")
    control["hosp_mortality"] = control.hospital_expire_flag.fillna(0).astype(int)

    # ── Secondary outcomes + RRT + death offset ───────────────────
    all_hadms = set(treated.hadm_id.dropna().astype(int)) | set(
        control.hadm_id.dropna().astype(int)
    )
    varr_hadms = matches_icd(
        dx, all_hadms, {9: ["4271", "42741", "42742"], 10: ["I472", "I490"]}
    )
    for df in [treated, control]:
        df["vent_arrhythmia"] = df.hadm_id.isin(varr_hadms).astype(int)

    print("\n  RRT detection...")
    rrt_mimic = get_rrt_mimic(keep_treated | keep_control, MIMIC_ICU, cardiac)
    for df in [treated, control]:
        df_m = df.merge(rrt_mimic, on="stay_id", how="left")
        df["rrt_offset_h"] = df_m["rrt_offset_h"].values
        df["has_rrt"] = df_m["rrt_offset_h"].notna().astype(int).values

    adm_death = admissions[["hadm_id", "deathtime"]].copy()
    adm_death["deathtime"] = pd.to_datetime(adm_death["deathtime"])
    for df in [treated, control]:
        df_d = df.merge(adm_death, on="hadm_id", how="left")
        df["death_offset_h"] = (
            (df_d.deathtime - df_d.intime).dt.total_seconds() / 3600
        ).values

    # ── Export ────────────────────────────────────────────────────
    save_all_patients(treated, control, "mimic")

    all_s = keep_treated | keep_control
    cr_exp = cr[cr.stay_id.isin(all_s) & (cr.valuenum <= CR_POST_PLAUSIBLE_MAX)]
    cr_exp = cr_exp[["stay_id", "valuenum", "offset_min", "offset_h"]].copy()
    cr_exp = cr_exp.rename(
        columns={"valuenum": "labresult", "offset_min": "labresultoffset"}
    )
    cr_exp.to_csv(os.path.join(RESULTS, "did_cr_all_mimic.csv"), index=False)
    print(f"  \u2713 did_cr_all_mimic.csv: {len(cr_exp):,} Cr")

    lab_rows = []
    mimic_lab_map = {
        "hemoglobin": LAB_HGB_MIMIC,
        "calcium": LAB_CA_MIMIC,
        "lactate": LAB_LAC_MIMIC,
        "potassium": LAB_K_MIMIC,
        "magnesium": LAB_MG_MIMIC,
        "albumin": LAB_ALB_MIMIC,
        "wbc": LAB_WBC_MIMIC,
        "platelets": LAB_PLT_MIMIC,
    }
    for lab_name, items in mimic_lab_map.items():
        sub = labs[
            labs.itemid.isin(items)
            & labs.hadm_id.isin(
                set(cardiac[cardiac.stay_id.isin(all_s)].hadm_id.dropna().astype(int))
            )
        ]
        if len(sub) > 0:
            sub = sub.copy()
            sub["charttime"] = pd.to_datetime(sub.charttime)
            sub = sub.merge(cardiac[["stay_id", "hadm_id", "intime"]], on="hadm_id")
            sub["offset_h"] = (sub.charttime - sub.intime).dt.total_seconds() / 3600
            if lab_name != "albumin":
                sub = sub[sub.offset_h >= 0]
            lab_rows.append(
                pd.DataFrame(
                    {
                        "stay_id": sub.stay_id,
                        "lab_name": lab_name,
                        "value": sub.valuenum,
                        "offset_h": sub.offset_h,
                    }
                )
            )
    if len(ce_hr) > 0:
        hr = ce_hr[ce_hr.stay_id.isin(all_s)].copy()
        hr["charttime"] = pd.to_datetime(hr.charttime)
        hr = hr.merge(cardiac[["stay_id", "intime"]], on="stay_id")
        hr["offset_h"] = (hr.charttime - hr.intime).dt.total_seconds() / 3600
        hr = hr[(hr.offset_h >= 0) & hr.valuenum.between(20, 250)]
        if len(hr) > 0:
            lab_rows.append(
                pd.DataFrame(
                    {
                        "stay_id": hr.stay_id,
                        "lab_name": "heartrate",
                        "value": hr.valuenum,
                        "offset_h": hr.offset_h,
                    }
                )
            )
    labs_all = pd.concat(lab_rows, ignore_index=True) if lab_rows else pd.DataFrame()
    labs_all.to_csv(os.path.join(RESULTS, "did_labs_all_mimic.csv"), index=False)
    print(f"  \u2713 did_labs_all_mimic.csv: {len(labs_all):,} measurements")
    for ln in labs_all.lab_name.unique():
        print(
            f"    {ln}: {(labs_all.lab_name==ln).sum():,} values across {labs_all[labs_all.lab_name==ln].stay_id.nunique():,} pts"
        )

    consort["db"] = "MIMIC"
    print(f"\n  CONSORT: {consort}")
    save_consort(consort, "MIMIC")
    return consort


# ═══════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print("=" * 70)
    print("01_etl.py - Albumin -> CSA-AKI Cohort Construction")
    print("  Outputs: did_all, did_labs_all, did_cr_all per database")
    print("=" * 70)
    args = [a.lower() for a in sys.argv[1:]]
    if not args or "eicu" in args:
        run_eicu()
    if not args or "mimic" in args:
        run_mimic()
    print("\n" + "=" * 70)
    print("NEXT: Rscript 02_psm.R eicu / mimic")
    print("=" * 70)
