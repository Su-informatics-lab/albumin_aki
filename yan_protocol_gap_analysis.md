# Albumin-AKI: Yan Protocol vs Implementation — Gap Analysis

**Date**: 2026-07-04
**Protocol**: 心脏术后早期白蛋白治疗研究方案_PSM变量_液体定义版
**Databases**: MIMIC-IV v3.1 (primary, full) / eICU-CRD v2.0 (external replication, light)

---

## 1. Study Architecture (§1-3, §12)

| Yan Protocol | Our Implementation | Status |
|---|---|---|
| **T0** = first postop serum Alb lab before any albumin infusion | **T0 = ICU0** (ICU admission). Probe showed only 7.9% (MIMIC) / 32% (eICU) of treated had a qualifying Alb lab before infusion — operationally infeasible as anchor. Yan approved the change: "术后输白蛋白的首要原因不是为了纠正低白蛋白". | ✅ Changed, Yan approved |
| T0 window candidates: 0-6h / 0-12h / 0-24h | T0 fixed at ICU0. Exposure window = (0, ICU0+24h]. Sensitivity: restrict to infusion ≤6h / ≤12h subsets. | ✅ Simplified |
| **Exposure** = any albumin infusion between T0 and ICU0+24h | First IV albumin infusion ∈ (0, ICU0+24h]. Infusion >24h = late/rescue, excluded from primary. MIMIC 85.4% / eICU 73.3% eligible. | ✅ |
| **Landmark** = ICU0+24h; AKI counted from 24h onward | ICU0+24h landmark. Exclude: death ≤24h, RRT ≤24h, stage≥2 AKI ≤24h. Cost: <1% per filter. | Deferred sensitivity in `02b_landmark_sensitivity.R` |
| **Primary estimand**: early albumin strategy (ITT-like at 24h) | Risk-set PSM + DiD (retained as mechanistic support) + **landmark binary** (new primary per Yan). | ✅ To implement |

---

## 2. PS Variables — §6.1 Surgery-Related

| Yan Variable | Yan Priority | MIMIC | eICU | Our Definition | Status |
|---|---|---|---|---|---|
| Surgery type (CABG/valve/combined/aortic/other) | 必须 | ICD-9/10 procedure codes | apacheAdmissionDx text | `surg_cabg`, `surg_valve`, `surg_combined` (from 01_etl); `surg_aortic` (from 01b, ICD W+X codes) | ✅ In PS-1 |
| Aortic surgery marker | 强烈建议 | ICD-9 3834/3844/3845 + ICD-10 02R/Q/U/V/W for W+X (descending + ascending/arch). **7.3%** | apacheAdmissionDx regex (valve-excluded). **2.9%** | `surg_aortic` in surg_{db}.csv | ✅ In PS-1 |
| Combined/complex surgery | 强烈建议 | Already `surg_combined` | Already `surg_combined` | CABG+valve | ✅ In PS-1 (via surg_combined) |
| Emergency/elective | 如可得必须 | `admission_type` ∈ {EW EMER., DIRECT EMER., URGENT} → 47.7% | `hospitaladmitsource` contains "emergency" → 30.4% | `adm_emergency` — **但这是入院途径,不是手术紧急度** | ⚠️ 可用但含义偏移,需声明 |
| Redo sternotomy | 如可得强烈建议 | ICD dx codes for prior CABG/valve prosthesis status (V4581/V433/Z951-Z954) → **4.0%** | Not available | `prior_cardiac_surgery` — proxy via diagnosis codes, not a direct "redo" flag | ⚠️ Proxy only (MIMIC); absent in eICU |
| CPB use (on/off pump) | 如可得建议 | **Not available** — no intraoperative data in MIMIC | **Not available** | — | ❌ 不可得 |
| CPB time (min) | 如可得强烈建议 | **Not available** | **Not available** | — | ❌ 不可得 |
| Aortic cross-clamp time | 如可得强烈建议 | **Not available** | **Not available** | — | ❌ 不可得 |
| DHCA / circulatory arrest | 如可得建议 | **Not available** | **Not available** | — | ❌ 不可得 |
| Surgery duration | 如可得建议 | **Not available** | **Not available** | — | ❌ 不可得 |
| Intraoperative transfusion | 如可得强烈建议 | **Not available** — inputevents starts at ICU admission | **Not available** | — | ❌ 不可得 |
| Intraoperative fluid input | 如可得建议 | **Not available** | **Not available** | — | ❌ 不可得 |
| Intraoperative urine output | 如可得建议 | **Not available** | **Not available** | — | ❌ 不可得 |

**术中变量总结**: 两库均从 ICU 入科开始记录,所有 intraoperative 变量不可得。Limitation 中说明,并以 postoperative surrogates (initial lactate, initial Hgb, vasopressor need) 部分替代。

---

## 3. PS Variables — §6.2 Preoperative / Baseline

| Yan Variable | Yan Priority | MIMIC Coverage | eICU Coverage | Our Definition | Status |
|---|---|---|---|---|---|
| Age | 必须 | 100% | 100% (>89 capped) | `age` | ✅ PS-1 |
| Sex | 必须 | 100% | 100% | `is_female` | ✅ PS-1 |
| BMI / weight | 必须 | ~85% (chartevents) | ~70% (patient table) | `bmi` (MICE imputed) | ✅ PS-1 |
| Baseline creatinine | 必须 | Last Cr before T0; hospital-admission fallback | First ICU Cr; hospital-admission fallback | `first_cr` → `egfr` via CKD-EPI | ✅ PS-1 |
| Baseline eGFR | 必须 | Derived from above | Derived from above | `egfr` | ✅ PS-1 |
| **Preop albumin** | 必须 | **~26% of treated have any postop Alb lab; true preop unavailable** | ~61% have peri-admission Alb lab | `peri_admission_alb` (−48h to +6h window) — **excluded from PS-1** per mg_aki precedent (treatment trigger). Used as HTE stratifier. | ⚠️ Excluded from PS; HTE only |
| Preop Hb/Hct | 强烈建议 | Hb 100%, Hct 100% | Hb ~99%, Hct ~99% | `hemoglobin` (existing PS) + `hct` (new ext labs) | ✅ PS-1 |
| Preop platelet | 如可得强烈建议 | 100% | 99.2% | `platelet` (new ext labs) | ✅ PS-1 |
| Preop INR/PT | 如可得强烈建议 | 99.2% | 73.3% | `inr` (new ext labs) | ✅ PS-1 |
| Preop aPTT | 如可得强烈建议 | 99.1% | 61.9% | `ptt` (new ext labs) | ⚠️ PS-1 (MIMIC); eICU 需 MICE |
| Bilirubin | 建议 | 65.3% | 66.3% | `bilirubin` (new ext labs) | ⚠️ Table 1 描述; PS 需 MICE |
| ALT/AST | 建议 | ~66% | Not reliably extractable | `alt`, `ast` (MIMIC only) | ⚠️ Table 1 (MIMIC); eICU absent |
| BUN | 建议 | 100% | 100% | `bun` (new ext labs) | ✅ PS-1 |
| Bicarbonate/pH | 建议 | 100% | 99.4% | `bicarbonate` (new ext labs) | ✅ PS-1 |
| Chloride | 建议 | 100% | Not extracted (add if needed) | — | 🔜 Can add |
| Sodium | 建议 | 100% | 100% | `sodium` (new ext labs) | ✅ PS-1 |
| Potassium | 建议 | 100% | 100% | Already in did_labs_all. **Excluded from primary PS** (treatment trigger precedent from mg_aki) | ⚠️ Sensitivity only |
| WBC / infection | 可选 | 100% | 99.2% | `wbc` (new ext labs) | ✅ Table 1; consider PS-1 |
| HF / LVEF | 强烈建议 | HF by ICD | HF by pastHistory | `heart_failure` (binary ICD/text). **LVEF not structured** (MIMIC-IV-ECHO downloading, not yet integrated) | ⚠️ HF yes; LVEF future work |
| HTN, DM, CKD, COPD, PVD, stroke, liver | 必须 | ICD-9/10 prefix codes | pastHistory text patterns | 8 binary comorbidity flags | ✅ PS-1 |
| Preop ACEI/ARB | 如可得建议 | prescriptions table | admissionDrug table | `acei_arb_chronic` | ✅ PS-1 |
| Preop diuretic | 如可得建议 | prescriptions table | admissionDrug table | `loop_diuretic_chronic` | ✅ PS-1 |
| Preop anticoag/antiplatelet | 如可得建议 | **Not extracted** | **Not extracted** | — | 🔜 Can add from prescriptions/admissionDrug |

**"Preop" caveat**: 两库均无真正术前值。所有 "preop" labs 实际 = 首次 ICU (术后) 值,在 Discussion 中需透明声明。

---

## 4. PS Variables — §6.3 T0-Time / Decision-Specific

| Yan Variable | Yan Priority | MIMIC | eICU | Our Definition | Status |
|---|---|---|---|---|---|
| Postop initial Alb at T0 | 必须 | ~26% of treated | ~61% | `peri_admission_alb` — **excluded from PS** (treatment trigger); used as HTE stratifier/四象限 | ⚠️ HTE only |
| Time from ICU0 to T0 | 必须 | T0=ICU0, so this is 0 by definition | Same | Collapsed by design change | ✅ N/A (T0=ICU0) |
| **Vasopressor use / NE-eq / VIS at T0** | 必须 | `strm_vaso_mimic.csv`, 64.8% coverage, 7 drug classes with rate+unit → **can compute binary + count + VIS** | 23.5% coverage, hospital-confounded → **excluded from eICU PS** | MIMIC: binary `vaso_at_t0` in PS-1; VIS/NE-eq in PS-2. eICU: not in PS. | ✅ MIMIC PS-1/2; ❌ eICU |
| **Lactate before T0** | 强烈建议 | Already in did_labs_all, ~85% | Already in did_labs_all, ~70% | `lactate` + `lactate_missing` indicator | ✅ PS-1 |
| **Heart rate / MAP before T0** | 建议 | HR: chartevents 100%; MAP: 99.9% | HR: vitalPeriodic 100%; MAP: **53.3% (hospital ceiling)** → excluded | MIMIC: `heartrate` (PS-1) + `map_before_t0` (PS-2). eICU: HR only. | ✅ MIMIC; ⚠️ eICU partial |
| **Mechanical ventilation at T0** | 强烈建议 | procedureevents segments 71.8% ∪ chartevents settings 82.8% → **~87-90%** | apachePredVar `vent_day1` flag, 86.9% | MIMIC: `vent_at_t0` (segment covers T0 OR ventset charted near T0). eICU: `vent_day1` binary. | ✅ PS-1 (both DBs) |
| Crystalloid before T0 | PS-2 强烈建议 | `strm_fluid_mimic.csv`, 85.3% | **Not extractable** (free-text celllabel, no dictionary built) | MIMIC PS-2 only: `crystalloid_before_t0_ml` | ✅ MIMIC PS-2 only |
| Net fluid balance before T0 | PS-2 强烈建议 | fluid intake + urine output computable | **Not reliably computable** | MIMIC PS-2 only: `fluid_balance_before_t0` = crystalloid+colloid+albumin − urine | ✅ MIMIC PS-2 only |
| Urine output before T0 | PS-2 强烈建议 | `strm_output_mimic.csv` (urine), 99.1% | 80.9% but cumulative/noisy | MIMIC PS-2 only: `urine_before_t0_ml` | ✅ MIMIC PS-2 only |
| RBC transfusion before T0 | PS-2 强烈建议 | `strm_blood_mimic.csv`, 25.6% with volume | ~11% free-text | MIMIC PS-2 only: `rbc_before_t0` (binary/units) | ✅ MIMIC PS-2 only |
| Diuretic before T0 | PS-2 可选 | `strm_diuretic_mimic.csv`, 63.9% | **Not extracted** | MIMIC PS-2 only: `diuretic_before_t0` binary | ✅ MIMIC PS-2 only |
| Non-albumin colloid before T0 | PS-2 可选或排除 | **0.2%** — effectively unused in US practice | **~0%** | **Dropped from design** — no data to adjust | ❌ 不可得 (clinical reality: US abandoned HES) |

---

## 5. PS Model Summary

| Model | Databases | Variables |
|---|---|---|
| **PS-1 (primary)** | MIMIC + eICU | age, sex, BMI, surg_cabg, surg_valve, surg_combined, surg_aortic, HF, HTN, DM, CKD, COPD, PVD, stroke, liver_disease, eGFR, hemoglobin, calcium, lactate, lactate_missing, heartrate, **vent_at_t0**, **platelet, INR, BUN, bicarbonate, sodium** (~27 vars) |
| **PS-2 (MIMIC sensitivity)** | MIMIC only | PS-1 + **vaso_at_t0, MAP_before_t0, crystalloid_before_t0, urine_before_t0, rbc_before_t0, diuretic_before_t0** (~33 vars) |

---

## 6. Primary and Secondary Endpoints — §7

| Yan Endpoint | Time Window | MIMIC | eICU | Status |
|---|---|---|---|---|
| **Primary: KDIGO stage 2-3 AKI or new RRT** | ICU0+24h → day 7 | Cr from did_cr_all + RRT detection | Same | ✅ To implement (landmark binary) |
| Early AKI signal (any AKI or stage 2-3) | ICU0+24h → 48h | Same infrastructure | Same | ✅ |
| Extended AKI signal | ICU0+24h → 72h | Same infrastructure | Same | ✅ |
| **MAKE30** (death / new RRT / persistent renal dysfunction) | 30 days | Death: hospital mortality. RRT: detected. **Persistent Cr: coverage unknown — need probe for day-30 / discharge Cr** | Same caveats | ⚠️ Death+RRT yes; persistent renal needs probe |
| **Bleeding: RBC ≥4U** | ICU0 → 48h | `strm_blood_mimic.csv`, PRBC with volume/units, 25.6% ever received → can threshold | Free-text pRBC, ~11% → **crude binary only** | ✅ MIMIC; ⚠️ eICU crude |
| **Bleeding: chest tube drainage >1500mL** | ICU0 → 48h | `strm_output_mimic.csv` (chesttube), **75.7%** — can sum drainage in window | eICU "Chest Tube" labels ~11% → sparse | ✅ MIMIC; ❌ eICU too sparse |
| **Bleeding: reoperation/resternotomy** | ICU0 → 48h | **MIMIC-Note NLP "Return to OR"** (base rate 4.8%) — not yet integrated into this pipeline | **Not available** | 🔜 MIMIC via note extraction; ❌ eICU |
| Bleeding: FFP/plt/cryo volume | ICU0 → 48h | `strm_blood_mimic.csv` (FFP 10.5%, plt 12.7%, cryo 2.7%) | Sparse free-text | ⚠️ MIMIC descriptive; eICU absent |
| **Fluid benefit: crystalloid 24-48h** | ICU0+24h → 48h | `strm_fluid_mimic.csv`, crystalloid class, 85.3% | **Not available** | ✅ MIMIC only |
| Fluid benefit: non-blood fluid input | ICU0+24h → 48h | crystalloid + colloid + albumin summed | Not available | ✅ MIMIC only |
| Fluid benefit: non-bleeding net fluid balance | ICU0+24h → 48h | intake − urine − RRT ultrafiltration (excludes chest tube) | Not available | ✅ MIMIC only |
| Fluid benefit: fluid overload (balance/weight >5%) | ICU0+24h → 48/72h | Requires cumulative balance + admission weight | Not available | ⚠️ MIMIC possible but weight coverage varies |
| Circulation benefit: VIS/NE-eq change 24-48h | ICU0+24h → 48h | `strm_vaso_mimic.csv` with rates → computable | Not available | ✅ MIMIC only |
| Circulation benefit: vasopressor-free hours | ICU0+24h → 48h | Infusion start/end times available | Not available | ✅ MIMIC only |
| Circulation benefit: lactate clearance | ICU0+24h → 48h | Lactate in did_labs_all | Lactate in did_labs_all | ✅ Both DBs |
| **Ventilator-free days at day 28** | 28 days | `strm_vent_mimic.csv` segments + ventset → can compute | apachePredVar is day-1 only → **cannot compute VFD** | ✅ MIMIC only |
| **Vasopressor-free days at day 28** | 28 days | `strm_vaso_mimic.csv` infusion times | Not available | ✅ MIMIC only |
| **RRT-free days at day 28** | 28 days | RRT onset from existing pipeline | Same | ✅ Both DBs |
| **ICU-free days at day 28** | 28 days | `icu_discharge_h` | `icu_discharge_h` | ✅ Both DBs |
| Hospital-free days at day 28 | 28 days | `admissions.dischtime` | `hospitaldischargeoffset` | ✅ Both DBs |
| Hospital mortality / 30-day mortality | In-hospital | `hosp_mortality` | `hosp_mortality` | ✅ Both DBs |
| **Composite net benefit** (alive + no AKI 2-3/RRT + no major bleeding @ 30d) | 30 days | All components available (MIMIC) | AKI+mortality yes; bleeding crude | ✅ MIMIC; ⚠️ eICU partial |

---

## 7. HTE / Four-Quadrant Analysis — §9

| Yan Design | Our Implementation | Status |
|---|---|---|
| eGFR × initial Alb 四象限 (A/B/C/D) | **Secondary** (not primary). Initial Alb coverage: MIMIC ~26%, eICU ~61% → run in available-Alb subset with transparent reporting | ⚠️ Secondary; limited by Alb coverage |
| eGFR strata (≥60 / <60) | From `egfr`, 100% both DBs | ✅ |
| Initial Alb strata (≥3.0 / <3.0) | From `peri_admission_alb` where available | ⚠️ Subset analysis |
| Triple interaction (albumin × eGFR × initial Alb) | Exploratory only per Yan | ✅ Exploratory |

---

## 8. Post-24h Treatment Handling — §8

| Yan Design | Our Implementation | Status |
|---|---|---|
| Primary: early strategy (ITT at 24h landmark) | Implemented: classify at 24h, analyze as assigned | ✅ |
| Descriptive: 24h+ crossover rates | Computable from existing albumin infusion timestamps | ✅ |
| Per-protocol sensitivity (exclude/censor crossover ± IPCW) | **Not yet implemented** — requires IPCW framework | 🔜 Later |
| As-treated (early/late/never/continued) | Computable from timestamps | 🔜 Later |
| Time-varying exposure (0-24/24-48/48-72h) | **Advanced sensitivity** — deferred | 🔜 Later |

---

## 9. Sensitivity Analyses — §10

| Yan Sensitivity | Feasibility | Status |
|---|---|---|
| T0 window: 0-6h / 0-12h / 0-24h | N/A — T0=ICU0; instead restrict exposure onset ≤6h / ≤12h subsets | ✅ Adapted |
| Initial Alb threshold: 3.0 → 2.5 | Available in peri_admission_alb subset | ✅ |
| eGFR threshold: 60 → 45 or 90 | Available | ✅ |
| Exclude any AKI ≤24h | From landmark filter | ✅ |
| Exclude massive transfusion T0-24h | From strm_blood (MIMIC) | ✅ MIMIC |
| Exclude reoperation T0-24h | **Requires NLP** — 🔜 | 🔜 MIMIC |
| Exclude non-albumin colloid | N/A — 0% usage | ✅ Moot |
| Exclude 24h crossover | From albumin timestamps | ✅ |
| Adjust T0-24h crystalloid/blood/balance | PS-2 (MIMIC only) | ✅ MIMIC |
| PS-2 fluid-enhanced model | MIMIC only | ✅ MIMIC |
| IPTW / overlap weighting | Existing 02_psm framework supports | ✅ |
| MICE for missing values | Already implemented (m=20) | ✅ |
| AKI → any AKI | Already computed | ✅ |
| MAKE30 persistent renal: Cr ≥1.5× or eGFR drop ≥25% | **Needs day-30/discharge Cr coverage probe** | ⚠️ |
| Bleeding: ICU0+24h → 72h landmark | Available (shift window) | ✅ |

---

## 10. Fluid Classification — §13-14

| Yan Category | MIMIC | eICU | Status |
|---|---|---|---|
| **Resuscitation crystalloid** (NS + balanced) | `strm_fluid_mimic.csv` class="crystalloid", 15 itemids, 85.3%. Can split NS vs LR/Plasmalyte by itemid if needed. | Free-text celllabel ("NS", "Crystalloids", "LR") — **no dictionary built**, unusable without manual curation | ✅ MIMIC; ❌ eICU |
| Maintenance/glucose fluid (D5W, D5NS, etc.) | Included in crystalloid class; can split by itemid | Not available | 🔜 MIMIC (split from crystalloid) |
| Hypertonic saline | Not separately extracted (rare) | Not available | 🔜 Can add |
| Sodium bicarbonate | Not separately extracted | Not available | 🔜 Can add |
| **Albumin** (5%/20%/25%, dose g, volume mL) | 5% and 25% itemids confirmed. Volume in `amount_ml`. Dose(g) = 5%×0.05 + 25%×0.25 per mL. Concentration distinguishable. | Volume not reliably available (`alb_total_ml_24h = NaN`); concentration not distinguishable | ✅ MIMIC; ⚠️ eICU (binary only) |
| **Non-albumin colloid** (HES/dextran/gelatin) | **0.2%** — effectively zero | **~0%** | ❌ Dropped (clinical reality) |
| **Blood products** (RBC/FFP/plt/cryo) individually | `strm_blood_mimic.csv` with product type + volume, 30.5% ever received any | Free-text intakeOutput, ~11% pRBC | ✅ MIMIC; ⚠️ eICU (crude RBC only) |
| **Urine output** | `strm_output_mimic.csv` kind="urine", 99.1% | intakeOutput 80.9% (cumulative, noisy) | ✅ MIMIC; ⚠️ eICU (quality issue) |
| **Chest tube / mediastinal drainage** | `strm_output_mimic.csv` kind="chesttube", **75.7%** | ~11% | ✅ MIMIC; ❌ eICU too sparse |
| **Total fluid balance** | Computable: all inputevents − all outputevents | Not reliably computable | ✅ MIMIC only |
| **Non-bleeding net fluid balance** (Yan's preferred) | fluid inputs − urine − RRT ultrafiltration, **excluding** chest tube drainage | Not reliably computable | ✅ MIMIC only |
| Fluid overload (cumulative balance / weight >5%) | Balance + patientweight from inputevents | Not available | ⚠️ MIMIC (weight coverage varies) |

---

## 11. Two-Tier Design Summary

### MIMIC (primary, full functionality)
- PS-1 (27 vars) + PS-2 (33 vars, fluid-enhanced)
- All endpoints: AKI, MAKE30, bleeding (RBC + drainage + reoperation via NLP), fluid benefit, circulation benefit, organ-free days, net benefit composite
- Sensitivity analyses: full set

### eICU (external replication, light)
- PS-1 only (no vaso/MAP/fluid in PS due to hospital-level missingness)
- Endpoints: AKI (primary) + mortality + RRT + ICU-free days + lactate clearance
- No: bleeding detail, fluid benefit, organ-free days (except RRT-free, ICU-free)

---

## 12. Not Feasible (Limitation Section)

1. **All intraoperative variables** (CPB time, cross-clamp, DHCA, OR fluids/blood/urine, surgery duration) — neither database covers the OR period
2. **True preoperative labs** — "preop" values are actually first postoperative ICU measurements
3. **Structured LVEF** — not in either database (MIMIC-IV-ECHO is downloading; future work)
4. **Non-albumin colloid adjustment** — abandoned in US practice, 0% usage in both cohorts
5. **eICU precision hemodynamics** — MAP (53%) and vasopressor (23%) limited by hospital data interfacing; creates an asymmetry with MIMIC that must be acknowledged
6. **Albumin dose-response in eICU** — volume and concentration not reliably recorded
7. **Reoperation / resternotomy** — only extractable from MIMIC-Note NLP (not yet integrated); unavailable in eICU
