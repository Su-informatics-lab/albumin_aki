# Albumin and Cardiac-Surgery AKI: Frozen Main-Experiment Design

- **Design version:** 3.3
- **Freeze date:** 2026-07-19
- **Status:** **FROZEN BEFORE THE M=20 MAIN EXPERIMENT**
- **Canonical estimator:** `02_psm.R`
- **Databases:** MIMIC-IV v3.1 and eICU-CRD v2.0, analyzed separately

Any change to this document after the freeze requires a new version, a written
rationale in `JOURNAL.md`, and supervisor approval before rerunning outcomes.
The 24-hour ICU-admission landmark script, `02b_landmark_sensitivity.R`, is
deferred and is not part of the main experiment.

Version 3.1 was a documented falsification amendment authorized after the first
MIMIC pooled run exposed an alive-at-T0 eligibility bug and immortal-time bias
in whole-stay mortality. It does not change the AKI estimand, matching ratio,
replacement rule, MICE, HC1, DR rule, trigger category, or creatinine outcomes.

Version 3.2 froze S2 after the precommitted m=5 MIMIC pooled covariate sweep.
Version 3.3 is the supervisor-authorized amendment recorded in `JOURNAL.md`
Entries 12b, 14, and 16. Before the unified m=20 rerun it adds the pre-T0
`surg_aortic` indicator to the primary adjustment set, preserves the implemented
strict-before-T0 values, standardizes their display labels, and removes eICU's
post-T0-contaminated APACHE day-1 ventilation proxy. MIMIC is primary; eICU is
supplementary because vaso/MAP are unavailable and early mortality
falsification was non-null. S0, S1, and S2-without-aortic are sensitivities;
S3-S5 remain excluded.

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

### Baseline-at-T0 timing convention

Every table and Methods description uses one display convention:
**baseline (at ICU T0)**. For a measured lab or vital this means the most recent
qualifying value **strictly before T0** (`offset_h < index_h`); for an ongoing
organ support it means status at T0. The display convention is label-only and
does not change any covariate value. Same-timestamp measurements are not
admitted with `<=`. The alternative `sens_b` lab-timing specification is
labeled **earliest ICU value**.

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

### Version 3.3 frozen primary adjustment set

The MIMIC primary propensity-score set is **S2 plus `surg_aortic` (23
covariates)**, comprising the magnesium-base set, the prespecified
resuscitation-severity covariates, and the complete surgery-type block:

- age, sex, BMI;
- CABG, valve, combined-surgery, and aortic-surgery indicators;
- heart failure, hypertension, diabetes, COPD, peripheral vascular disease,
  stroke, and liver disease;
- eGFR in the pooled model;
- baseline-at-T0 lactate, lactate-missing indicator, heart rate, hemoglobin, and
  categorical serum-albumin trigger (`alb_cat`);
- baseline-at-T0 vasopressor support, MAP, and ventilation support.

The eICU supplementary set is the magnesium-base set plus `surg_aortic`. It
deliberately drops vasopressor and MAP because their hospital-level missingness
is informative, and drops ventilation because the available APACHE day-1 flag
can post-date T0. This database-specific under-adjustment is prespecified and
must be explicit in every results report; eICU is directional supplementary
evidence, not co-primary validation.

S0 (the magnesium-mirror base set), S1 (S0 plus baseline-at-T0 vasopressor
support in MIMIC), and S2-without-aortic are sensitivity specifications only.
S3-S5 are excluded from primary and sensitivity outcome reporting because the
m=5 sweep showed broad imputation/PS instability; S4 additionally contains
near-path resuscitation variables. No sensitivity result can change the frozen
primary set.

Calcium, potassium, magnesium, extended S3-S5 covariates, continuous albumin,
emergency-admission route, SOFA/APACHE-24h, intraoperative variables, LVEF, and
post-index variables are excluded. Control covariates are not re-extracted at
the treated patient's T0 beyond the magnesium pipeline behavior.

For the eGFR-stratified analysis, form strata from `baseline_cr`:

- G1: eGFR >=90 mL/min/1.73 m2;
- G2: eGFR 60-89;
- G3+: eGFR <60.

Match within each stratum and remove eGFR and any redundant CKD indicator from
that stratum's PS. The pooled analysis retains eGFR; CKD is not part of the
version 3.3 primary set.

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

### Version 3.1 mortality amendment

Every treated and control member must be alive at the relevant T0:
`death_offset_h` is missing or strictly greater than T0. Mortality
falsification is death within 48 hours and within 7 days after T0, aligned to
the AKI windows. For both horizons report three prespecified diagnostics:

1. all matched controls;
2. never-treated controls only;
3. later-treated controls censored at crossover.

Whole-stay hospital mortality is descriptive only and is not the
falsification test. Mortality is always reported as both OR and absolute RD;
the fixed-window RD is the primary falsification read because death is sparse.
Whole-stay ORs carry an explicit immortal-time caveat and cannot overturn a
fixed-window RD interpretation.

### Version 3.1 covariate sweep

Before releasing eGFR-stratified or eICU analyses, MIMIC pooled evaluates the
ordered, cumulative, strictly pre-index registry:

- S0: frozen magnesium-base set;
- S1: S0 plus baseline-at-T0 vasopressor support;
- S2: S1 plus baseline-at-T0 MAP and ventilation support;
- S3: S2 plus baseline-at-T0 platelet, INR, hematocrit, bicarbonate, BUN, and
  sodium;
- S4: S3 plus RBC exposure, cumulative crystalloid, and cumulative urine
  output strictly before first-albumin T0;
- S5: S4 plus aortic and prior cardiac surgery;
- optional S6: S5 plus WBC and chronic loop-diuretic, ACEI/ARB, NSAID, and
  PPI indicators.

Selection is prespecified on improved balance and mortality falsification
moving toward null, never on the AKI estimate. Every binary outcome is reported
as both OR and absolute risk difference with HC1 confidence intervals and P
values. The comparative sweep uses MICE m=5; only the selected and newly frozen
set is rerun at m=20. Calcium, emergency-admission route, continuous albumin,
SOFA/APACHE-24h, intraoperative variables, and LVEF are excluded. The full
sweep is retained as a transparency analysis.

### Version 3.3 adjustment-set decision

The completed m=5 sweep selected S2 before the m=20 run. S2 covers the
resuscitation-severity axis while preserving the authorized compromise between
balance and the fixed-window mortality-RD falsification. Yan's prespecified
refinement adds `surg_aortic`, a pre-T0 time-invariant surgery indicator, to
test whether incomplete surgery-type adjustment explains residual imbalance.
Selection was not based on the AKI estimate. S0, S1, and S2-without-aortic
remain sensitivities; S3-S5 are excluded for the reasons in Section 4.

## 6. Prespecified analyses and reporting

The main experiment contains only:

1. pooled risk-set matching in MIMIC (primary);
2. eGFR-stratified risk-set matching in MIMIC (primary);
3. pooled risk-set matching in eICU (supplementary);
4. eGFR-stratified risk-set matching in eICU (supplementary);
5. formal treatment-by-eGFR interaction and prespecified subgroup estimates in
   each database.

Report match rates, maximum absolute SMD and every SMD >0.10, pooled and
stratum-specific outcome ORs with 95% CIs, formal interaction P values,
mortality falsification, and arm-level post-T0 creatinine missingness.
Report all prespecified horizons and stages, including discordant or null
patterns. No result-driven estimator changes or selective emphasis are allowed.
For MIMIC pooled, report the raw and matched `surg_aortic` SMD and compare
maximum SMD and violation count with the m=20 S2-without-aortic sensitivity.
For eICU, report an under-adjustment diagnostic on available baseline axes and
state explicitly that vaso/MAP are unmeasured and ventilation is omitted.

Landmark, the `sens_b` **earliest ICU value** lab-timing specification, flexible
PS models, LLM endpoints, PS-2, and IUH validation are deferred. IUH Phase 7,
using MIMIC-grade hemodynamics, is the planned external validation.
