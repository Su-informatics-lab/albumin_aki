#!/usr/bin/env python
"""
01b_covariates.py -- Covariate / event-stream extraction for the landmark redesign.

Run AFTER 01_etl.py (needs did_all_{db}.csv for the cohort + ICU intime map) and
BEFORE the landmark PS step. Emits time-stamped event streams; all windowing
(ICU0->T0, T0->24h, 24->48/72h) is done downstream in R at each patient's T0.

Two-tier per the agreed design:
  MIMIC = full   : vasopressors, ventilation (segments + charted settings), MAP,
                   crystalloid/colloid, blood products, urine + chest-tube drainage,
                   diuretics, extended coag/chem labs, surgery-granularity flags.
  eICU  = light  : vasopressor (binary/count usable), apache day-1 vent flag,
                   MAP (arterial OR noninvasive), extended labs, aortic/emergency flags.

All itemids are either confirmed from the probe or derived at runtime from
d_items / d_labitems by regex. Nothing hardcoded that wasn't verified.

Outputs -> ~/albumin_aki/results/ (patient-level; DUA => never commit, gitignore).

Usage (Tempest):
  module purge; module load Python/3.10.8-GCCcore-12.2.0; source ~/alcrx/.venv/bin/activate
  python 01b_covariates.py mimic          # full (chartevents MAP+vent scan is the slow step)
  python 01b_covariates.py mimic nomap    # skip chartevents (MAP + ventset) for a fast pass
  python 01b_covariates.py eicu
"""

import os
import sys

import numpy as np
import pandas as pd

RESULTS = os.path.expanduser("~/albumin_aki/results")
MIMIC = os.path.expanduser("~/mg_aki/mimic-iv-3.1")
MIMIC_HOSP = os.path.join(MIMIC, "hosp")
MIMIC_ICU = os.path.join(MIMIC, "icu")
_FULL = os.path.expanduser("~/mg_aki/eicu-crd-2.0")
_DEMO = os.path.expanduser("~/mg_aki/eicu-collaborative-research-database-demo-2.0.1")
EICU = _FULL if os.path.isdir(_FULL) else _DEMO


def rule(t):
    print("\n" + "=" * 74 + "\n  " + t + "\n" + "=" * 74)


def _resolve(root, name):
    for ext in (".csv.gz", ".csv"):
        p = os.path.join(root, name + ext)
        if os.path.exists(p):
            return p
    raise FileNotFoundError(f"{name} not under {root}")


def _cohort(tag):
    f = os.path.join(RESULTS, f"did_all_{tag}.csv")
    if not os.path.exists(f):
        sys.exit(f"MISSING {f} -- run 01_etl.py first")
    return pd.read_csv(f, low_memory=False)


def _save(df, name):
    p = os.path.join(RESULTS, name)
    df.to_csv(p, index=False)
    npid = df.iloc[:, 0].nunique() if len(df) else 0
    print(f"    -> {name:<26} rows={len(df):>9,}  pids={npid:>7,}")


def _chunk(path, usecols, keycol, keep, itemcol=None, items=None, chunk=5_000_000):
    keep = set(keep)
    items = set(items) if items is not None else None
    out = []
    for ch in pd.read_csv(path, usecols=usecols, chunksize=chunk, low_memory=False):
        m = ch[keycol].isin(keep)
        if itemcol is not None:
            m &= ch[itemcol].isin(items)
        if m.any():
            out.append(ch.loc[m, usecols])
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame(columns=usecols)


# ══════════════════════════════════════════════════════════════════════
# MIMIC  (full)
# ══════════════════════════════════════════════════════════════════════
def run_mimic(skip_map=False):
    rule("01b -- MIMIC covariate/event-stream extraction (full)")
    coh = _cohort("mimic")
    stays = set(pd.to_numeric(coh.pid, errors="coerce").dropna().astype(int))
    n = len(stays)

    icu = pd.read_csv(
        _resolve(MIMIC_ICU, "icustays"), usecols=["stay_id", "hadm_id", "intime"]
    )
    icu = icu[icu.stay_id.isin(stays)].copy()
    icu["intime"] = pd.to_datetime(icu["intime"])
    intime = dict(zip(icu.stay_id, icu.intime))
    hadm2stay = dict(zip(icu.hadm_id, icu.stay_id))
    hadms = set(icu.hadm_id.astype(int))
    print(f"  cohort stays={n:,}  hadms={len(hadms):,}")

    di = pd.read_csv(_resolve(MIMIC_ICU, "d_items"))
    dl = pd.read_csv(_resolve(MIMIC_HOSP, "d_labitems"))

    def items(regex, linksto):
        m = di[di.label.str.contains(regex, case=False, na=False, regex=True)]
        m = m[m.linksto == linksto]
        return dict(zip(m.itemid, m.label))

    def off_dt(df, tcol, id2time, idcol="stay_id"):
        base = df[idcol].map(id2time)
        return (pd.to_datetime(df[tcol]) - base).dt.total_seconds() / 3600.0

    # ---------- inputevents: vaso / fluids / blood / diuretic (one scan) ----------
    print("  inputevents: vaso + fluids + blood + diuretic ...")
    VASO = {
        "NE": items(r"^norepinephrine", "inputevents"),
        "EPI": items(r"^epinephrine", "inputevents"),
        "DOPA": items(r"^dopamine", "inputevents"),
        "DOBUT": items(r"^dobutamine", "inputevents"),
        "PHENYL": items(r"phenylephrine", "inputevents"),
        "VASO": items(r"^vasopressin", "inputevents"),
        "MILRIN": items(r"^milrinone", "inputevents"),
    }
    CRYS = items(
        r"sodium chloride 0.9|lactated ringer|plasmalyte|plasma-lyte|"
        r"dextrose 5|d5|0.45|half normal|normosol|isolyte",
        "inputevents",
    )
    COLL = items(
        r"hetastarch|hydroxyethyl|voluven|hespan|dextran|gelatin|hextend", "inputevents"
    )
    ALBI = items(r"albumin", "inputevents")
    BLOOD = {
        "RBC": items(r"packed red|prbc|red blood cell", "inputevents"),
        "FFP": items(r"fresh frozen|^ffp|plasma \(", "inputevents"),
        "PLT": items(r"platelet", "inputevents"),
        "CRYO": items(r"cryoprecipitate", "inputevents"),
    }
    DIUR = items(r"furosemide|bumetanide|torsemide|lasix", "inputevents")

    item2class_vaso = {i: k for k, d in VASO.items() for i in d}
    item2class_blood = {i: k for k, d in BLOOD.items() for i in d}
    fluid_map = {
        **{i: "crystalloid" for i in CRYS},
        **{i: "colloid" for i in COLL},
        **{i: "albumin" for i in ALBI},
    }
    want = set(item2class_vaso) | set(fluid_map) | set(item2class_blood) | set(DIUR)

    ie = _chunk(
        _resolve(MIMIC_ICU, "inputevents"),
        [
            "stay_id",
            "starttime",
            "endtime",
            "itemid",
            "amount",
            "amountuom",
            "rate",
            "rateuom",
            "patientweight",
        ],
        "stay_id",
        stays,
        "itemid",
        want,
    )
    ie["t_start_h"] = off_dt(ie, "starttime", intime)
    ie["t_end_h"] = off_dt(ie, "endtime", intime)

    vaso = ie[ie.itemid.isin(item2class_vaso)].copy()
    vaso["class"] = vaso.itemid.map(item2class_vaso)
    _save(
        vaso[
            [
                "stay_id",
                "class",
                "t_start_h",
                "t_end_h",
                "rate",
                "rateuom",
                "patientweight",
            ]
        ].rename(columns={"stay_id": "pid"}),
        "strm_vaso_mimic.csv",
    )

    ml = ie.amountuom.astype(str).str.lower().str.contains("ml")
    fl = ie[ie.itemid.isin(fluid_map) & ml].copy()
    fl["class"] = fl.itemid.map(fluid_map)
    _save(
        fl[["stay_id", "class", "t_start_h", "amount"]].rename(
            columns={"stay_id": "pid", "t_start_h": "offset_h", "amount": "amount_ml"}
        ),
        "strm_fluid_mimic.csv",
    )

    bl = ie[ie.itemid.isin(item2class_blood)].copy()
    bl["product"] = bl.itemid.map(item2class_blood)
    _save(
        bl[["stay_id", "product", "t_start_h", "amount", "amountuom"]].rename(
            columns={"stay_id": "pid", "t_start_h": "offset_h"}
        ),
        "strm_blood_mimic.csv",
    )

    du = ie[ie.itemid.isin(DIUR)].copy()
    _save(
        du[["stay_id", "t_start_h", "amount", "amountuom"]].rename(
            columns={"stay_id": "pid", "t_start_h": "offset_h"}
        ),
        "strm_diuretic_mimic.csv",
    )

    # ---------- outputevents: urine + chest tube ----------
    print("  outputevents: urine + chest-tube drainage ...")
    URINE = items(r"foley|urine|void", "outputevents")
    CHEST = items(r"chest tube|mediastinal|pleural", "outputevents")
    oitems = set(URINE) | set(CHEST)
    oe = _chunk(
        _resolve(MIMIC_ICU, "outputevents"),
        ["stay_id", "charttime", "itemid", "value"],
        "stay_id",
        stays,
        "itemid",
        oitems,
    )
    oe["offset_h"] = off_dt(oe, "charttime", intime)
    oe["kind"] = np.where(oe.itemid.isin(CHEST), "chesttube", "urine")
    _save(
        oe[["stay_id", "kind", "offset_h", "value"]].rename(
            columns={"stay_id": "pid", "value": "amount_ml"}
        ),
        "strm_output_mimic.csv",
    )

    # ---------- procedureevents: ventilation segments ----------
    print("  procedureevents: ventilation segments ...")
    VENT = items(
        r"invasive ventilation|non-invasive ventilation|intubation", "procedureevents"
    )
    pe = _chunk(
        _resolve(MIMIC_ICU, "procedureevents"),
        ["stay_id", "starttime", "endtime", "itemid"],
        "stay_id",
        stays,
        "itemid",
        set(VENT),
        chunk=2_000_000,
    )
    pe["t_start_h"] = off_dt(pe, "starttime", intime)
    pe["t_end_h"] = off_dt(pe, "endtime", intime)
    pe["mode"] = pe.itemid.map(VENT)
    n_seg_pid = pe["stay_id"].nunique()
    _save(
        pe[["stay_id", "t_start_h", "t_end_h", "mode"]].rename(
            columns={"stay_id": "pid"}
        ),
        "strm_vent_mimic.csv",
    )

    # ---------- chartevents: MAP + ventilator-setting presence (one scan; slow) ----------
    if skip_map:
        print("  chartevents MAP + ventset: SKIPPED (nomap)")
    else:
        print("  chartevents: MAP + ventilator settings (scans ~430M rows; slow) ...")
        MAP = items(
            r"^arterial blood pressure mean|^non invasive blood pressure mean",
            "chartevents",
        )
        # vent-specific settings (chart only when mechanically ventilated); FiO2 excluded
        # to avoid NIV / high-flow false positives.
        VSET = items(
            r"ventilator mode|peep set|tidal volume|respiratory rate \(set\)",
            "chartevents",
        )
        ci = set(MAP) | set(VSET)
        ce = _chunk(
            _resolve(MIMIC_ICU, "chartevents"),
            ["stay_id", "charttime", "itemid", "valuenum"],
            "stay_id",
            stays,
            "itemid",
            ci,
            chunk=8_000_000,
        )
        ce["offset_h"] = off_dt(ce, "charttime", intime)

        cm = ce[ce.itemid.isin(set(MAP)) & ce.valuenum.between(20, 200)]
        _save(
            cm[["stay_id", "offset_h", "valuenum"]].rename(
                columns={"stay_id": "pid", "valuenum": "map"}
            ),
            "strm_map_mimic.csv",
        )

        cv = ce[ce.itemid.isin(set(VSET))].copy()
        cv["hr"] = np.floor(cv.offset_h)  # thin to 1 row/stay/hour
        cv = cv.sort_values(["stay_id", "offset_h"]).drop_duplicates(["stay_id", "hr"])
        _save(
            cv[["stay_id", "offset_h"]].rename(columns={"stay_id": "pid"}),
            "strm_ventset_mimic.csv",
        )
        print(
            f"     vent coverage: segments={100*n_seg_pid/n:.1f}%  "
            f"charted-settings={100*cv.stay_id.nunique()/n:.1f}%"
        )

    # ---------- labevents: extended coag/chem ----------
    print("  labevents: extended coag/chem (by hadm) ...")
    LABRX = {
        "platelet": r"platelet count",
        "inr": r"^inr|international normal",
        "pt": r"prothrombin time|^pt$",
        "ptt": r"^ptt|partial thromboplastin",
        "sodium": r"^sodium",
        "bun": r"urea nitrogen",
        "bicarbonate": r"^bicarbonate",
        "bilirubin": r"bilirubin, total",
        "alt": r"alanine amino",
        "ast": r"aspartate amino|asparate amino",
        "wbc": r"white blood cell",
        "hct": r"^hematocrit",
    }
    blood_lab = dl[dl.fluid.str.contains("Blood", case=False, na=False)]
    lab_items, item2lab = set(), {}
    for nm, rx in LABRX.items():
        hit = blood_lab[
            blood_lab.label.str.contains(rx, case=False, na=False, regex=True)
        ]
        for i in hit.itemid:
            item2lab[i] = nm
            lab_items.add(i)
    le = _chunk(
        _resolve(MIMIC_HOSP, "labevents"),
        ["hadm_id", "itemid", "charttime", "valuenum"],
        "hadm_id",
        hadms,
        "itemid",
        lab_items,
    )
    le = le[le.hadm_id.isin(hadm2stay)].copy()
    le["pid"] = le.hadm_id.map(hadm2stay)
    le["lab_name"] = le.itemid.map(item2lab)
    le["offset_h"] = (
        pd.to_datetime(le.charttime) - le.pid.map(intime)
    ).dt.total_seconds() / 3600.0
    le = le.dropna(subset=["valuenum"])
    _save(
        le[["pid", "lab_name", "valuenum", "offset_h"]].rename(
            columns={"valuenum": "value"}
        ),
        "labs_ext_mimic.csv",
    )

    # ---------- surgery granularity (static flags) + aortic audit ----------
    print("  diagnoses_icd / procedures_icd / admissions: surgery flags ...")
    px = pd.read_csv(
        _resolve(MIMIC_HOSP, "procedures_icd"),
        usecols=["hadm_id", "icd_code", "icd_version"],
    )
    dx = pd.read_csv(
        _resolve(MIMIC_HOSP, "diagnoses_icd"),
        usecols=["hadm_id", "icd_code", "icd_version"],
    )
    adm = pd.read_csv(
        _resolve(MIMIC_HOSP, "admissions"), usecols=["hadm_id", "admission_type"]
    )
    px = px[px.hadm_id.isin(hadms)]
    dx = dx[dx.hadm_id.isin(hadms)]

    def _pref(df, codes):
        code = df.icd_code.astype(str).str.replace(".", "", regex=False).str.upper()
        m = pd.Series(False, index=df.index)
        for c in codes:
            m |= code.str.startswith(c)
        return set(df.loc[m, "hadm_id"])

    # aortic procedures: ICD-9 384x; ICD-10-PCS thoracic aorta (W=descending, X=ascending/arch)
    # W = Thoracic Aorta, Descending; X = Thoracic Aorta, Ascending/Arch
    AORTIC_CODES = (
        "3834",
        "3844",
        "3845",
        "021W",
        "021X",
        "02RW",
        "02RX",
        "02QW",
        "02QX",
        "02UW",
        "02UX",
        "02VW",
        "02VX",
        "02WW",
        "02WX",
    )
    aortic = _pref(px, AORTIC_CODES)
    # prior cardiac surgery (redo proxy): status codes for CABG/valve prostheses
    redo = _pref(dx, ["V4581", "V433", "Z951", "Z952", "Z953", "Z954"])
    emerg_types = {"EW EMER.", "DIRECT EMER.", "URGENT"}
    surg = pd.DataFrame({"pid": [hadm2stay[h] for h in hadms]}, index=list(hadms))
    surg["surg_aortic"] = [int(h in aortic) for h in surg.index]
    surg["prior_cardiac_surgery"] = [int(h in redo) for h in surg.index]
    at = dict(zip(adm.hadm_id, adm.admission_type.astype(str)))
    surg["adm_emergency"] = [int(at.get(h, "") in emerg_types) for h in surg.index]
    _save(surg.reset_index(drop=True), "surg_mimic.csv")
    print(
        f"    aortic={surg.surg_aortic.mean()*100:.1f}%  "
        f"prior_cardiac={surg.prior_cardiac_surgery.mean()*100:.1f}%  "
        f"emergency={surg.adm_emergency.mean()*100:.1f}%  "
        f"(NB: emergency = hospital admission_type, not surgical urgency)"
    )

    # aortic audit: which aorta/thoracic procedure codes actually appear (for clinical review)
    try:
        dpx = pd.read_csv(_resolve(MIMIC_HOSP, "d_icd_procedures"))
        lab = dict(zip(zip(dpx.icd_code.astype(str), dpx.icd_version), dpx.long_title))
        pa = px.copy()
        pa["long_title"] = [
            lab.get((str(c), v), "?") for c, v in zip(pa.icd_code, pa.icd_version)
        ]
        cand = pa[
            pa.long_title.astype(str).str.contains(
                r"aort|thoracic", case=False, na=False
            )
        ]
        top = (
            cand.groupby(["icd_version", "icd_code", "long_title"])
            .size()
            .sort_values(ascending=False)
            .head(15)
        )
        print("    AORTIC AUDIT (top aorta/thoracic procedure codes in cohort):")
        for (v, c, t), cnt in top.items():
            mark = (
                "*" if str(c).replace(".", "").upper().startswith(AORTIC_CODES) else " "
            )
            print(f"      {mark} ICD{v} {str(c):<7} n={cnt:<4} {str(t)[:64]}")
        print("      (* = currently counted as surg_aortic; review the rest with Yan)")
    except Exception as e:
        print(f"    (aortic audit skipped: {e})")


# ══════════════════════════════════════════════════════════════════════
# eICU  (light)
# ══════════════════════════════════════════════════════════════════════
def _eicu_chunk(name, keep, cols, chunk=3_000_000):
    keep = set(keep)
    out = []
    for ch in pd.read_csv(
        _resolve(EICU, name),
        usecols=lambda c: c in cols,
        chunksize=chunk,
        low_memory=False,
    ):
        m = ch["patientunitstayid"].isin(keep)
        if m.any():
            out.append(ch[m])
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame(columns=cols)


def run_eicu():
    rule("01b -- eICU covariate/event-stream extraction (light: PS-1 support)")
    coh = _cohort("eicu")
    pids = set(pd.to_numeric(coh.pid, errors="coerce").dropna().astype(int))
    n = len(pids)
    print(f"  cohort patientunitstayid={n:,}")

    # ---------- vasopressors: infusionDrug ----------
    print("  infusionDrug: vasopressors ...")
    idf = _eicu_chunk(
        "infusionDrug",
        pids,
        ["patientunitstayid", "infusionoffset", "drugname", "drugrate"],
    )
    if len(idf):
        dn = idf.drugname.astype(str).str.lower()

        def cls(s):
            if "norepineph" in s or "levophed" in s:
                return "NE"
            if "epinephrine" in s:
                return "EPI"
            if "vasopressin" in s:
                return "VASO"
            if "phenylephrine" in s or "neosynephrine" in s:
                return "PHENYL"
            if "dopamine" in s:
                return "DOPA"
            if "dobutamine" in s:
                return "DOBUT"
            if "milrinone" in s:
                return "MILRIN"
            return None

        idf["class"] = dn.map(cls)
        idf["unit_hint"] = idf.drugname.astype(str).str.extract(r"\(([^)]+)\)")
        vaso = idf[idf["class"].notna()].copy()
        vaso["offset_h"] = vaso.infusionoffset / 60.0
        _save(
            vaso[
                ["patientunitstayid", "class", "offset_h", "drugrate", "unit_hint"]
            ].rename(columns={"patientunitstayid": "pid", "drugrate": "rate"}),
            "strm_vaso_eicu.csv",
        )
        print(
            "     NB: coverage ~23% and hospital-confounded (infusionDrug not universally"
            " interfaced) -> treat as informative missingness; likely excluded from eICU PS."
        )
    else:
        print("    infusionDrug empty")

    # ---------- ventilation: apachePredVar day-1 flags ----------
    print("  apachePredVar: day-1 vent/intub flags ...")
    apv = _eicu_chunk(
        "apachePredVar", pids, ["patientunitstayid", "oobventday1", "oobintubday1"]
    )
    if len(apv):
        apv = apv.rename(
            columns={
                "patientunitstayid": "pid",
                "oobventday1": "vent_day1",
                "oobintubday1": "intub_day1",
            }
        )
        _save(apv[["pid", "vent_day1", "intub_day1"]], "vent_eicu.csv")
    else:
        print("    apachePredVar empty/columns differ")

    # ---------- MAP: vitalPeriodic (arterial OR noninvasive) ----------
    print("  vitalPeriodic: MAP (systemicmean OR noninvasivemean) ...")
    vp = _eicu_chunk(
        "vitalPeriodic",
        pids,
        ["patientunitstayid", "observationoffset", "systemicmean", "noninvasivemean"],
        chunk=4_000_000,
    )
    if len(vp):
        nan_s = pd.Series(np.nan, index=vp.index)
        sm = (
            pd.to_numeric(vp["systemicmean"], errors="coerce")
            if "systemicmean" in vp.columns
            else nan_s
        )
        nm = (
            pd.to_numeric(vp["noninvasivemean"], errors="coerce")
            if "noninvasivemean" in vp.columns
            else nan_s
        )
        vp["map"] = sm.where(sm.notna(), nm)
        vp["source"] = np.where(sm.notna(), "art", np.where(nm.notna(), "nibp", "na"))
        vp = vp[vp["map"].between(20, 200)]
        vp["offset_h"] = vp.observationoffset / 60.0
        _save(
            vp[["patientunitstayid", "offset_h", "map", "source"]].rename(
                columns={"patientunitstayid": "pid"}
            ),
            "strm_map_eicu.csv",
        )
        art = vp[vp.source == "art"].patientunitstayid.nunique()
        print(
            f"     MAP coverage {100*vp.patientunitstayid.nunique()/n:.1f}% "
            f"(arterial {100*art/n:.1f}%, rest NIBP)"
        )
    else:
        print("    vitalPeriodic empty")

    # ---------- extended labs ----------
    print("  lab: extended coag/chem ...")
    lb = _eicu_chunk(
        "lab", pids, ["patientunitstayid", "labresultoffset", "labname", "labresult"]
    )
    if len(lb):
        ln = lb.labname.astype(str).str.lower()
        LABRX = {
            "platelet": r"platelet",
            "inr": r"inr",
            "pt": r"^pt\b|prothrombin",
            "ptt": r"ptt",
            "sodium": r"^sodium",
            "bun": r"bun",
            "bicarbonate": r"bicarbonate|hco3|total co2",
            "bilirubin": r"total bilirubin",
            "wbc": r"wbc",
            "hct": r"hct|hematocrit",
        }
        rows = []
        for nm, rx in LABRX.items():
            sub = lb[ln.str.contains(rx, na=False, regex=True)].copy()
            if len(sub):
                sub["lab_name"] = nm
                rows.append(
                    sub.rename(
                        columns={"patientunitstayid": "pid", "labresult": "value"}
                    ).assign(offset_h=sub.labresultoffset / 60.0)[
                        ["pid", "lab_name", "value", "offset_h"]
                    ]
                )
        ext = (
            pd.concat(rows, ignore_index=True)
            if rows
            else pd.DataFrame(columns=["pid", "lab_name", "value", "offset_h"])
        )
        _save(ext, "labs_ext_eicu.csv")
    else:
        print("    lab empty")

    # ---------- surgery flags (aortic valve-excluded; emergency = admit source) ----------
    print("  patient: aortic (valve-excluded) / emergency flags ...")
    pat = pd.read_csv(
        _resolve(EICU, "patient"),
        usecols=lambda c: c
        in (
            "patientunitstayid",
            "apacheadmissiondx",
            "hospitaladmitsource",
            "unitadmitsource",
        ),
        low_memory=False,
    )
    pat = pat[pat.patientunitstayid.isin(pids)].copy()
    dxs = pat.apacheadmissiondx.astype(str).str.lower()
    aorta_pos = dxs.str.contains(
        r"aneurysm|dissection|thoracic aort|aorta repair|"
        r"aorta resection|aortic graft",
        na=False,
        regex=True,
    )
    aorta_bare = dxs.str.contains(
        r"\baorta\b", na=False, regex=True
    ) & ~dxs.str.contains("valve", na=False)
    src = (
        pat.get("hospitaladmitsource", pd.Series("", index=pat.index)).astype(str)
        + " "
        + pat.get("unitadmitsource", pd.Series("", index=pat.index)).astype(str)
    ).str.lower()
    surg = pd.DataFrame(
        {
            "pid": pat.patientunitstayid,
            "surg_aortic": (aorta_pos | aorta_bare).astype(int).values,
            "adm_emergency": src.str.contains("emergency", na=False).astype(int).values,
        }
    )
    _save(surg, "surg_eicu.csv")
    print(
        f"    aortic (valve-excluded)={surg.surg_aortic.mean()*100:.1f}%  "
        f"emergency={surg.adm_emergency.mean()*100:.1f}%  "
        f"(NB: emergency = admit source, not surgical urgency)"
    )


if __name__ == "__main__":
    db = (sys.argv[1].lower() if len(sys.argv) > 1 else "").strip()
    nomap = len(sys.argv) > 2 and sys.argv[2].lower() == "nomap"
    print(f"MIMIC={MIMIC}\nEICU={EICU}\nRESULTS={RESULTS}\ndb={db} nomap={nomap}")
    if db == "mimic":
        run_mimic(skip_map=nomap)
    elif db == "eicu":
        run_eicu()
    else:
        sys.exit("Usage: python 01b_covariates.py {mimic|eicu} [nomap]")
    print("\nDONE.")
