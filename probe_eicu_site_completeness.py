#!/usr/bin/env python3
"""Read-only, raw-table eICU site completeness probe.

This script does not fit a propensity score or outcome model and does not
alter the frozen v3.3 pairs.  The analysis cohort and each patient's frozen
index are read from did_all_eicu.csv; MAP, vasopressor, and ventilation
recoverability are derived afresh from raw eICU tables.

High-fidelity site (prespecified before the probe):
  * >=30 albumin-treated patients;
  * MAP available for >=80% of both arms;
  * best-effort vasopressor state recoverable for >=80% of both arms; and
  * clean time-resolved ventilation state recoverable for >=80% of both arms.

Absence of a raw record is never interpreted as an off state.  In particular,
infusionDrug has point observations but no stop time, so its contribution is
explicitly labelled best-effort rather than an exact continuous interval.
"""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

import numpy as np
import pandas as pd

MAP_MIN = 20.0
MAP_MAX = 200.0
MAP_THRESHOLD = 0.80
VASO_THRESHOLD = 0.80
VENT_THRESHOLD = 0.80
MIN_TREATED = 30
VASO_INTERFACE_LOOKBACK_MIN = 6 * 60
VENT_EXPLICIT_LOOKBACK_MIN = 24 * 60
VENT_SETTING_LOOKBACK_MIN = 6 * 60

PRESSOR_RX = re.compile(
    r"norepi|levophed|epinephrine|vasopressin|phenylephrine|neosynephrine|"
    r"dopamine|dobutamine|milrinone",
    re.I,
)
VENT_SETTING_RX = re.compile(
    r"ventilator mode|vent mode|peep|tidal volume|set tidal|resp.*rate.*set|"
    r"pressure control|pressure support|fio2|fraction.*inspired",
    re.I,
)
VENT_TREATMENT_RX = re.compile(
    r"mechanical ventilation|ventilator|intubat|endotracheal|airway",
    re.I,
)


def resolve(root: Path, stem: str) -> Path:
    for suffix in (".csv.gz", ".csv"):
        path = root / f"{stem}{suffix}"
        if path.exists():
            return path
    raise FileNotFoundError(f"Missing raw eICU table: {stem}")


def numeric(series: pd.Series) -> pd.Series:
    return pd.to_numeric(series, errors="coerce")


def pct(num: int, den: int) -> float:
    return float(num / den) if den else np.nan


def add_ids(target: set[int], values: pd.Series) -> None:
    target.update(numeric(values).dropna().astype("int64").tolist())


def cohort_chunk(path: Path, usecols: list[str], keep: set[int], chunksize=1_000_000):
    for chunk in pd.read_csv(
        path,
        usecols=usecols,
        chunksize=chunksize,
        low_memory=False,
        compression="infer",
    ):
        pid = numeric(chunk["patientunitstayid"])
        mask = pid.isin(keep)
        if mask.any():
            out = chunk.loc[mask].copy()
            out["patientunitstayid"] = pid.loc[mask].astype("int64")
            yield out


def scan_map(root: Path, keep: set[int], t0_min: pd.Series):
    periodic = set()
    aperiodic = set()

    path = resolve(root, "vitalPeriodic")
    cols = [
        "patientunitstayid",
        "observationoffset",
        "systemicmean",
        "noninvasivemean",
    ]
    for chunk in cohort_chunk(path, cols, keep, chunksize=2_000_000):
        pid = chunk.patientunitstayid
        off = numeric(chunk.observationoffset)
        sm = numeric(chunk.systemicmean)
        nm = numeric(chunk.noninvasivemean)
        value = sm.where(sm.notna(), nm)
        valid = (
            off.notna()
            & (off < pid.map(t0_min))
            & value.between(MAP_MIN, MAP_MAX, inclusive="both")
        )
        add_ids(periodic, pid[valid])

    path = resolve(root, "vitalAperiodic")
    cols = ["patientunitstayid", "observationoffset", "noninvasivemean"]
    for chunk in cohort_chunk(path, cols, keep, chunksize=1_000_000):
        pid = chunk.patientunitstayid
        off = numeric(chunk.observationoffset)
        value = numeric(chunk.noninvasivemean)
        valid = (
            off.notna()
            & (off < pid.map(t0_min))
            & value.between(MAP_MIN, MAP_MAX, inclusive="both")
        )
        add_ids(aperiodic, pid[valid])

    return periodic, aperiodic


def scan_vaso(root: Path, keep: set[int], t0_min: pd.Series):
    interface_near = set()
    pressor_rate_near = set()
    active_med_interval = set()

    path = resolve(root, "infusionDrug")
    cols = [
        "patientunitstayid",
        "infusionoffset",
        "drugname",
        "drugrate",
        "infusionrate",
    ]
    for chunk in cohort_chunk(path, cols, keep):
        pid = chunk.patientunitstayid
        off = numeric(chunk.infusionoffset)
        rate = numeric(chunk.drugrate).where(
            numeric(chunk.drugrate).notna(), numeric(chunk.infusionrate)
        )
        t0 = pid.map(t0_min)
        near = (
            off.notna()
            & rate.notna()
            & (off <= t0)
            & (off >= t0 - VASO_INTERFACE_LOOKBACK_MIN)
        )
        add_ids(interface_near, pid[near])
        pressor = chunk.drugname.fillna("").str.contains(PRESSOR_RX)
        add_ids(pressor_rate_near, pid[near & pressor])

    path = resolve(root, "medication")
    cols = [
        "patientunitstayid",
        "drugname",
        "routeadmin",
        "drugstartoffset",
        "drugstopoffset",
        "drugordercancelled",
    ]
    for chunk in cohort_chunk(path, cols, keep):
        pid = chunk.patientunitstayid
        start = numeric(chunk.drugstartoffset)
        stop = numeric(chunk.drugstopoffset)
        t0 = pid.map(t0_min)
        pressor = chunk.drugname.fillna("").str.contains(PRESSOR_RX)
        iv = chunk.routeadmin.fillna("").str.contains(
            r"IV|INFUS", case=False, regex=True
        )
        not_cancelled = ~chunk.drugordercancelled.fillna("").str.contains(
            "yes", case=False
        )
        active = (
            pressor
            & iv
            & not_cancelled
            & start.notna()
            & stop.notna()
            & (start <= t0)
            & (stop > t0)
        )
        add_ids(active_med_interval, pid[active])

    best_effort = interface_near | active_med_interval
    positive = pressor_rate_near | active_med_interval
    return interface_near, pressor_rate_near, active_med_interval, best_effort, positive


def scan_vent(root: Path, keep: set[int], t0_min: pd.Series):
    explicit_state = set()
    explicit_on = set()
    explicit_off = set()
    setting_on = set()
    care_interval_on = set()
    treatment_support = set()

    path = resolve(root, "respiratoryCharting")
    cols = [
        "patientunitstayid",
        "respchartoffset",
        "respcharttypecat",
        "respchartvaluelabel",
        "respchartvalue",
    ]
    for chunk in cohort_chunk(path, cols, keep):
        pid = chunk.patientunitstayid
        off = numeric(chunk.respchartoffset)
        t0 = pid.map(t0_min)
        label = chunk.respchartvaluelabel.fillna("").str.lower()
        value = chunk.respchartvalue.fillna("").str.strip().str.lower()
        prior24 = off.notna() & (off <= t0) & (off >= t0 - VENT_EXPLICIT_LOOKBACK_MIN)
        onoff = label.str.contains(r"vent.*on.?off|on.?off.*vent", regex=True)
        on = value.str.contains(
            r"^(on|yes|started|start|continued|continue|1)$", regex=True
        )
        off_state = value.str.contains(
            r"^(off|no|stopped|stop|discontinued|discontinue|0)$", regex=True
        )
        add_ids(explicit_on, pid[prior24 & onoff & on])
        add_ids(explicit_off, pid[prior24 & onoff & off_state])
        add_ids(explicit_state, pid[prior24 & onoff & (on | off_state)])

        prior6 = off.notna() & (off <= t0) & (off >= t0 - VENT_SETTING_LOOKBACK_MIN)
        setting = label.str.contains(VENT_SETTING_RX)
        has_value = value.ne("") & ~value.isin(["nan", "none", "unable"])
        add_ids(setting_on, pid[prior6 & setting & has_value])

    path = resolve(root, "respiratoryCare")
    cols = [
        "patientunitstayid",
        "respcarestatusoffset",
        "ventstartoffset",
        "ventendoffset",
        "priorventstartoffset",
        "priorventendoffset",
    ]
    for chunk in cohort_chunk(path, cols, keep):
        pid = chunk.patientunitstayid
        t0 = pid.map(t0_min)
        status = numeric(chunk.respcarestatusoffset)
        start = numeric(chunk.ventstartoffset)
        end = numeric(chunk.ventendoffset)
        pstart = numeric(chunk.priorventstartoffset)
        pend = numeric(chunk.priorventendoffset)
        current_on = (
            start.notna()
            & (start <= t0)
            & ((end > t0) | ((end == 0) & status.notna() & (status >= t0)))
        )
        prior_on = pstart.notna() & (pstart <= t0) & (pend > t0)
        add_ids(care_interval_on, pid[current_on | prior_on])

    path = resolve(root, "treatment")
    cols = ["patientunitstayid", "treatmentoffset", "treatmentstring"]
    for chunk in cohort_chunk(path, cols, keep):
        pid = chunk.patientunitstayid
        off = numeric(chunk.treatmentoffset)
        t0 = pid.map(t0_min)
        relevant = chunk.treatmentstring.fillna("").str.contains(VENT_TREATMENT_RX)
        near = off.notna() & (off <= t0) & (off >= t0 - VENT_EXPLICIT_LOOKBACK_MIN)
        add_ids(treatment_support, pid[near & relevant])

    clean = explicit_state | setting_on | care_interval_on
    positive = explicit_on | setting_on | care_interval_on
    return {
        "explicit_state": explicit_state,
        "explicit_on": explicit_on,
        "explicit_off": explicit_off,
        "setting_on": setting_on,
        "care_interval_on": care_interval_on,
        "treatment_support": treatment_support,
        "clean": clean,
        "positive": positive,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--results",
        type=Path,
        default=Path(os.path.expanduser("~/albumin_aki/results")),
    )
    parser.add_argument(
        "--eicu-root",
        type=Path,
        default=Path(os.path.expanduser("~/mg_aki/eicu-crd-2.0")),
    )
    args = parser.parse_args()

    cohort_path = args.results / "did_all_eicu.csv"
    pairs_path = args.results / "did_pairs_primary_yet_untreated_pooled_eicu.csv"
    cohort = pd.read_csv(cohort_path, low_memory=False)
    cohort["pid"] = numeric(cohort.pid).astype("int64")
    cohort["treated"] = numeric(cohort.treated).astype("int64")
    cohort["index_h"] = numeric(cohort.alb_offset_h).where(
        cohort.treated.eq(1), numeric(cohort.cr_ref_early_offset_h)
    )
    if cohort.index_h.isna().any():
        raise RuntimeError("Missing frozen index in eICU cohort")
    cohort["index_min"] = cohort.index_h * 60.0
    keep = set(cohort.pid)
    t0_min = cohort.set_index("pid").index_min

    patient = pd.read_csv(
        resolve(args.eicu_root, "patient"),
        usecols=["patientunitstayid", "hospitalid"],
        low_memory=False,
    )
    patient.patientunitstayid = numeric(patient.patientunitstayid).astype("int64")
    patient = patient[patient.patientunitstayid.isin(keep)].drop_duplicates(
        "patientunitstayid"
    )
    hospital_map = patient.set_index("patientunitstayid").hospitalid
    cohort["hospitalid"] = cohort.pid.map(hospital_map)
    if cohort.hospitalid.isna().any():
        raise RuntimeError("Unmapped hospital in frozen eICU source cohort")
    cohort.hospitalid = numeric(cohort.hospitalid).astype("int64")

    pairs = pd.read_csv(pairs_path, usecols=["trt_pid", "ctl_pid"], low_memory=False)
    pairs.trt_pid = numeric(pairs.trt_pid).astype("int64")
    pairs.ctl_pid = numeric(pairs.ctl_pid).astype("int64")
    pairs["trt_hospitalid"] = pairs.trt_pid.map(hospital_map)
    pairs["ctl_hospitalid"] = pairs.ctl_pid.map(hospital_map)
    if pairs[["trt_hospitalid", "ctl_hospitalid"]].isna().any().any():
        raise RuntimeError("Unmapped hospital in frozen pairs")

    map_periodic, map_aperiodic = scan_map(args.eicu_root, keep, t0_min)
    map_any = map_periodic | map_aperiodic
    (
        vaso_interface,
        vaso_rate,
        vaso_med_interval,
        vaso_best,
        vaso_positive,
    ) = scan_vaso(args.eicu_root, keep, t0_min)
    vent = scan_vent(args.eicu_root, keep, t0_min)

    feature_sets = {
        "map_periodic": map_periodic,
        "map_aperiodic": map_aperiodic,
        "map_any": map_any,
        "vaso_infusion_interface_near_t0": vaso_interface,
        "vaso_rate_near_t0": vaso_rate,
        "vaso_active_med_interval": vaso_med_interval,
        "vaso_best_effort": vaso_best,
        "vaso_positive_best_effort": vaso_positive,
        "vent_explicit_state": vent["explicit_state"],
        "vent_explicit_on": vent["explicit_on"],
        "vent_explicit_off": vent["explicit_off"],
        "vent_setting_on": vent["setting_on"],
        "vent_care_interval_on": vent["care_interval_on"],
        "vent_treatment_support": vent["treatment_support"],
        "vent_clean": vent["clean"],
        "vent_positive_clean": vent["positive"],
    }
    for name, ids in feature_sets.items():
        cohort[name] = cohort.pid.isin(ids)

    pair_trt_rows = pairs.groupby("trt_hospitalid").size()
    pair_ctl_rows = pairs.groupby("ctl_hospitalid").size()
    pair_trt_unique = pairs.groupby("trt_hospitalid").trt_pid.nunique()
    pair_ctl_unique = pairs.groupby("ctl_hospitalid").ctl_pid.nunique()
    same_site = pairs[pairs.trt_hospitalid.eq(pairs.ctl_hospitalid)]
    same_site_rows = same_site.groupby("trt_hospitalid").size()

    rows = []
    for hospitalid, site in cohort.groupby("hospitalid", sort=True):
        row = {"hospitalid": int(hospitalid)}
        for arm_value, arm_name in ((1, "treated"), (0, "control")):
            arm = site[site.treated.eq(arm_value)]
            den = len(arm)
            row[f"n_{arm_name}"] = den
            for name in feature_sets:
                count = int(arm[name].sum())
                row[f"{name}_n_{arm_name}"] = count
                row[f"{name}_pct_{arm_name}"] = pct(count, den)

        row["frozen_pair_rows_treated_site"] = int(pair_trt_rows.get(hospitalid, 0))
        row["frozen_pair_rows_control_site"] = int(pair_ctl_rows.get(hospitalid, 0))
        row["frozen_unique_treated_site"] = int(pair_trt_unique.get(hospitalid, 0))
        row["frozen_unique_control_site"] = int(pair_ctl_unique.get(hospitalid, 0))
        row["frozen_same_site_pair_rows"] = int(same_site_rows.get(hospitalid, 0))

        row["map_pass_both"] = (
            row["map_any_pct_treated"] >= MAP_THRESHOLD
            and row["map_any_pct_control"] >= MAP_THRESHOLD
        )
        row["vaso_best_effort_pass_both"] = (
            row["vaso_best_effort_pct_treated"] >= VASO_THRESHOLD
            and row["vaso_best_effort_pct_control"] >= VASO_THRESHOLD
        )
        row["vent_clean_pass_both"] = (
            row["vent_clean_pct_treated"] >= VENT_THRESHOLD
            and row["vent_clean_pct_control"] >= VENT_THRESHOLD
        )
        row["n_treated_pass"] = row["n_treated"] >= MIN_TREATED
        row["high_fidelity_site"] = all(
            row[x]
            for x in (
                "map_pass_both",
                "vaso_best_effort_pass_both",
                "vent_clean_pass_both",
                "n_treated_pass",
            )
        )
        row["vaso_schema_note"] = (
            "best-effort only: infusionDrug has point offsets/rates but no stop; "
            "medication contributes only explicit active IV pressor intervals"
        )
        row["vent_schema_note"] = (
            "absence is not off; treatment events are support-only and excluded "
            "from clean recoverability"
        )
        rows.append(row)

    site_table = pd.DataFrame(rows).sort_values("hospitalid")
    qualifying = site_table[site_table.high_fidelity_site]
    qualifying_ids = set(qualifying.hospitalid.astype(int))
    subset = cohort[cohort.hospitalid.isin(qualifying_ids)]
    qualifying_pairs = pairs[pairs.trt_hospitalid.isin(qualifying_ids)]
    summary = pd.DataFrame(
        [
            {
                "n_sites_total": len(site_table),
                "n_sites_qualifying": len(qualifying),
                "qualifying_hospitalids": ";".join(map(str, sorted(qualifying_ids))),
                "pooled_n_treated": int(subset.treated.eq(1).sum()),
                "pooled_n_control": int(subset.treated.eq(0).sum()),
                "pooled_frozen_pair_rows_by_treated_site": len(qualifying_pairs),
                "pooled_frozen_unique_treated": qualifying_pairs.trt_pid.nunique(),
                "pooled_frozen_unique_control": qualifying_pairs.ctl_pid.nunique(),
                "map_threshold_both_arms": MAP_THRESHOLD,
                "vaso_best_effort_threshold_both_arms": VASO_THRESHOLD,
                "vent_clean_threshold_both_arms": VENT_THRESHOLD,
                "minimum_albumin_treated": MIN_TREATED,
                "control_index_definition": "cr_ref_early_offset_h",
                "treated_index_definition": "first albumin offset",
                "model_fit": False,
            }
        ]
    )

    args.results.mkdir(parents=True, exist_ok=True)
    site_table.to_csv(args.results / "eicu_site_completeness.csv", index=False)
    summary.to_csv(args.results / "eicu_high_fidelity_summary.csv", index=False)
    print(
        "probe_eicu_site_completeness.py | COMPLETE | "
        f"sites={len(site_table)} qualifying={len(qualifying)} | "
        "raw-table completeness only; no model fit"
    )


if __name__ == "__main__":
    main()
