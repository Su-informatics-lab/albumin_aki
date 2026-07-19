# Albumin → CSA-AKI

ICU-period IV albumin infusion and cardiac surgery-associated acute kidney
injury: effect modification by peri-admission serum albumin level.

Risk-set PSM + DiD in MIMIC-IV v3.1 and eICU-CRD v2.0.

Architecture adapted from [mg_aki](https://github.com/Su-informatics-lab/mg_aki).

## Pipeline

```bash
python 01_etl.py        # cohort construction
Rscript 02_psm.R mimic  # risk-set PSM + DiD
Rscript 02_psm.R eicu
Rscript 03_hte.R mimic   # albumin-strata HTE
Rscript 03_hte.R eicu
python 04_figures.py     # publication figures
```

The deferred ICU-admission 24-hour landmark sensitivity is isolated in
`02b_landmark_sensitivity.R`; it is not part of the main experiment.

## Data

Requires credentialed PhysioNet access:
- [MIMIC-IV v3.1](https://physionet.org/content/mimiciv/3.1/)
- [eICU-CRD v2.0](https://physionet.org/content/eicu-crd/2.0/)

Raw data read from `~/mg_aki/` on IU Tempest HPC (shared with mg_aki project).
