#!/usr/bin/env python3
"""Aggregate-only diagnosis of the frozen IUH pooled match."""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd

results = Path(
    os.path.expanduser(os.getenv("ALBUMIN_AKI_RESULTS", "~/albumin_aki/results"))
)
all_pts = pd.read_csv(results / "did_all_iuh.csv")
pairs = pd.read_csv(results / "did_pairs_primary_yet_untreated_pooled_iuh.csv")

rows = []


def add(metric: str, value: float, detail: str = "") -> None:
    rows.append({"metric": metric, "value": value, "detail": detail})


trt = all_pts[all_pts.treated == 1]
ctl = all_pts[all_pts.treated == 0]
# Pair indices are serialized from R and are therefore one-based.
matched_t = all_pts.iloc[pairs.trt_idx.astype(int) - 1]
matched_c = all_pts.iloc[pairs.ctl_idx.astype(int) - 1]
for label, frame in [
    ("source_treated", trt),
    ("source_never_control", ctl),
    ("matched_treated", matched_t),
    ("matched_control", matched_c),
]:
    for q in [0.1, 0.25, 0.5, 0.75, 0.9]:
        add(f"egfr_{label}_q{int(q * 100):02d}", frame.egfr.quantile(q))
    for stratum, count in (
        pd.cut(
            frame.egfr,
            [-float("inf"), 60, 90, float("inf")],
            labels=["G3plus", "G2", "G1"],
            right=False,
        )
        .value_counts()
        .items()
    ):
        add(f"egfr_{label}_{stratum}_n", count)

reuse = pairs.ctl_pid.value_counts()
add("matched_pairs", len(pairs))
add("unique_controls", reuse.size)
add("max_control_reuse", reuse.max())
add("controls_reused_ge5", (reuse >= 5).sum())
add("pairs_from_controls_reused_ge5", reuse[reuse >= 5].sum())

balance = pd.read_csv(results / "psm_balance_pooled_iuh.csv")
for row in balance.sort_values("smd", ascending=False).head(10).itertuples():
    add(f"matched_smd_{row.variable_code}", row.smd, f"raw_smd={row.raw_smd:.6f}")

binary = pd.read_csv(results / "did_binary_pooled_iuh.csv")
for outcome in ["aki1_48h", "aki1_7d", "death_48h_all", "death_7d_all"]:
    for _, row in binary[binary.outcome == outcome].iterrows():
        add(
            f"{outcome}_{row['method']}_or",
            row["or"],
            f"rd={row['rd']:.6f}; p_or={row['or_p']:.6f}; " f"p_rd={row['rd_p']:.6f}",
        )

out = pd.DataFrame(rows)
out.to_csv(results / "iuh_balance_probe.csv", index=False)
print(out.to_string(index=False))
