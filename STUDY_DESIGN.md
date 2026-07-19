# Albumin and Cardiac-Surgery AKI: Frozen Main-Experiment Design

- **Design version:** 3.0
- **Freeze date:** 2026-07-18
- **Status:** **FROZEN BEFORE OUTCOME ANALYSIS**
- **Canonical estimator:** `02_psm.R`
- **Databases:** MIMIC-IV v3.1 and eICU-CRD v2.0, analyzed separately

Any change to this document after the freeze requires a new version, a written
rationale in `JOURNAL.md`, and supervisor approval before rerunning outcomes.
The 24-hour ICU-admission landmark script, `02b_landmark_sensitivity.R`, is
deferred and is not part of the main experiment.

## 1. Question and estimand

Among adult first cardiac-surgery ICU stays without ESKD and with evaluable
creatinine, what is the effect of initiating accepted IV albumin at a treated
patient's first administration time, compared with remaining untreated at that
same time?

The target is a sequential risk-set, yet-untreated estimand. For each treated
patient, `T0` is the first accepted IV albumin administration after ICU
admission. Eligible controls have received no accepted IV albumin at that T0;
patients treated later may serve as controls before their own treatment.
Never-treated-only controls are not the primary comparison.

## 2. Time zero and the two creatinine references

Two references have distinct, non-interchangeable roles.

1. `cr_ref_early` is the earliest qualifying ICU creatinine. If no qualifying
   ICU creatinine exists on or before a treated patient's own T0, use the
   prespecified hospital-admission-window fallback. It screens prevalent AKI
   before each risk-set T0.
2. `baseline_cr` is the last qualifying creatinine strictly before the relevant
   T0. For treated patients this is last pre-albumin creatinine; the
   hospital-admission-window fallback is used only when no ICU value exists.
   At pair analysis, controls are re-anchored strictly before the treated
   patient's T0. This reference defines eGFR, change from baseline, and KDIGO
   outcomes.

For both references in both databases, time selection precedes value selection:
when multiple qualifying creatinines share the selected timestamp, use the
maximum creatinine at that timestamp. This deterministic conservative rule is
also used for admission-window fallback ties. The approved eICU count
sensitivity is 16,780 eligible controls under a minimum-at-tie rule versus
16,778 under the frozen maximum-at-tie rule.

At each candidate T0, exclude treated and control candidates with creatinine
rise after `cr_ref_early` and on or before T0 meeting either SCr KDIGO screen:
an absolute rise of at least 0.3 mg/dL or a ratio of at least 1.5. The own-T0
treated prevalence count emitted by ETL is descriptive; pair-time eligibility
is enforced symmetrically during risk-set construction.

## 3. Exposure and treatment-trigger category

Exposure is the first accepted IV albumin administration as defined in
`01_etl.py`. The serum albumin treatment-trigger category is built using only
measurements strictly before the relevant T0:

- `low`: serum albumin <3.5 g/dL;
- `normal`: serum albumin >=3.5 g/dL;
- `missing`: no qualifying strict-pre-index measurement.

`alb_cat` is a categorical propensity-score covariate. No static peri-admission
albumin category may substitute for the strict-pre-index category.

## 4. Propensity score and matching

The pooled model mirrors the magnesium study's primary covariate set, with
hemoglobin and `alb_cat` added:

- age, sex, BMI;
- CABG, valve, and combined-surgery indicators;
- heart failure, hypertension, diabetes, CKD, COPD, peripheral vascular
  disease, stroke, and liver disease;
- eGFR;
- last strict-pre-index calcium, lactate, lactate-missing indicator, heart
  rate, and hemoglobin;
- strict-pre-index `alb_cat`.

Potassium, magnesium, Yan-specific extended covariates, and post-index
variables are excluded from the primary PS. Calcium remains included, matching
the magnesium primary specification. Control covariates are not re-extracted at
the treated patient's T0 beyond the magnesium pipeline behavior.

For the eGFR-stratified analysis, form strata from `baseline_cr`:

- G1: eGFR >=90 mL/min/1.73 m2;
- G2: eGFR 60-89;
- G3+: eGFR <60.

Match within each stratum and remove eGFR and CKD from that stratum's PS.
The pooled analysis retains eGFR and CKD in the PS.

For every database and analysis:

- logistic propensity score;
- MICE predictive mean matching, `m=20`, with propensity scores averaged across
  imputations;
- one match on the averaged propensity score;
- 1:1 nearest neighbor with replacement;
- caliper 0.2 standard deviations of the averaged propensity score;
- seed 2026;
- HC1 robust standard errors;
- doubly robust outcome adjustment only for covariates with post-match
  absolute SMD >0.10.

The guard rail is a treated match rate of approximately 90% or greater,
including within each reported eGFR stratum. A collapse or other surprising
count triggers a probe and stop, not a flexible or outcome-informed PS.

## 5. Outcomes

Missing post-T0 creatinine is coded as no SCr event, not as missing outcome.
The matched-arm frequency of having no post-T0 creatinine is nevertheless
reported as a missingness diagnostic.

Primary SCr-only KDIGO outcomes are binary:

- stage >=1, >=2, and >=3 by 48 hours after T0;
- stage >=1, >=2, and >=3 by 7 days after T0.

SCr staging uses the pair-time `baseline_cr` and the maximum qualifying
post-T0 creatinine through each horizon. The secondary renal outcome is KDIGO
stage >=2 or new RRT through the corresponding horizon, with the prespecified
7-day estimate required in the main report.

Hospital mortality is the falsification outcome and is reported, not promoted
as efficacy evidence.

## 6. Prespecified analyses and reporting

The main experiment contains only:

1. pooled risk-set matching in MIMIC;
2. eGFR-stratified risk-set matching in MIMIC;
3. pooled risk-set matching in eICU;
4. eGFR-stratified risk-set matching in eICU;
5. formal treatment-by-eGFR interaction and prespecified subgroup estimates in
   each database.

Report match rates, maximum absolute SMD and every SMD >0.10, pooled and
stratum-specific outcome ORs with 95% CIs, formal interaction P values,
mortality falsification, and arm-level post-T0 creatinine missingness.
Report all prespecified horizons and stages, including discordant or null
patterns. No result-driven estimator changes or selective emphasis are allowed.

Landmark, alternative lab-timing specifications, flexible PS models, LLM
endpoints, PS-2, and IUH validation are deferred.
