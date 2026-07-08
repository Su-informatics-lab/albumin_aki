#!/usr/bin/env python
"""
01c_endpoints.py -- Structured endpoint extraction for F-MPAO / infection analysis.

Extracts from tables NOT scanned by 01_etl or 01b:
  - microbiologyevents  → cultures (blood, respiratory, urine, wound) with timing
  - prescriptions       → antibiotics with start/stop and timing
  - diagnoses_icd       → infection-related ICD codes (pneumonia, sepsis, UTI, SSI)

MIMIC-IV only (eICU infection endpoints are diagnosis-class only, handled in 01_etl).

Usage (Tempest):
  module purge; module load Python/3.10.8-GCCcore-12.2.0; source ~/alcrx/.venv/bin/activate
  python 01c_endpoints.py
"""

import os

import numpy as np
import pandas as pd

RESULTS = os.path.expanduser("~/albumin_aki/results")
MIMIC = os.path.expanduser("~/mg_aki/mimic-iv-3.1")
MIMIC_HOSP = os.path.join(MIMIC, "hosp")


def rule(t):
    print("\n" + "=" * 74 + "\n  " + t + "\n" + "=" * 74)


def _resolve(root, name):
    for ext in (".csv.gz", ".csv"):
        p = os.path.join(root, name + ext)
        if os.path.exists(p):
            return p
    raise FileNotFoundError(f"{name} not under {root}")


def _save(df, name):
    p = os.path.join(RESULTS, name)
    df.to_csv(p, index=False)
    npid = df.iloc[:, 0].nunique() if len(df) else 0
    print(f"    -> {name:<30} rows={len(df):>9,}  pids={npid:>7,}")


def run():
    rule("01c -- Structured endpoint extraction (MIMIC-IV)")
    # Load cohort
    d = pd.read_csv(os.path.join(RESULTS, "did_all_mimic.csv"), low_memory=False)
    stays = set(pd.to_numeric(d.pid, errors="coerce").dropna().astype(int))
    icu = pd.read_csv(
        _resolve(os.path.join(MIMIC, "icu"), "icustays"),
        usecols=["stay_id", "hadm_id", "intime"],
    )
    icu = icu[icu.stay_id.isin(stays)].copy()
    icu["intime"] = pd.to_datetime(icu["intime"])
    intime = dict(zip(icu.stay_id, icu.intime))
    hadm2stay = dict(zip(icu.hadm_id, icu.stay_id))
    hadms = set(icu.hadm_id.astype(int))
    stay2hadm = dict(zip(icu.stay_id, icu.hadm_id))
    n = len(stays)
    print(f"  cohort stays={n:,}  hadms={len(hadms):,}")

    # ── microbiologyevents: cultures ──────────────────────────────
    print("\n  microbiologyevents: cultures ...")
    mc = pd.read_csv(
        _resolve(MIMIC_HOSP, "microbiologyevents"),
        usecols=[
            "hadm_id",
            "chartdate",
            "charttime",
            "spec_type_desc",
            "org_name",
            "interpretation",
        ],
        low_memory=False,
    )
    mc = mc[mc.hadm_id.isin(hadms)].copy()
    mc["pid"] = mc.hadm_id.map(hadm2stay)
    # charttime can be null; fall back to chartdate
    ct = pd.to_datetime(mc.charttime, errors="coerce")
    cd = pd.to_datetime(mc.chartdate, errors="coerce")
    mc["event_time"] = ct.where(ct.notna(), cd)
    mc["offset_h"] = (mc.event_time - mc.pid.map(intime)).dt.total_seconds() / 3600.0
    # classify specimen type
    spec = mc.spec_type_desc.astype(str).str.lower()
    mc["spec_group"] = np.where(
        spec.str.contains("blood"),
        "blood",
        np.where(
            spec.str.contains("sputum|bronchoalveolar|tracheal|respiratory"),
            "respiratory",
            np.where(
                spec.str.contains("urine"),
                "urine",
                np.where(
                    spec.str.contains("wound|tissue|sternum|mediastin"),
                    "wound",
                    "other",
                ),
            ),
        ),
    )
    mc["positive"] = mc.org_name.notna().astype(int)
    _save(
        mc[["pid", "spec_group", "offset_h", "positive", "org_name"]],
        "strm_culture_mimic.csv",
    )
    # summary
    for sg in ["blood", "respiratory", "urine", "wound"]:
        sub = mc[mc.spec_group == sg]
        pos = sub[sub.positive == 1]
        print(
            f"     {sg:<12} cultures={sub.pid.nunique():>5}  positive={pos.pid.nunique():>5}  "
            f"({100*pos.pid.nunique()/n:.1f}%)"
        )

    # ── prescriptions: antibiotics ────────────────────────────────
    print("\n  prescriptions: antibiotics ...")
    ABX_RE = (
        r"cefazolin|cefepime|ceftriaxone|cefuroxime|ceftazidime|cefoxitin|"
        r"vancomycin|piperacillin|tazobactam|meropenem|imipenem|ertapenem|"
        r"levofloxacin|ciprofloxacin|moxifloxacin|azithromycin|metronidazole|"
        r"doxycycline|trimethoprim|sulfamethoxazole|linezolid|daptomycin|"
        r"ampicillin|amoxicillin|gentamicin|tobramycin|amikacin|clindamycin|"
        r"fluconazole|micafungin|voriconazole|amphotericin|colistin|polymyxin"
    )
    rx = pd.read_csv(
        _resolve(MIMIC_HOSP, "prescriptions"),
        usecols=["hadm_id", "drug", "starttime", "stoptime", "route"],
        low_memory=False,
    )
    rx = rx[rx.hadm_id.isin(hadms)].copy()
    drug_lc = rx.drug.astype(str).str.lower()
    rx = rx[drug_lc.str.contains(ABX_RE, na=False, regex=True)].copy()
    rx["pid"] = rx.hadm_id.map(hadm2stay)
    rx["start_h"] = (
        pd.to_datetime(rx.starttime, errors="coerce") - rx.pid.map(intime)
    ).dt.total_seconds() / 3600.0
    rx["stop_h"] = (
        pd.to_datetime(rx.stoptime, errors="coerce") - rx.pid.map(intime)
    ).dt.total_seconds() / 3600.0
    rx["route"] = rx.route.astype(str).str.lower()
    rx["iv"] = rx.route.str.contains("iv|intraven", na=False).astype(int)
    _save(
        rx[["pid", "drug", "start_h", "stop_h", "iv"]].rename(
            columns={"drug": "abx_name"}
        ),
        "strm_abx_mimic.csv",
    )
    print(f"     any abx:   {100*rx.pid.nunique()/n:.1f}%  rows={len(rx):,}")
    # new abx after 48h (proxy for new infection treatment)
    abx48 = rx[rx.start_h > 48]
    print(f"     new abx >48h: {100*abx48.pid.nunique()/n:.1f}%")

    # ── diagnoses_icd: infection-related codes ────────────────────
    print("\n  diagnoses_icd: infection ICD codes ...")
    dx = pd.read_csv(
        _resolve(MIMIC_HOSP, "diagnoses_icd"),
        usecols=["hadm_id", "icd_code", "icd_version", "seq_num"],
    )
    dx = dx[dx.hadm_id.isin(hadms)].copy()
    dx["pid"] = dx.hadm_id.map(hadm2stay)
    code = dx.icd_code.astype(str).str.replace(".", "", regex=False).str.upper()

    INF_ICD = {
        "pneumonia": {
            9: ["480", "481", "482", "483", "484", "485", "486"],
            10: ["J12", "J13", "J14", "J15", "J16", "J17", "J18"],
        },
        "sepsis": {
            9: ["99591", "99592", "78552"],
            10: ["A40", "A41", "R6520", "R6521"],
        },
        "uti": {
            9: ["5990"],
            10: ["N390"],
        },
        "ssi_mediastinitis": {
            9: ["99859", "5191"],  # post-op infection, mediastinitis
            10: ["T8144", "T814", "J985"],  # SSI, mediastinitis
        },
        "endocarditis": {
            9: ["4210", "4211", "4219"],
            10: ["I33", "I38", "I39"],
        },
    }
    rows = []
    for dx_name, ver_map in INF_ICD.items():
        for ver, prefixes in ver_map.items():
            for pf in prefixes:
                mask = (dx.icd_version == ver) & code.str.startswith(pf)
                if mask.any():
                    sub = dx[mask].copy()
                    sub["dx_name"] = dx_name
                    rows.append(
                        sub[["pid", "dx_name", "icd_code", "icd_version", "seq_num"]]
                    )
    if rows:
        inf = pd.concat(rows, ignore_index=True)
        _save(inf, "dx_infection_mimic.csv")
        for dn in INF_ICD:
            c = inf[inf.dx_name == dn].pid.nunique()
            print(f"     {dn:<20} {100*c/n:.1f}%  (n={c:,})")
    else:
        print("     (no infection ICD codes matched)")
        pd.DataFrame(
            columns=["pid", "dx_name", "icd_code", "icd_version", "seq_num"]
        ).to_csv(os.path.join(RESULTS, "dx_infection_mimic.csv"), index=False)


if __name__ == "__main__":
    run()
    print("\nDONE.")
