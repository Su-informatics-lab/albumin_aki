#!/usr/bin/env python
"""
qc_probe.py -- Coverage + event rate QC for all ETL outputs.

Reads everything in ~/albumin_aki/results/ and prints a comprehensive report.
Run after 01_etl, 01b, 01c, and (optionally) after LLM extraction lands.

Usage:
  python qc_probe.py
"""

import os

import pandas as pd

R = os.path.expanduser("~/albumin_aki/results")


def _load(name):
    p = os.path.join(R, name)
    if os.path.exists(p):
        return pd.read_csv(p, low_memory=False)
    return None


def hdr(t):
    print("\n" + "=" * 70 + f"\n  {t}\n" + "=" * 70)


def pct(n, d):
    return f"{100*n/d:.1f}%" if d else "n/a"


def run():
    for db in ("mimic", "eicu"):
        d = _load(f"did_all_{db}.csv")
        if d is None:
            print(f"  {db}: did_all not found, skip")
            continue
        n = len(d)
        n_t = (d.treated == 1).sum()
        hdr(f"{db.upper()} -- cohort {n:,} (treated {n_t:,})")

        # ── PS vitals (MIMIC only) ──
        vt = _load(f"strm_vitals_{db}.csv")
        if vt is not None:
            print("  PS vitals (0-3h coverage):")
            vt3 = vt[(vt.offset_h >= 0) & (vt.offset_h <= 3)]
            for v in ["temperature", "spo2", "fio2", "peep"]:
                c = vt3[vt3.vital == v].pid.nunique() if "vital" in vt3.columns else 0
                print(f"    {v:<14} {pct(c, n)}")

        # ── Extended labs (0-6h window) ──
        le = _load(f"labs_ext_{db}.csv")
        if le is not None:
            print("  Extended labs (any record in 0-6h):")
            le6 = le[(le.offset_h >= 0) & (le.offset_h <= 6)]
            for lab in [
                "platelet",
                "inr",
                "ptt",
                "sodium",
                "potassium",
                "chloride",
                "magnesium",
                "bun",
                "bicarbonate",
                "ph",
                "base_excess",
                "bilirubin",
                "alt",
                "ast",
                "wbc",
                "hct",
            ]:
                c = le6[le6.lab_name == lab].pid.nunique()
                print(f"    {lab:<14} {pct(c, n)}")

        # ── Cr variants (MIMIC only) ──
        cv = _load(f"cr_variants_{db}.csv")
        if cv is not None:
            print("  Cr variants:")
            for c in ["first_icu_cr_3h", "first_icu_cr_6h", "pre_icu_cr"]:
                if c in cv.columns:
                    print(f"    {c:<20} {pct(cv[c].notna().sum(), n)}")

        # ── Albumin dose (MIMIC only) ──
        ad = _load(f"alb_dose_24h_{db}.csv")
        if ad is not None:
            print("  Albumin dose (0-24h, treated only):")
            print(f"    patients with dose data: {len(ad):,}")
            print(
                f"    total_g median={ad.total_g.median():.1f}  IQR=[{ad.total_g.quantile(.25):.1f}, {ad.total_g.quantile(.75):.1f}]"
            )
            print(f"    n_infusions median={ad.n_infusions.median():.0f}")

        # ── Structured endpoints (MIMIC only) ──
        cult = _load(f"strm_culture_{db}.csv")
        if cult is not None:
            print("  Cultures (positive after 48h):")
            c48 = cult[(cult.offset_h > 48) & (cult.positive == 1)]
            for sg in ["blood", "respiratory", "urine", "wound"]:
                c = c48[c48.spec_group == sg].pid.nunique()
                print(f"    {sg:<14} {pct(c, n)}  (n={c})")

        abx = _load(f"strm_abx_{db}.csv")
        if abx is not None:
            n_new = abx[abx.start_h > 48].pid.nunique()
            print(f"  New antibiotics >48h: {pct(n_new, n)}  (n={n_new})")

        dxi = _load(f"dx_infection_{db}.csv")
        if dxi is not None:
            print("  Infection ICD:")
            for dn in [
                "pneumonia",
                "sepsis",
                "uti",
                "ssi_mediastinitis",
                "endocarditis",
            ]:
                c = dxi[dxi.dx_name == dn].pid.nunique()
                print(f"    {dn:<20} {pct(c, n)}  (n={c})")

        # ── LLM endpoints (if available) ──
        llm = _load(f"llm_endpoints_{db}.csv")
        if llm is not None:
            print("  LLM endpoints:")
            for col in llm.columns:
                if col in ("pid", "hadm_id", "note_id"):
                    continue
                pos = (llm[col] == 1).sum()
                fail = (llm[col] == -1).sum()
                print(f"    {col:<24} {pct(pos, n)}  (n={pos}, failed={fail})")
        else:
            print("  LLM endpoints: not yet available (waiting for Codex)")

        # ── F-MPAO component feasibility ──
        print("  F-MPAO components (event rates, full cohort):")
        mort = d.get("hosp_mortality", d.get("mortality"))
        if mort is not None:
            print(f"    death              {pct(int(mort.sum()), n)}")

        bl = _load(f"strm_blood_{db}.csv")
        if bl is not None:
            rbc4 = (
                bl[(bl.product == "RBC") & (bl.offset_h <= 48)]
                .groupby("pid")
                .amount.sum()
            )
            n_rbc4 = (rbc4 >= 4).sum()  # crude: 4 events ~ 4 units
            print(f"    RBC>=4 events 0-48h {pct(n_rbc4, n)}")

        out = _load(f"strm_output_{db}.csv")
        if out is not None:
            ct48 = (
                out[(out.kind == "chesttube") & (out.offset_h <= 48)]
                .groupby("pid")
                .amount_ml.sum()
            )
            n_drain = (ct48 > 1500).sum()
            print(f"    drainage>1500mL 0-48h {pct(n_drain, n)}")

        vent = _load(f"strm_vent_{db}.csv")
        if vent is not None:
            dur = vent.groupby("pid").t_end_h.max()
            n_mv48 = (dur > 48).sum()
            print(f"    MV>48h             {pct(n_mv48, n)}")

        vaso = _load(f"strm_vaso_{db}.csv")
        if vaso is not None:
            vdur = vaso.groupby("pid").t_end_h.max()
            n_v48 = (vdur > 48).sum()
            print(f"    vasopressor>48h    {pct(n_v48, n)}")


if __name__ == "__main__":
    run()
    print("\nDONE.")
