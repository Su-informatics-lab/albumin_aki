#!/usr/bin/env python3
"""Aggregate-only IUH albumin source audit for the cardiac-surgery ICU cohort."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import duckdb
import pandas as pd
import pyarrow.parquet as pq

KEEP_CVDSC = {
    "CABG (CORONARY ARTERY BYPASS GRAFT)",
    "CORONARY ARTERY BYPASS GRAFT",
    "CORONARY ARTERY BYPASS GRAFTING",
    "CABG",
    "AORTIC VALVE REPLACEMENT",
    "MITRAL VALVE REPAIR",
    "MITRAL VALVE REPLACEMENT",
    "TRICUSPID VALVE REPAIR",
    "TRICUSPID VALVE REPLACEMENT",
    "MULTIPLE VALVE SURGERY",
    "VALVE REPLACEMENT",
    "VALVE REPAIR",
    "ASCENDING AORTIC ANEURYSM REPAIR",
    "AORTIC ARCH REPAIR",
    "THORACIC AORTIC ANEURYSM REPAIR",
    "AORTIC ROOT REPLACEMENT",
    "BENTALL PROCEDURE",
    "DAVID PROCEDURE",
    "CABG WITH AORTIC VALVE REPLACEMENT",
    "CABG WITH MITRAL VALVE REPAIR",
    "CABG WITH MITRAL VALVE REPLACEMENT",
    "CABG WITH VALVE REPLACEMENT",
    "CABG WITH VALVE REPAIR",
    "CABG WITH AORTIC ANEURYSM REPAIR",
    "CABG WITH ASCENDING AORTIC ANEURYSM REPAIR",
    "VALVE SURGERY WITH AORTIC ANEURYSM REPAIR",
    "CARDIAC SURGERY",
    "OPEN HEART SURGERY",
    "CARDIOTHORACIC SURGERY",
    "PULMONARY THROMBOENDARTERECTOMY",
    "PULMONARY ENDARTERECTOMY",
    "ATRIAL SEPTAL DEFECT REPAIR",
    "VENTRICULAR SEPTAL DEFECT REPAIR",
    "MYXOMA RESECTION",
    "CARDIAC TUMOR RESECTION",
    "MAZE PROCEDURE",
    "PERICARDIECTOMY",
    "LEFT VENTRICULAR ANEURYSM REPAIR",
    "VENTRICULAR ASSIST DEVICE IMPLANTATION",
}


def cardiac_icu_cohort(base: Path) -> pd.DataFrame:
    proc_path = base / "processed" / "Procedure.parquet"
    icu_path = base / "derived" / "icustay_hourhrbp.parquet"
    proc = pq.read_table(
        proc_path,
        columns=[
            "subject_id",
            "hadm_id",
            "SurgicalStopDTS",
            "SurgicalProcedureCVDSC",
        ],
    ).to_pandas()
    proc["label"] = proc["SurgicalProcedureCVDSC"].fillna("").str.strip().str.upper()
    proc = proc[proc["label"].isin(KEEP_CVDSC)].copy()
    proc["surgery_stop"] = pd.to_datetime(proc["SurgicalStopDTS"], errors="coerce")
    proc = proc.dropna(subset=["subject_id", "hadm_id", "surgery_stop"])

    icu = pq.read_table(
        icu_path,
        columns=[
            "subject_id",
            "hadm_id",
            "stay_id",
            "unitin",
            "unitout",
        ],
    ).to_pandas()
    icu["unitin"] = pd.to_datetime(icu["unitin"], errors="coerce")
    icu["unitout"] = pd.to_datetime(icu["unitout"], errors="coerce")
    cohort = proc.merge(icu, on=["subject_id", "hadm_id"], how="inner")
    cohort = cohort[
        cohort["unitout"].notna() & (cohort["unitout"] > cohort["surgery_stop"])
    ].copy()
    cohort["postop_start"] = cohort[["unitin", "surgery_stop"]].max(axis=1)
    cohort = cohort.sort_values(
        ["subject_id", "postop_start", "unitout", "stay_id"]
    ).drop_duplicates("subject_id", keep="first")
    return cohort[
        [
            "subject_id",
            "hadm_id",
            "stay_id",
            "postop_start",
            "unitout",
        ]
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base",
        default="/N/project/Analgesia_management/IUH_DATA_2025/2019_2025",
    )
    parser.add_argument("--outdir", required=True)
    args = parser.parse_args()

    base = Path(args.base)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    cohort = cardiac_icu_cohort(base)

    con = duckdb.connect()
    con.execute("SET threads=2")
    con.execute("SET preserve_insertion_order=false")
    con.execute("SET memory_limit='20GB'")
    temp_dir = os.environ.get("TMPDIR", "/tmp")
    con.execute(f"SET temp_directory='{temp_dir}/duckdb_albumin_probe'")
    con.register("cohort", cohort)

    p = str(base / "processed")
    sources = {
        "io": f"""
            SELECT i.subject_id, i.hadm_id, i.IOdate AS event_time,
                   coalesce(i.Event, '') AS label,
                   coalesce(i.IO, '') AS detail,
                   try_cast(i.Vol AS DOUBLE) AS amount
            FROM read_parquet('{p}/IO.parquet') i
            JOIN cohort c USING (subject_id, hadm_id)
            WHERE lower(coalesce(i.Event, '') || ' ' || coalesce(i.IO, ''))
                  LIKE '%albumin%'
        """,
        "med": f"""
            SELECT m.subject_id, m.hadm_id, m.AdminDT AS event_time,
                   coalesce(m."ORDER", '') AS label,
                   coalesce(m.IVevent, '') AS detail,
                   try_cast(m.VolumeDose AS DOUBLE) AS amount
            FROM read_parquet('{p}/Med.parquet') m
            JOIN cohort c USING (subject_id, hadm_id)
            WHERE lower(coalesce(m."ORDER", '') || ' ' ||
                        coalesce(m.IVevent, '')) LIKE '%albumin%'
        """,
        "anesfluid": f"""
            SELECT a.subject_id, a.hadm_id, a.FluidDT AS event_time,
                   coalesce(a.Fluid, '') AS label,
                   '' AS detail,
                   try_cast(a.FluidVol AS DOUBLE) AS amount
            FROM read_parquet('{p}/AnesFluid.parquet') a
            JOIN cohort c USING (subject_id, hadm_id)
            WHERE lower(coalesce(a.Fluid, '')) LIKE '%albumin%'
        """,
    }

    label_rows = []
    source_rows = []
    for source, query in sources.items():
        con.execute(f"CREATE OR REPLACE TEMP VIEW alb AS {query}")
        labels = con.execute(
            """
            SELECT ? AS source, label, detail, count(*) AS rows,
                   count(DISTINCT subject_id) AS patients,
                   count(*) FILTER (WHERE amount > 0) AS positive_amount_rows
            FROM alb
            GROUP BY label, detail
            ORDER BY rows DESC, label, detail
            """,
            [source],
        ).fetchdf()
        label_rows.append(labels)
        summary = con.execute(
            """
            SELECT ? AS source,
                   count(*) AS albumin_rows,
                   count(DISTINCT subject_id) AS patients_any_time,
                   count(DISTINCT a.subject_id) FILTER (
                     WHERE try_cast(a.event_time AS TIMESTAMP) >= c.postop_start
                       AND try_cast(a.event_time AS TIMESTAMP) <= c.unitout
                   ) AS patients_postop_icu,
                   count(*) FILTER (
                     WHERE try_cast(a.event_time AS TIMESTAMP) >= c.postop_start
                       AND try_cast(a.event_time AS TIMESTAMP) <= c.unitout
                   ) AS rows_postop_icu,
                   count(*) FILTER (
                     WHERE try_cast(a.event_time AS TIMESTAMP) >= c.postop_start
                       AND try_cast(a.event_time AS TIMESTAMP) <= c.unitout
                       AND a.amount > 0
                   ) AS positive_amount_rows_postop_icu
            FROM alb a
            JOIN cohort c USING (subject_id, hadm_id)
            """,
            [source],
        ).fetchdf()
        source_rows.append(summary)

    pd.concat(label_rows, ignore_index=True).to_csv(
        outdir / "iuh_source_albumin_labels.csv", index=False
    )
    summary = pd.concat(source_rows, ignore_index=True)
    summary.insert(0, "cardiac_icu_patients", len(cohort))
    summary.to_csv(outdir / "iuh_source_albumin_summary.csv", index=False)
    print(summary.to_string(index=False))


if __name__ == "__main__":
    main()
