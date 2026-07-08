# Albumin -> CSA-AKI Study Design

- **Updated:** 2026-07-08
- **Current analysis:** `02_psm_v2.R` 24h landmark PSM
- **Presentation audience:** Michael Eadon, Meng Lingzhong
- **Status:** MIMIC v2 results available; eICU replication, HTE v2, and LLM endpoints pending

---

## Executive Summary

This analysis asks whether early postoperative IV albumin after cardiac surgery is
associated with later severe CSA-AKI and organ-support complications.

The current v2 design deliberately departs from the original mg_aki-style
patient-specific drug-time risk set. For albumin, treatment timing is not a clean
"give now" decision in the same way magnesium was. Yan's clinical interpretation
is that albumin is often used as a volume strategy rather than to correct a low
albumin lab, and only a minority of treated patients have a serum albumin value
available before infusion. The implemented design therefore anchors all patients
at ICU admission after cardiac surgery (`ICU0`) and compares early albumin use
within the first 24h against no early albumin.

The current MIMIC result is directionally coherent and clinically interpretable:
after 24h landmarking and 1:1 propensity-score matching, early albumin is
associated with higher severe AKI/new RRT, higher bleeding proxies, more prolonged
ventilation/vasopressor support, and a higher F-MPAO composite, while hospital
mortality is not increased.

This aligns with ALBICS at the level of the harm phenotype. ALBICS did not show a
positive primary composite, but its component results pointed toward more bleeding,
resternotomy, and infection with albumin. Our current observational MIMIC analysis
does not replicate CK-MB myocardial injury and cannot yet report the LLM-derived
resternotomy/infection/POAF components, but it does reproduce the broader
bleeding/support signal and identifies a severe AKI signal that ALBICS was
underpowered to resolve.

---

## Current Results Snapshot

Command supplied for the current presentation:

```bash
Rscript 02_psm_v2.R mimic 5
```

### MIMIC cohort and matching

| Quantity | Value |
|---|---:|
| Loaded base cohort | 12,667 patients |
| 24h landmark exclusions | 1,015 (8.0%) |
| Death <=24h | 44 |
| RRT <=24h | 40 |
| Stage >=2 AKI <=24h | 935 |
| Landmark cohort | 11,652 |
| Treated, albumin <=24h | 4,488 |
| Control, no albumin <=24h | 7,164 |
| Matched pairs | 3,738 |

Balance after matching is acceptable for presentation. All reported SMDs are
below 0.10. The only flagged variable above 0.05 is `lactate_missing` (SMD 0.064).

### Primary endpoint

**KDIGO stage 2-3 AKI or new RRT, 24h to 7d**

| Arm | Rate |
|---|---:|
| Early albumin | 1.7% |
| Control | 0.7% |

OR = **2.55** [1.60, 4.06], P = 0.0001.

Interpretation for the meetings: the signal is not a small creatinine drift. It is
concentrated in severe AKI/new RRT after the landmark.

### Continuous creatinine time course

Delta-creatinine DiD estimates from 6h to 48h are small and positive
(approximately +0.007 to +0.013 mg/dL). In v2 this is a mechanistic/supporting
analysis, not the primary result. Because T0 is ICU admission for everyone, the
early time horizons include treated patients before albumin administration and
are expected to dilute any drug-time effect.

### Binary secondary endpoints

| Endpoint | Early albumin | Control | OR [95% CI] | P |
|---|---:|---:|---:|---:|
| Primary AKI 2-3/RRT 7d | 1.7% | 0.7% | 2.55 [1.60, 4.06] | 0.0001 |
| Hospital mortality | 1.8% | 2.0% | 0.90 [0.65, 1.26] | 0.5546 |
| RBC >=4 units / 48h | 4.5% | 2.4% | 1.94 [1.49, 2.52] | <0.0001 |
| Chest tube drainage >1500 mL / 48h | 11.4% | 5.2% | 2.37 [1.99, 2.83] | <0.0001 |
| Mechanical ventilation >48h | 11.1% | 7.1% | 1.64 [1.40, 1.93] | <0.0001 |
| Vasopressor >48h | 17.0% | 8.5% | 2.22 [1.93, 2.57] | <0.0001 |
| F-MPAO | 28.2% | 15.0% | 2.23 [1.98, 2.50] | <0.0001 |

`any_aki_24h_7d` is not used for the current presentation because the severe AKI
endpoint is the prespecified primary endpoint and the current run still reports
`any_aki_24h_7d` as unavailable.

LLM endpoints are pending and should not be presented as results yet:
return to OR, reintubation, pneumonia/VAP, sepsis, sternal wound infection,
cardiac arrest, POAF, stroke, acute heart failure, delirium, and myocardial injury.

---

## Research Question

Among adult cardiac-surgery ICU patients, is early postoperative IV albumin within
the first 24h after ICU admission associated with severe CSA-AKI/new RRT from 24h
to 7d, and does it identify a broader bleeding/support harm phenotype aligned with
ALBICS?

Secondary questions:

1. Does the association persist across MIMIC and eICU?
2. Do bleeding, prolonged ventilation, and prolonged vasopressor support move in
   the same direction as severe AKI?
3. Do renal reserve and baseline albumin modify the association? This is planned
   but not yet v2-final.
4. Do NLP-extracted ALBICS-aligned clinical endpoints confirm the proposed chain:
   bleeding -> return to OR -> infection/support complications?

---

## Database and Pipeline

Raw data are read from the shared Tempest paths under `~/mg_aki/`.

| Step | Script | Current role |
|---|---|---|
| Base cohort, albumin timing, Cr/labs | `01_etl.py` | Creates `did_all_*`, `did_cr_all_*`, `did_labs_all_*` |
| Event streams and richer covariates | `01b_covariates.py` | Creates vaso, vent, MAP, blood, drainage, extended labs, surgery flags |
| Structured infection endpoints | `01c_endpoints.py` | MIMIC ICD/culture infection support |
| Primary v2 analysis | `02_psm_v2.R` | 24h landmark PSM and binary/DiD endpoints |
| HTE | `03_hte.R` | Still older pair-preserving risk-set version; needs v2 update |
| LLM endpoints | `llm_extract/*` | In progress; not in current results |

The base `did_all_*` files still contain albumin timing from `01_etl.py`. The v2
analysis reclassifies exposure as `treated_24h = first albumin offset <= 24h`.
Patients who receive albumin after 24h are therefore controls for the early
albumin strategy analysis, subject to the available base-cohort eligibility.

---

## Design

### Time zero

**T0 = ICU admission after cardiac surgery (`ICU0`) for every patient.**

This is the key departure from mg_aki. The older risk-set design used a
patient-specific drug administration time. The current albumin design uses a
fixed clinical landmark:

```text
Surgery/admission -> ICU0 = T0 -> 0-24h exposure window -> 24h landmark -> 7d outcome window
```

### Exposure

- **Treated:** any IV albumin administration from ICU0 to ICU0+24h.
- **Control:** no IV albumin administration from ICU0 to ICU0+24h.

Albumin after 24h is interpreted as late/rescue crossover and is not the primary
exposure. This can dilute effect estimates, but it better represents the clinical
decision being evaluated: early postoperative albumin strategy vs no early
albumin strategy.

MIMIC albumin products are identified from inputevents:

- Albumin 25%: itemid 220862
- Albumin 5%: itemid 220864

### Eligibility

Implemented base cohort:

- Adult cardiac-surgery ICU patients.
- First ICU stay per patient.
- MIMIC: cardiac surgery by procedure codes and/or CVICU logic in `01_etl.py`.
- eICU: cardiac-surgery admission diagnosis/unit logic in `01_etl.py`.
- Evaluable creatinine data from `01_etl.py`.
- Baseline creatinine <4.0 mg/dL.
- No pre-surgery ESKD/dialysis evidence.

### 24h landmark exclusions

Applied in `02_psm_v2.R`:

- Death <=24h.
- RRT <=24h.
- KDIGO stage >=2 AKI <=24h.

Rationale: the primary endpoint is incident severe AKI/new RRT after the early
albumin decision window. Patients who already have severe AKI/RRT/death by the
landmark are not at risk for the primary incident endpoint.

---

## Propensity Score Model

The current shared PS model contains 29 variables.

| Domain | Variables |
|---|---|
| Demographics | age, sex, BMI |
| Surgery | CABG, valve, combined, aortic |
| Comorbidities | heart failure, hypertension, diabetes, CKD, COPD, PVD, stroke, liver disease |
| Renal reserve | eGFR |
| Early labs/vitals, 0-6h | hemoglobin, calcium, lactate, lactate missing, heart rate |
| ICU state | mechanical ventilation at T0 |
| Extended labs, 0-6h | platelet, INR, BUN, bicarbonate, sodium, WBC, hematocrit |

MIMIC m=5 run missingness highlights:

- BMI: 12.2% missing.
- Hemoglobin: 7.9% missing.
- Calcium: 78.2% missing.
- Lactate: 19.6% missing plus missingness indicator.
- Heart rate: 7.1% missing.
- Platelet/INR/BUN/bicarbonate/sodium/WBC/Hct: approximately 7-17% missing.

### Imputation and matching

Current implementation in `02_psm_v2.R`:

1. MICE with PMM, default target m=20; current presentation run used m=5.
2. Fit a logistic PS model in each imputed dataset.
3. Average predicted PS across imputations.
4. Match once on the averaged PS.
5. 1:1 nearest-neighbor matching **without replacement**.
6. Caliper = 0.2 SD of the averaged PS.
7. Seed = 2026.

This is the "across" strategy for imputed propensity scores. It replaced the
unstable earlier attempt to require the same matched pair to recur across
multiple imputations.

### What is intentionally not in the PS

- Post-24h variables: downstream of the exposure window.
- LLM complications: outcomes, not baseline covariates.
- Peri-admission albumin lab: treatment trigger and high missingness; planned for
  HTE/subset analysis, not primary PS.
- Intraoperative variables: not consistently available.

---

## Outcomes

### Primary

**KDIGO stage 2-3 AKI or new RRT from ICU0+24h to ICU0+7d.**

Operationalization in `02_psm_v2.R`:

- New RRT if `rrt_offset_h > 24` and `<=168`.
- Stage 2-3 AKI if post-landmark creatinine ratio is >=2.0 relative to
  `first_cr`.
- Outcome window: >24h to <=168h.

### Continuous supporting outcome

Delta creatinine time course at 6, 12, 18, 24, 30, 36, 42, and 48h from ICU0.
For each horizon, the script selects the closest creatinine within +/-12h and
reports:

```text
DiD = mean(deltaCr_treated) - mean(deltaCr_control)
```

This is mechanistic support only in v2 because T0 is ICU0 rather than the exact
drug time.

### Binary secondary endpoints

Current structured endpoints in `02_psm_v2.R`:

- Hospital mortality.
- RBC transfusion >=4 units / 48h, approximated as RBC volume >=1200 mL.
- Chest tube drainage >1500 mL / 48h.
- Mechanical ventilation >48h.
- Vasopressor support >48h.
- F-MPAO composite.

F-MPAO currently includes:

- Death.
- Severe AKI/new RRT.
- Major bleeding proxy: RBC >=4 units or chest drainage >1500 mL.
- Mechanical ventilation >48h.
- Vasopressor >48h.
- Return to OR when LLM extraction is available; currently absent.

### LLM endpoints

The LLM extraction pipeline is in progress and should be treated as pending for
the meetings. Once complete, `02_psm_v2.R` can report:

- Return to OR/resternotomy.
- Reintubation.
- Pneumonia/VAP.
- Sepsis.
- Sternal wound infection.
- Cardiac arrest.
- POAF.
- Stroke.
- Acute heart failure.
- Delirium.
- Myocardial injury.

---

## ALBICS Alignment

ALBICS was a randomized trial of 4% albumin vs Ringer acetate in on-pump cardiac
surgery. The primary composite was not positive, but component directions are
clinically useful for framing our observational results.

| ALBICS domain | ALBICS direction | Current MIMIC v2 status |
|---|---|---|
| AKI | No significant difference, low event rate | Severe AKI/RRT increased: OR 2.55 |
| Bleeding | Albumin harm | RBC >=4u OR 1.94; drainage >1500 mL OR 2.37 |
| Resternotomy/return to OR | Albumin harm | Pending LLM |
| Infection | Albumin harm | Pending ICD/culture/LLM integration |
| Arrhythmia/POAF | No significant signal | Pending LLM |
| Stroke | No significant signal | Pending LLM/ICD exploratory |
| Acute heart failure | No significant signal | Pending/coarse |
| Myocardial injury | Albumin protective by CK-MB | Not directly replicable in MIMIC |
| Death | No significant signal | No increase: OR 0.90, P=0.55 |

Presentation framing:

1. We should not claim we have reproduced an RCT result for AKI.
2. We can say the harm phenotype is ALBICS-consistent: bleeding/support burden
   moves strongly in the same direction.
3. The severe AKI signal is larger in MIMIC because the observational cohort is
   much larger and the endpoint is specifically post-landmark severe AKI/new RRT.

---

## Presentation Structure

### Slide 1: Design

Core message:

```text
T0 = ICU admission after cardiac surgery.
Exposure = any albumin during ICU0 -> ICU0+24h.
Landmark at 24h excludes early death, RRT, and stage >=2 AKI.
Primary endpoint = new severe AKI/RRT from 24h -> 7d.
```

What to emphasize:

- This is not the mg_aki risk-set design.
- The fixed ICU0 landmark is intentional because albumin timing reflects a
  postoperative volume strategy.
- Late albumin is crossover/rescue and belongs in the no-early-albumin strategy
  for the primary contrast.

### Slide 2: Propensity score model

Core message:

```text
29-variable shared model:
demographics + surgery type + comorbidities + eGFR +
early 0-6h labs/vitals + ventilation + extended labs.
MICE -> averaged PS -> one 1:1 nearest-neighbor match.
```

What to emphasize:

- 3,738 matched pairs from 4,488 treated.
- Balance is good; all SMD <0.10.
- The severe AKI signal is not explained by obvious baseline imbalance in the
  current PS variables.

### Slide 3: Main results

Use the MIMIC m=5 table above.

Core message:

```text
Early albumin is associated with:
severe AKI/RRT OR 2.55,
major bleeding proxies OR ~1.9-2.4,
prolonged support OR ~1.6-2.2,
F-MPAO OR 2.23,
without increased hospital mortality.
```

### Slide 4: ALBICS context and next steps

Core message:

```text
ALBICS gives randomized context for the phenotype:
albumin did not improve the composite and moved bleeding/resternotomy/infection
in the harm direction. Our MIMIC v2 analysis sees the same bleeding/support
direction and adds a severe AKI/RRT signal.
```

Next steps:

- Run final MIMIC with m=20 if time allows.
- Complete eICU v2 replication.
- Finish LLM endpoint extraction and rerun MIMIC once return-to-OR, infection,
  POAF, delirium, stroke, and related endpoints are available.
- Update `03_hte.R` to consume v2 matched pairs before presenting HTE.

---

## Current Limitations to State Explicitly

1. This is an observational matched analysis, not a randomized comparison.
2. MIMIC-only results are available for the current deck; eICU replication is
   still needed.
3. LLM endpoints are not yet integrated into the result table.
4. `03_hte.R` is not yet updated to the v2 matched-pair object, so HTE should not
   be presented as final.
5. Current `02_psm_v2.R` inference is standard logistic regression on the matched
   sample, not paired conditional logistic regression or cluster-robust inference.

---

## Run Contract

Current presentation run:

```bash
cd ~/albumin_aki
Rscript 02_psm_v2.R mimic 5
```

Target final run:

```bash
cd ~/albumin_aki
Rscript 02_psm_v2.R mimic 20
Rscript 02_psm_v2.R eicu 20
python -m llm_extract.extract --workers 8 --delay 0   # if LLM extraction is not complete
python -m llm_extract.validate
Rscript 02_psm_v2.R mimic 20
```

The final MIMIC rerun after LLM completion is needed because LLM endpoints are
read from `~/albumin_aki/results/llm_endpoints_mimic.csv` when available.
