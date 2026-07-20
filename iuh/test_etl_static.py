#!/usr/bin/env python3
"""Small deterministic fixtures for IUH eGFR and creatinine tie behavior."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pandas as pd

path = Path(__file__).with_name("01_etl.py")
spec = importlib.util.spec_from_file_location("iuh_etl", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

tie = pd.DataFrame(
    {
        "offset_h": [1.0, 1.0, 2.0, 2.0],
        "value": [0.8, 1.1, 1.0, 1.4],
    }
)
early = module.max_at_time(tie, earliest=True)
late = module.max_at_time(tie, earliest=False)
assert early is not None and early.offset_h == 1.0 and early.value == 1.1
assert late is not None and late.offset_h == 2.0 and late.value == 1.4

# CKD-EPI 2021 reference calculation, male age 60 with SCr 1.0.
assert abs(module.compute_egfr(1.0, 60, 0) - 86.16) < 0.1
assert pd.isna(module.compute_egfr(float("nan"), 60, 0))
print("PASS: IUH maximum-at-tie creatinine and CKD-EPI 2021 fixtures")
