# IUH External Validation Addendum

- **Addendum version:** 1.0
- **Freeze date:** 2026-07-19
- **Status:** **FROZEN BEFORE IUH ETL/OUTCOME RUN**
- **Parent design:** `STUDY_DESIGN.md` v3.3 (unchanged)
- **Role:** supplement-level external validation on IUH Epic 2019-2025

## Cohort and exposure

Construct the cohort from raw `Procedure.parquet` and
`derived/icustay_hourhrbp.parquet`, using the reviewed 39-label open
cardiac-surgery allowlist from `mg/iuh/01_etl.py`. Never use the derived
cardiac-surgery convenience parquet. The effective postoperative ICU start is
`max(unitin, SurgicalStopDTS)`; retain the first postoperative ICU stay per
patient.

Accepted albumin is a positive-volume IUH `IO.parquet` row with
`Event == "MED INTAKE"` and `IO` containing `albumin`, occurring from effective
postoperative ICU start through ICU discharge. This is the administered-intake
source used by the magnesium IUH pipeline. The pre-run audit found 2,028
cardiac-surgery ICU patients with any postoperative albumin row in IO, versus
1,993 in Med and 294 in AnesFluid; Med is not substituted for confirmed intake,
and intraoperative AnesFluid is not the study exposure.

## Frozen causal engine

Use the parent v3.3 risk-set yet-untreated estimator without outcome-informed
changes: T0 is first accepted albumin; controls must remain untreated through
the 24-hour grace period; MICE PMM m=20, seed 2026; logistic PS; 1:1 nearest
neighbor with replacement; 0.2-SD caliper; HC1; DR only for post-match absolute
SMD >0.10. Run pooled and eGFR-stratified analyses, then the formal treatment by
eGFR interaction. Report OR and RD. The primary IUH PS set is the same
MIMIC v3.3 S2-plus-aortic set (23 covariates), with site-native measurement of
vasopressor, MAP, and ventilation status.

The two creatinine references, maximum-at-tied-time rule, strict-pre-T0
baseline labs, missing-post-creatinine non-event coding, KDIGO outcomes,
fixed-window mortality falsification, and sparse-stratum guard rails are
identical to the parent design.

## eGFR dependency and sensitivity

The primary modifier remains race-free CKD-EPI 2021 eGFR calculated from the
frozen pair-time baseline creatinine, age, and sex. This preserves the same
definition across MIMIC, eICU, and IUH. It is explicitly **not independent of
baseline creatinine**: eGFR and baseline creatinine are two parameterizations
of renal reserve, and a joint eGFR/creatinine interaction model cannot by itself
identify separate biological axes.

IUH uniquely supplies lab-reported race-free CKD-EPI eGFR. Before outcomes,
pair the nearest reported eGFR within six hours of the creatinine used to
calculate eGFR; parse `>90` as the G1 lower bound. Report correlation, median
difference, and G1/G2/G3+ classification agreement. As a prespecified
structural sensitivity, repeat within-stratum matching using reported eGFR
among patients with an aligned value, removing computed eGFR and CKD history
from that stratum's PS. This sensitivity evaluates modifier
measurement/classification; it cannot replace the cross-database computed-eGFR
primary definition.

## Gate

Patient-level files and matched pairs remain on Quartz. Commit only reviewed
aggregate CONSORT, concordance, balance, match-rate, outcome, interaction, and
missingness tables. Stop on a stratum match rate below 90%, surprising counts,
or a materially discordant computed-versus-reported eGFR classification pattern
before interpreting outcomes.
