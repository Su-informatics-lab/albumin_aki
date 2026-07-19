# PLAN.md — Supervisor Blueprint for the albumin_aki Engine Realignment

**Author:** Claude (supervisor / study architect)
**Executor:** Codex (worker / HPC handyman)
**Engine:** `icu-causal-engine` (risk-set PSM + DiD with effect-modifier stratification)
**Reference study:** `mg_aki` / `mg` (the prototype that paid the debugging cost)
**Status:** Draft plan — freezes into `STUDY_DESIGN.md` at the Phase 2 gate, after supervisor + Yan sign-off.

This document is the single authoritative description of *what* we are building and *why*.
`codex.md` describes *how* Codex executes it. `LESSONS.md` is the scar tissue that
justifies the guard rails. `JOURNAL.md` is where Codex reports back at each gate.

---

## 0. Decision record (from the supervising session)

Four decisions were made before this plan was written; they are binding until revised in writing.

| # | Decision | Consequence |
|---|---|---|
| D1 | **Pure engine design is primary.** Patient-specific *first-albumin-administration* risk-set T0, exactly like mg_aki. | `02_psm.R` (risk-set) is canonical. The ICU0 24h-landmark design is demoted to a **sensitivity analysis**, not discarded. |
| D2 | **Codex runs locally + SSH to HPC.** Codex CLI operates in the local Mac repo, edits files there, SSHes to Tempest/Quartz to run jobs, syncs via git. | Human stays in the loop locally; patient-level data never leaves the HPC. |
| D3 | **Full scope.** MIMIC + eICU core (Tempest), the 12 LLM endpoints (CatChat), IUH external validation (Quartz), and a manuscript scaffold. | Four workstreams, phased. |
| D4 | **Gate at each phase.** Codex runs one engine phase, writes a `JOURNAL.md` gate report, and STOPS for supervisor review before advancing. | No phase begins until the previous gate is approved. |

---

## 1. The crux: why "pure engine primary" is feasible (the T0 clarification)

The current repo (`STUDY_DESIGN.md` v2, `02_psm_v2.R`) abandoned the risk-set design in favor
of a fixed ICU0 + 24h-landmark design. `yan_protocol_gap_analysis.md` records the stated reason:
Dr. Yan judged that a **serum-albumin-lab-anchored T0** is operationally infeasible because only
**7.9% (MIMIC) / ~32% (eICU)** of treated patients have a qualifying albumin lab *before* infusion,
and because "术后输白蛋白的首要原因不是为了纠正低白蛋白" (post-op albumin is usually a volume
strategy, not correction of a low albumin lab).

**That objection is correct — but it does not apply to the engine's design.** The engine never
anchored T0 on a lab. It anchors T0 on the **first albumin administration**, which is known for
**100%** of treated patients (it is *how* we know they are treated). The peri-admission serum
albumin is the engine's **trigger lab** — a covariate, coarse-categorized in the PS (or an effect
modifier), *never* the T0 anchor. So:

- The infeasibility Yan cited (lab-anchored T0) is real, and the engine agrees: **do not anchor on the albumin lab.**
- The engine's actual anchor (first-administration T0) is fully available and is what `02_psm.R` already implements.
- Therefore the pure risk-set design is feasible, and the ICU0 landmark is a *choice*, not a necessity.

**Guard-rail note / collaborator action:** Yan is the clinical lead and hypothesis originator, and the
current results were presented to Eadon & Meng under the landmark design. Restoring the risk-set as
*primary* is D1 and is scientifically defensible, but it re-orders Yan's stated preference. We are
**not discarding** the landmark analysis — it is retained as a co-reported sensitivity. **Yan must
sign off** on "risk-set primary, landmark sensitivity" before the Phase 2 freeze. This is logged as
an open decision in §7 and must be surfaced in the Phase 1 → 2 gate report.

---

## 2. Current-state drift inventory

What the realignment inherits, and what it must fix. Codex confirms each row by reading the actual
file before acting (never from this table alone).

| Area | Current repo state | Engine canon | Action |
|---|---|---|---|
| Primary estimator | `02_psm.R` risk-set exists **and** `02_psm_v2.R` landmark fork exists; v2 was the presented "primary" | One canonical primary; sensitivities named for what they compute | **Restore `02_psm.R` as primary. Rename `02_psm_v2.R` → `02b_landmark_sensitivity.R`.** No `_v2` forks. |
| T0 | v2: ICU0 for everyone | First exposure (first albumin) | Primary = first-albumin T0 (already in `02_psm.R`). Landmark T0=ICU0 lives only in the sensitivity script. |
| Matching | v2: 1:1 **without** replacement | 1:1 **with** replacement, caliper 0.2 SD, HC1 SE | Primary uses with-replacement (already in `02_psm.R`). Fix the sensitivity script to match, or document the difference. |
| Imputation | v2 presented at **m=5** | MICE PMM **m=20** averaged | All reported runs at m=20. m=5 only for smoke tests, never reported. |
| Trigger lab (albumin) | `primary` spec **excludes** `peri_admission_alb`; `sens_a` adds it **continuous** | Enter trigger lab as a **coarse category** (normal/low/missing); never continuous; do not fully drop | **Add `alb_cat`** (normal / low / missing at a clinical cut, e.g. 3.5 g/dL) to the primary PS, mirroring mg_aki's `mg_cat`. Keep continuous-albumin as the over-adjustment sensitivity (`sens_a`). |
| Headline | v2: main effect (severe AKI OR 2.55) | The **effect modification** is the paper; a fragile main effect is not | Headline = albumin × eGFR interaction (the replicating signal in memory: OR ~1.2 at eGFR≥90 → ~7.8 at eGFR 30–44). Main effect reported, not led with. |
| eICU PS | vaso (23%) / MAP (53%) flagged | Informative missingness must not enter PS | eICU = PS-1 only; **no vaso/MAP/fluid in eICU PS**. MIMIC gets PS-2 fluid-enhanced sensitivity. |
| Committed truth | `.gitignore` ignores **all** `*.csv` → nothing frozen | Commit **aggregate** result CSVs as frozen truth; patient-level `.gitignore`d | Carve aggregate results out of `.gitignore` (see §6); keep `did_pairs_*`, patient-level `did_all_*` ignored. |
| Freeze / state | No `STUDY_DESIGN` freeze for the risk-set design; no `STATE_*` dumps | Freeze `STUDY_DESIGN.md`; write a state dump each session | Rewrite + freeze `STUDY_DESIGN.md` at Phase 2; Codex writes a state block in `JOURNAL.md` each gate. |
| Probes | `qc_probe.py` exists (good) | One probe per surprising number, committed | Keep `qc_probe.py`; add `probe_*.{py,R}` per surprise, mirroring `mg/probes/`. |
| HTE wiring | `03_hte.R` reads `did_pairs_primary_yet_untreated_*` (already risk-set!) | HTE on the matched pairs; interaction tested formally | `03_hte.R` is already aligned to the risk-set output. Verify, don't rebuild. |
| External validation | No `iuh/` directory in albumin_aki | Identical engine on an independent site | Build `albumin_aki/iuh/` modeled on `mg/iuh/` (Quartz). |
| LLM endpoints | `llm_extract/` scaffolded (cardiac_cohort/extract/schema/validate) | — | Run + validate, don't rebuild (per `CODEX_LLM_TASK.md`). |

## 2.1 Additional drift verified by Codex in Phase 0 (2026-07-18)

Codex's Entry 1 audit read the live code and found drift the draft §2 missed. All six were
supervisor-verified against `02_psm.R` and are accepted. They reshape Phase 3 (see §4).

| # | Verified finding | Fix (phase) |
|---|---|---|
| a | `02_psm.R` fits **one global PS with `egfr` + `ckd` as covariates**; no eGFR-stratified matching. | eGFR-stratified matching, `egfr`+`ckd` removed from PS (Phase 3 repair). |
| b | **Control covariates leak future info**: `extract_labs()` uses each patient's own `alb_offset_h`; never-treated controls get the last lab of the whole stay, past the treated partner's index T0. | Extract control covariates at the **treated partner's index T0** (Phase 3 repair). |
| c | **Baseline Cr is not canonical**: earliest-Cr (prevalent-AKI), last-pre-T0 Cr (KDIGO), and ETL `first_cr`/eGFR are three different constructs. | One canonical `baseline_cr` + tier + timestamp in ETL; eGFR + prevalent-AKI from it (Phase 1). |
| d | **Missing post-T0 Cr → `NA` → pair deleted** in `02_psm.R`, but `03_hte.R` codes `0`. Scripts disagree; deletion is the collider bug (failure-modes #2). | Non-event (0) coding in every outcome script (Phase 3 repair; reconcile with `03_hte.R`). |
| e | **`02_psm.R` promotes in-window RRT to AKI stage 3**, contradicting a Cr-only endpoint. | Resolve at Phase 2 freeze *with Yan* (his primary = "stage 2–3 AKI or new RRT"); keep a Cr-only variant. |
| f | **`peri_admission_alb` `[-48,+6]` from ICU0 can be post-infusion**; a static `alb_cat` would be contaminated. | Derive `alb_cat` strictly pre-index-T0 in Phase 3; Phase 1 only preserves timestamped inputs + audits coverage. |

Consequence: the "restore `02_psm.R` as primary" row in §2 is only partly right — `02_psm.R` is the
right *skeleton* but needs the (c)–(f) fixes before its first trusted run. **Superseded by Entry 4b:**
(a) eGFR stratification is now a *variant to run alongside the pooled analysis*, not a mandatory removal;
(b) index-time control-covariate re-extraction is *not required* (mg behavior stands, optional sensitivity only).

---

## 3. The frozen design (the swap kit, filled in)

These are the engine's **fixed** elements (do not re-derive) plus the **albumin-specific** swaps.
This section becomes `STUDY_DESIGN.md` after the Phase 2 gate.

### 3.1 Estimand & control pool (FIXED)
Yet-untreated risk-set matching (sequential trial emulation; Lu 2005, Hernán & Robins 2016). At each
treated patient's T0, controls = everyone still in ICU, still at risk (no outcome yet), with a valid
pre-T0 baseline creatinine, untreated through the grace window, not self. Later-treated patients are
eligible controls at earlier index times. **Never** restrict to never-treated controls.

### 3.2 Treatment & T0 (SWAP)
- Treatment = **first IV albumin administration**. T0 = its time, patient-specific.
- MIMIC albumin items: `220862` (25%), `220864` (5%) — verified in `00_config.py`.
- eICU albumin from medication/intakeOutput text patterns (`00_config.py` `ALB_INFUSION_PATTERNS`, `ALB_IO_PATTERNS`).
- Grace window `GRACE_H` (primary) with a `12h` sensitivity.

### 3.3 Eligibility & exclusion at T0 (SWAP the disease-specific parts)
Adult, cardiac-surgery ICU, first ICU stay, ≥1 baseline Cr before T0. Exclude: pre-existing
ESKD/dialysis, baseline Cr ≥ 4.0, and **AKI already present at T0** (prevalent-outcome exclusion makes
this an incidence study).

### 3.4 Baseline anchoring (FIXED pattern; site-specific window)
Baseline Cr = last value before T0 in the correct **preoperative / pre-exposure** window, computed
identically for treated and control, with a documented fallback hierarchy. **Never** let
intraoperative/post-CPB values contaminate baseline (failure-modes #8). Record fallback reliance in
CONSORT. Note honestly: in MIMIC/eICU, "preop" labs are in practice the first *postoperative* ICU
values — state this as a limitation (`yan_protocol_gap_analysis.md` §3 caveat).

### 3.5 Propensity-score covariates (mirror mg; swap the trigger lab)
Per Entry 4b: **use mg's covariate set**; do not build a bespoke expanded model.
- **Primary PS = mg's set, adapted:** age, sex, BMI; surgery type (CABG, valve, combined); pre-ICU comorbidities (HF, HTN, DM, COPD, PVD, stroke, liver); `last_lactate` + `last_lactate_missing`; `last_heartrate`; the trigger lab **`alb_cat`** (mg's `mg_cat` analogue); and **`hemoglobin`** as albumin's key confounder (hemodilution pathway). Whether `egfr`/`ckd` sit in the PS depends on the variant (§3.6): **in** for the pooled analysis, **removed** for the eGFR-stratified one.
- **Trigger lab handling (FIXED rule):** `alb_cat` = normal / low / **missing** (missing dominant given ~26% MIMIC coverage — a feature: adjusts for indication where measured, absorbs the unmeasured majority). **Never continuous, never raw in the PS.** Continuous albumin is the `sens_a` over-adjustment check only.
- **Downstream exclusions (follow mg):** anything realized after T0; reassess `calcium` (albumin binds calcium — likely downstream; mg dropped calcium). Comorbidities strictly **pre-ICU**.
- **Yan's cardiac-surgery extras = OPTIONAL pre-specified sensitivity, not primary:** `surg_aortic`, `vent_at_t0`, extended labs (platelet/INR/BUN/bicarbonate/sodium), and the MIMIC-only fluid/vaso/MAP set. Add only if omitting a specific covariate is indefensible (说不通). **eICU never gets vaso/MAP/fluid** (hospital-level informative missingness: vaso 23%, MAP 53%).
- **Not available (Limitation):** all intraoperative variables (CPB time, cross-clamp, DHCA, OR fluids/transfusion), true preop labs, structured LVEF.

### 3.6 Analyses to run (pooled + stratified; don't prejudge the headline)
Per Entry 4b, run and compare — minimal novelty; let the data decide the story:
- **(a) Pooled main effect** — `egfr` in the PS, no stratification (the current `02_psm.R` behavior).
- **(b) eGFR-stratified** (mg-style) — `egfr` + redundant `ckd` removed from the PS, matched within eGFR strata; consolidate to as few as the data supports (mg_aki: G1 ≥90 / G2 60–89 / G3+ <60).
- **(c) Other stratifications, exploratory** — baseline albumin (Zhang bins, available-albumin subset with transparent coverage), age, surgery type.

If albumin's **main effect** is robust across MIMIC + eICU and clinically clean (ALBICS-consistent harm),
it can be the paper — unlike mg, we are **not** forced to pivot to a modifier (mg pivoted only because its
main effect was fragile). If instead the effect holds only within an eGFR stratum, that becomes the story.
Report whichever is robust; do not manufacture a modifier.

### 3.7 Outcomes (SWAP the operationalization; keep the rules)
- **Primary:** incident CSA-AKI by KDIGO creatinine criteria — absolute (ΔCr ≥ 0.3 within 48h) and relative (ratio ≥ 1.5 within 7d); cumulative stage indicators (≥1, ≥2, ≥3) as independent ≥ tests. Urine-output criterion not used; RRT kept descriptive (documented limitation), mirroring mg_aki.
- **Missing post-T0 outcome lab → non-event (0), consistently in every outcome script.** Members with no usable baseline stay NA everywhere. (Collider justification; failure-modes #2.)
- **Continuous support (DiD):** ΔCr from baseline at fixed horizons; DiD = mean(Δ_treated) − mean(Δ_control) via `lm(delta ~ treated)` with HC1 SE; use the window-max lab (KDIGO is peak-based).
- **Secondary (ALBICS-aligned harm phenotype):** severe AKI/new RRT, major bleeding (RBC ≥4u, chest-tube drainage >1500 mL — MIMIC), prolonged ventilation/vasopressor, F-MPAO composite; MAKE30 and organ-free days where feasible (MIMIC-rich, eICU-light per `yan_protocol_gap_analysis.md` §11).
- **LLM endpoints (12, MIMIC notes):** return-to-OR, reintubation, pneumonia/VAP, sepsis, sternal wound infection, bloodstream infection, cardiac arrest, POAF, acute heart failure, stroke, delirium, myocardial injury (`CODEX_LLM_TASK.md`).
- **Falsification (negative control):** hospital / 7-day mortality — expect **null** (v2 already shows OR 0.90, P 0.55, a good sign). Reported in a table, never narrated.
- **Positive control:** ALBICS-consistent **bleeding/support harm direction** (Pesonen JAMA 2022) — expect to reproduce the direction. To be finalized with an explicit expected effect size at the Phase 0 gate (see §7); do not invent a number.

### 3.8 Estimator hygiene (FIXED)
PSM+DiD is the **only** primary estimator. IPTW/AIPW/IPCW target a different estimand (population-weighted
ATE, no pairing) — archive/optional only, never primary, never pooled across databases, never used to
rescue significance. Pick the estimand first, then one estimator, then sensitivities that change **one**
assumption at a time.

---

## 4. Phase roadmap (mapped to albumin; each phase is a gate)

Codex executes one phase, writes a `JOURNAL.md` gate report, and STOPS. The supervisor reviews and
authorizes the next phase. Every gate here corresponds to a mistake that cost real rework in mg_aki.

### Phase 0 — Frame & pre-specify (mostly done; needs sign-off)
- **Do:** Confirm the estimand in plain language; pin the pre-specified effect modifier (eGFR) and its rationale; name the falsification endpoint (mortality) and the positive control (ALBICS bleeding direction) *with an expected magnitude*.
- **Gate:** T0, treatment strategy ("give albumin now vs defer"), modifier + rationale, falsification, and positive control are all named. The Yan "risk-set primary" sign-off is requested.
- **Deliverable:** `JOURNAL.md` Entry 1 (Phase 0 confirmation) + the drift inventory (§2) validated against the live repo.

### Phase 1 — ETL & cohort (MIMIC + eICU on Tempest)
- **Do:** Run `01_etl.py`, `01b_covariates.py`, `01c_endpoints.py`; build `alb_cat`; verify baseline anchoring and first-albumin T0 ascertainment from raw source tables; emit CONSORT counts from the ETL.
- **Gate:** baseline anchored pre-exposure (fallback reliance recorded); exposure defined from raw `inputevents`/medication tables inspected by Codex (not a derived convenience file); `qc_probe.py` clean; CONSORT counts emitted.
- **Deliverable:** `did_all_*`, `did_cr_all_*`, `did_labs_all_*`, `did_consort_*` (aggregate committed); QC probe output in `JOURNAL.md`.

### Phase 2 — Lock & freeze the design
- **Do:** Rewrite `STUDY_DESIGN.md` to the pure-engine design (risk-set primary, landmark sensitivity); rename `02_psm_v2.R` → `02b_landmark_sensitivity.R`; run `grill-my-research` against every fuzzy definition.
- **Gate:** control pool = yet-untreated; `alb_cat` coarse (not continuous, not dropped); eGFR is a stratifier removed from PS; comorbidities strictly pre-ICU; downstream variables excluded; `set.seed(2026)` before MICE; **Yan sign-off on primary/sensitivity ordering received.**
- **Deliverable:** frozen `STUDY_DESIGN.md` (versioned, dated); `JOURNAL.md` freeze entry listing every reversed/dropped decision.

### Phase 3 — PSM + DiD (primary estimator)
- **Mirror mg first (before any run), minimal changes (Entry 4b):** bring `02_psm.R` to mg's behavior — **non-event coding** for missing post-T0 outcomes (reconcile with `03_hte.R`); the **two-reference baseline** (Entry 4); `alb_cat` (mg's `mg_cat` analogue) at index T0; mg's covariate set (§3.5). Add the **eGFR-stratified variant** (egfr+ckd removed, match within strata) *alongside* the existing pooled version. **Not required:** index-time control-covariate re-extraction (a refinement beyond mg — optional sensitivity only). Add small static-fixture tests for the non-event coding + baseline, then run.
- **Do:** `Rscript 02_psm.R <db>` for mimic + eicu — run **both** the pooled and eGFR-stratified variants; MICE m=20 averaged, 1:1 with replacement, caliper 0.2, HC1; doubly-robust adjustment for any post-match SMD > 0.1.
- **Gate:** logistic PS only; match rate ~95%+ per stratum (if it collapses, the control pool is the constraint — do **not** reach for a flexible PS, failure-modes #5); balance table produced; SMD reported only for PS covariates.
- **Deliverable:** `did_riskset_*`, `did_binary_*`, `did_pairs_primary_yet_untreated_*` (patient-level → HPC only), `psm_balance_*` (aggregate committed).

### Phase 4 — HTE & effect modification (the headline)
- **Do:** `Rscript 03_hte.R <db>`; stratum-specific ORs + **formal** treatment × eGFR interaction test (one modifier at a time, HC1); secondary albumin-strata HTE in the available-albumin subset.
- **Gate:** effect modification tested formally (not asserted from cherry-picked strata); subgroup subsetting is on the **treated** patient's covariate only, retaining the originally matched control (the pair is the unit — failure-modes #1); interaction sign consistent across MIMIC/eICU.
- **Deliverable:** `did_hte_*`, `did_hte_interact_*`; interaction P table in `JOURNAL.md`.

### Phase 5 — Sensitivity, QC & falsification
- **Do:** landmark sensitivity (`02b_landmark_sensitivity.R`); grace-window `12h`; `sens_a` (continuous albumin over-adjustment); `sens_b` (first vs last labs); PS-2 (MIMIC fluid-enhanced); competing-risks / naive-incidence check; one probe per surprising number.
- **Gate:** falsification (mortality) null where expected; positive control reproduced; each sensitivity changes exactly one assumption and preserves the PSM+DiD estimand; cumulative incidence via **naive fixed-window**, not Kaplan-Meier (discharge is informative censoring — failure-modes #3); every surprising number has a committed probe.
- **Deliverable:** sensitivity CSVs; `probe_*` scripts + outputs; `JOURNAL.md` QC entry.

### Phase 6 — LLM endpoints (MIMIC notes, CatChat)
- **Do:** Run `llm_extract/` per `CODEX_LLM_TASK.md`: `cardiac_cohort` → dry-run → full extract (checkpoint/resume) → `validate`.
- **Gate:** 100% completion (≤1% `-1` failures); ICD-vs-LLM κ > 0.4 for pneumonia/sepsis; <5% low-confidence; human spot-check ≤10% error on the 60 sampled cases (Haining reviews).
- **Deliverable:** `llm_endpoints_mimic.csv`, `llm_qc_concordance.txt`, `llm_qc_spotcheck.txt`; re-run of downstream endpoint tables that consume them.

### Phase 7 — External validation (IUH on Quartz) + manuscript scaffold
- **Do:** Build `albumin_aki/iuh/` modeled on `mg/iuh/` (raw `Procedure.parquet` + ICU-stay tables — **not** a derived convenience parquet, failure-modes #4); run the identical engine and covariate spec; then scaffold STROBE/RECORD (`strobe-audit`) and Nature-style methods/results (`nature-*`).
- **Gate:** identical engine + covariate spec; sparse strata flagged (report, don't interpret — failure-modes #13); IUH is supplement-level unless powered; claim strength calibrated to evidence; implausibly large effects demoted out of the headline.
- **Deliverable:** IUH aggregate results; STROBE checklist; methods/results draft.

---

## 5. Databases, sites & infrastructure

| Workstream | Where | Login / path | Notes |
|---|---|---|---|
| MIMIC-IV v3.1, eICU-CRD v2.0 | Tempest | `g91p721@tempest-login`; data `~/mg_aki/`; repo `~/albumin_aki/` | Core pipeline (Phases 1–6). |
| MIMIC-IV-Note v2.2 | Tempest | `~/mg_aki/physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz` | LLM endpoints (Phase 6). |
| IUH ICU (Epic) | Quartz | Confirm login + paths via the `iuh-icu-etl` skill and `mg/iuh/` (do not guess) | External validation (Phase 7). |
| CatChat LLM | Tempest → MSU API | `https://catchat-api.msu.montana.edu/v1/chat/completions`, `gpt-oss:120b`, `Bearer $CATCHAT_API_KEY` | Phase 6. |

Toolchains: R `R/4.5.1-gfbf-2025a`; Python `Python/3.10.8-GCCcore-12.2.0` + venv `~/alcrx/.venv/`.
`module purge` between R and Python. SLURM: `#SBATCH --export=NONE` (a leaked interactive Python once
broke R jobs). Copy `mg/run_psm.sh` as the SLURM template; **confirm `--account` / `--partition`** on
first submit rather than trusting the header.

---

## 6. Artifact map & git discipline

**Canonical scripts (one per job; no version forks):**
- `00_config.py` — constants (add `alb_cat` cut).
- `01_etl.py`, `01b_covariates.py`, `01c_endpoints.py` — cohort + covariates + structured endpoints.
- `02_psm.R` — **primary** risk-set PSM + DiD.
- `02b_landmark_sensitivity.R` — the demoted ICU0 landmark analysis (renamed from `02_psm_v2.R`).
- `03_hte.R` — eGFR-stratified HTE + interaction tests.
- `04_figures.py`, `gen_table1.py`, CONSORT — reporting (model on `mg/`).
- `10_nlp.py` + `llm_extract/` — LLM endpoints.
- `qc_probe.py` + `probe_*.{py,R}` — one probe per surprising number.
- `iuh/` — Quartz external validation (model on `mg/iuh/`).
- SLURM wrappers `run_psm.sh` / `*.sbatch` (add; currently only `run.sh` exists).

**`.gitignore` (default-deny).** The current file ignores all `*.csv`, so nothing is frozen. Switch to
**default-deny**: ignore `results/*` and `logs/`, then unignore only individually reviewed aggregate
files (`did_riskset_*`, `did_binary_*` [the summary, **not** `did_binary_pairs_*`], `egfr_stages_*`,
`psm_balance_*`, `did_hte_*`, `did_hte_interact_*`, `did_consort_*`). **Never commit** patient-level or
PHI-bearing files: `did_pairs_*`, `did_binary_pairs_*`, `matched_pairs_*`, `did_all_*`, `did_cr_all_*`,
`did_labs_all_*`, `strm_*`, `labs_ext_*`, `cr_variants_*`, `_llm_checkpoint.csv`, `llm_endpoints_*.csv`,
and `llm_qc_spotcheck.txt` (note excerpts + IDs). Run `git check-ignore -v` on a patient-level example
before every commit. PhysioNet DUA forbids row-level records; aggregate cell counts are fine and are
the manuscript's source of truth.

**Branch discipline.** Work directly on `main`; the backup branch `backup/pre-engine-realign-2026-07-18`
+ tag preserve the pre-realignment (v2 landmark) state as the safety net. Commit per phase and push to
`origin/main` after the gate is approved. Every manuscript number must trace to one committed aggregate CSV.

---

## 7. Open decisions requiring supervisor / collaborator input

Codex must **STOP and ask** (via a `JOURNAL.md` "DECISION NEEDED" block) rather than choose these:

1. **Yan sign-off** on "risk-set primary, landmark sensitivity" (§1). Blocking for Phase 2.
2. **Positive control magnitude** — the specific prior result and expected effect size to reproduce (Phase 0 gate). Candidate: ALBICS bleeding/resternotomy direction; confirm the target with the team; do not fabricate.
3. **Table 1 counting** for with-replacement matching — per-slot vs unique-patient (open in both mg and albumin memory). Decide before Table 1.
4. **eGFR strata count** — 3 (G1/G2/G3+) vs a finer split — resolved by observed per-stratum match counts, not a priori.
5. **`alb_cat` cut point** — clinical threshold for "low" albumin (e.g., 3.0 vs 3.5 g/dL). Yan to confirm.

---

## 8. The one rule that matters most

Before any result sentence: does the **eGFR-modification** story hold across MIMIC and eICU (and, at
supplement level, IUH), and does the **mortality falsification** stay null? If yes, that is the paper.
If we are defending a borderline main effect (v2's OR 2.55) by choice of estimator or design, we are
about to be desk-rejected. The interaction is the honest, interesting, and defensible paper.
