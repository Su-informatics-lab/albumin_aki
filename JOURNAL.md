# JOURNAL.md — Codex ↔ Supervisor log for the albumin_aki engine realignment

**Append-only.** Never edit or delete a prior entry. Codex adds one gate entry per phase (plus short
interim notes for long jobs). The supervisor replies inline with `APPROVED: Phase N` / `CHANGES
REQUESTED` / answers to `DECISION NEEDED` blocks. This file is the auditable trail from the current
drifted state to a frozen, defensible result.

Reading order for anyone picking this up: `PLAN.md` (design) → `LESSONS.md` (why the rules) →
`codex.md` (how to execute) → this file (what has happened).

---

## Entry template (copy for each gate)

```
## Entry N — Phase <k>: <name>  (<YYYY-MM-DD HH:MM>, Codex)

**Goal.** <one line from PLAN.md §4>

**Commands run.** (host: tempest | quartz | local)
```bash
<exact, copy-pasteable commands>
```

**Numbers that matter.**
| ... | ... |
|---|---|

**Gate criteria** (from PLAN.md §4):
- [✅/❌] <criterion> — <one line of evidence>

**Probes run.**
- `probe_<q>.py` — Q: <question> → A: <answer with context>

**Surprises & resolution.** <what looked wrong, what you did — or a DECISION NEEDED block>

**Files written.**
- Aggregate (committed): <...>
- Patient-level (HPC only, gitignored): <...>

**State block (for future self).** Frozen: <...>. Pending: <...>. Stopped at: <...>.

>>> STOP. Awaiting supervisor approval for Phase <k+1>. <<<
```

**DECISION NEEDED block** (use when blocked):
```
### DECISION NEEDED — <topic>
- Question: <...>
- Options: A <...> / B <...>
- Codex recommends: <A/B> because <...>
- Default if no answer: <only for reversible low-stakes items; else "none — blocking">
```

---

## Entry 0 — Supervisor kickoff  (2026-07-18, Claude)

**Mission.** Realign `albumin_aki` to the `icu-causal-engine` and automate the study end-to-end under a
gated supervisor↔Codex loop. This is a **realignment, not a rebuild**: the pure-engine risk-set pipeline
already exists (`02_psm.R`, `03_hte.R`) and was sidelined by a landmark fork. We restore it as primary.

**Binding decisions (see PLAN.md §0).** D1 pure-engine primary (first-albumin risk-set T0; landmark →
sensitivity). D2 Codex local + SSH to HPC. D3 full scope (MIMIC+eICU, LLM, IUH/Quartz, manuscript).
D4 gate at each phase.

**What the supervisor found in the current repo (validate this in Phase 0, file by file):**
- `02_psm.R` **is** the engine risk-set implementation (yet-untreated pool, first-albumin T0, m=20,
  1:1 with replacement, caliper 0.2, HC1, `set.seed(2026)`). Keep as canonical primary.
- `02_psm_v2.R` is the ICU0 24h-landmark fork (T0=ICU0, without-replacement, m=5 as presented). Demote →
  `02b_landmark_sensitivity.R`.
- `03_hte.R` already reads `did_pairs_primary_yet_untreated_*` — already wired to the risk-set. Verify, don't rebuild.
- `.gitignore` ignores **all** `*.csv` ⇒ no aggregate "frozen truth" is committed. Fix in Phase 1 (PLAN.md §6).
- Trigger-lab handling is off-canon: primary PS **excludes** peri-admission albumin; `sens_a` adds it
  **continuous**. Build **`alb_cat`** (normal/low/missing) into the primary PS (LESSONS.md §6).
- No `iuh/` directory yet — Phase 7 builds it from **raw** Quartz tables, modeled on `mg/iuh/` (never a
  derived convenience parquet; LESSONS.md §4).
- `llm_extract/` is scaffolded (cardiac_cohort/extract/schema/validate) — Phase 6 runs + validates it,
  per `CODEX_LLM_TASK.md`.

**The T0 clarification (read PLAN.md §1 in full).** The v2 landmark was adopted partly because a
serum-albumin-**lab**-anchored T0 is infeasible (only ~7.9% MIMIC treated have a pre-infusion albumin
lab). The engine never anchored on the lab — it anchors on first **administration** (100% of treated).
So pure-engine primary is feasible; the albumin lab is the trigger covariate (`alb_cat`), not the clock.

**First tasks for Codex (Phase 0):**
1. Read `PLAN.md`, `LESSONS.md`, `codex.md`.
2. Validate the drift inventory (PLAN.md §2) against the live repo, file by file; correct any row that
   is wrong and note it here.
3. Confirm the Phase 0 gate items: estimand statement, eGFR modifier + rationale, falsification
   (mortality), positive control (+ expected magnitude).
4. Post the two blocking `DECISION NEEDED` items below to the team, and STOP.

### DECISION NEEDED — Yan sign-off on primary/sensitivity ordering (blocking Phase 2)
- Question: Dr. Yan (clinical lead) approved the ICU0-landmark design and it was presented to Eadon &
  Meng. D1 restores the risk-set as **primary** and keeps the landmark as a co-reported **sensitivity**.
  Does Yan approve this ordering?
- Options: A risk-set primary + landmark sensitivity (D1) / B keep landmark primary (overrides D1 —
  supervisor must re-authorize) / C co-primary (both).
- Codex recommends: A — it matches the engine and the T0 clarification (PLAN.md §1) while preserving
  Yan's analysis as a sensitivity.
- Default if no answer: none — blocking for the Phase 2 freeze.

### DECISION NEEDED — positive control magnitude (Phase 0 gate)
- Question: What specific prior result and expected effect size should we pre-register as the positive
  control the pipeline must reproduce?
- Options: A ALBICS bleeding/resternotomy harm direction (Pesonen JAMA 2022) / B a published
  observational albumin→AKI association (e.g., Zhang, Renal Failure 2025) / C both.
- Codex recommends: A as the RCT-grade directional control, with B as a supporting observational anchor.
- Default if no answer: none — name it before Phase 3 so the control is pre-specified, not post-hoc.

>>> Handing off to Codex. Begin Phase 0. STOP at the Phase 0 gate for supervisor review. <<<

---

## Entry 0b — Supervisor addendum: main-branch workflow + plan-first  (2026-07-18, Claude)

- **Git.** We work directly on `main`. A safety snapshot of the pre-realignment (v2 landmark) state exists as branch `backup/pre-engine-realign-2026-07-18` and tag `pre-engine-realign-2026-07-18`. Recovery: `git checkout backup/pre-engine-realign-2026-07-18`. (Note: `.gitignore`, `README.md`, `CODEX_LLM_TASK.md`, `10_nlp.py`, `yan_protocol_gap_analysis.md` are present in the working tree but were never committed — commit them as part of Phase 1 hygiene.)
- **Plan-first (required).** Codex has the `icu-causal-engine` skill installed. Phase 0 is a *critique-and-plan* gate: invoke the skill, validate the drift inventory, push back on anything in `PLAN.md` / `PHASE1.md` you disagree with, and propose your own Phase 1 execution plan in Entry 1 — **before changing any file or running any job.**
- **Phase 1 work order.** See `PHASE1.md` for the supervisor-proposed Phase 1 scope. Treat it as a draft to critique and refine, not a fixed script.

---

<!-- Codex: append Entry 1 (Phase 0) below this line. -->

## Entry 1 — Phase 0: critique and plan  (2026-07-18 19:27 EDT, Codex)

**Goal.** Name the causal contrast and pre-specified modifier, validate the live repository against
`PLAN.md`, challenge design drift before it becomes code, and post a run-ready Phase 1 plan. This was
a planning gate: no ETL, analysis, remote job, or pipeline edit was performed.

**Commands run.** (host: local Mac unless stated otherwise)

```bash
cd /Users/haining/Desktop/github/albumin_aki
rm -f .git/index.lock
cat AGENTS.md
cat codex.md
cat PLAN.md
cat LESSONS.md
cat PHASE1.md

# Step 0 history review and requested commit
git status --short --branch
git branch --show-current
git branch --list backup/pre-engine-realign-2026-07-18
git tag --list pre-engine-realign-2026-07-18
git add codex.md PLAN.md LESSONS.md JOURNAL.md AGENTS.md PHASE1.md \
  .gitignore README.md CODEX_LLM_TASK.md 10_nlp.py \
  yan_protocol_gap_analysis.md .pre-commit-config.yaml
git diff --cached --check
git commit -m "Add icu-causal-engine realignment harness"
# Hooks formatted 10_nlp.py and correctly stopped the first attempt.
git add 10_nlp.py
git commit -m "Add icu-causal-engine realignment harness"
git push origin main

# The assumed installation was absent. A local package was found, validated, and installed.
unzip -l "/Users/haining/Library/CloudStorage/OneDrive-SharedLibraries-IndianaUniversity/[Sec-E] IN-BSTA-Su Lab-Haining Research - Documents/Haining Research/skills/icu-causal-engine.skill"
unzip -q "/Users/haining/Library/CloudStorage/OneDrive-SharedLibraries-IndianaUniversity/[Sec-E] IN-BSTA-Su Lab-Haining Research - Documents/Haining Research/skills/icu-causal-engine.skill" \
  -d /Users/haining/.codex/skills
cat /Users/haining/.codex/skills/icu-causal-engine/SKILL.md
cat /Users/haining/.codex/skills/icu-causal-engine/references/design-canon.md
cat /Users/haining/.codex/skills/icu-causal-engine/references/failure-modes.md
cat /Users/haining/.codex/skills/icu-causal-engine/references/self-correction.md

# Live implementation audit
cat 00_config.py
cat 01_etl.py
cat 01b_covariates.py
cat 01c_endpoints.py
cat 02_psm.R
cat 02_psm_v2.R
cat 03_hte.R
cat STUDY_DESIGN.md
cat yan_protocol_gap_analysis.md
cat CODEX_LLM_TASK.md
cat qc_probe.py
cat run.sh
find . -maxdepth 2 -type f | sort
rg -n 'to_csv|write\.csv|read\.csv|02_psm_v2|did_consort|did_pairs|did_binary_pairs|matched_pairs|binary_results|did_results' .
```

The four installed engine files were SHA-256-compared with their four archive members; every pair
matched. The ALBICS positive-control candidates were checked against the primary JAMA report
(Pesonen et al., 2022, DOI `10.1001/jama.2022.10461`).

**Numbers that matter.**

| Check | Live result |
|---|---:|
| Step 0 commit pushed to `origin/main` | `e8c2303` |
| Engine package files validated | 4/4 checksum matches |
| `02_psm.R` eGFR strata used for matching | 0 |
| `02_psm.R` primary PS covariates currently include eGFR and CKD | both |
| `02_psm.R` missing-post-Cr binary coding | `NA` then pair deletion |
| `03_hte.R` declared primary modifier | peri-admission albumin |
| `01_etl.py` CONSORT outputs | one `did_consort.csv`, not per-DB files |
| Current `alb_cat` implementation | absent |
| Current `iuh/` directory | absent |
| Current `llm_extract/` scaffold files | 5 present |
| Untracked files intentionally left out of Step 0 | `.Rhistory`, `codex_kickoff_prompt.md` |

### Phase 0 estimand and controls

**Estimand.** Among eligible, matchable adult cardiac-surgery ICU patients at the time a treated
patient first receives IV albumin, estimate the ATT-like effect of **initiating albumin now** versus
**deferring albumin for at least 24 hours**, using a yet-untreated risk set (later-treated patients
remain eligible controls at earlier index times), within pre-specified baseline eGFR strata. The
primary outcome family is incident creatinine-defined KDIGO AKI after index T0; PSM+DiD is the sole
primary estimator. Eligibility and prevalent AKI are assessed at the treated patient's index T0 for
both members of a potential pair.

**T0 clarification: agreement with an important qualification.** `PLAN.md §1` is correct that the
7.9%/32% pre-infusion serum-albumin coverage objection does not make administration-time T0
infeasible. First administration is directly observed for treated patients. However, the current
code does not yet fully implement the claimed time alignment:

- `01_etl.py` identifies first albumin from raw MIMIC `inputevents` itemids `220862/220864` and raw
  eICU medication/intakeOutput text, so treated T0 ascertainment is feasible.
- `02_psm.R` allows later-treated patients into earlier risk sets, but it fits one global PS and uses
  one static covariate vector per patient. For never-treated controls, `extract_labs()` can select the
  last lab from the entire ICU stay, including values after the treated patient's T0 and outcome.
- For horizons beyond 24 hours, `02_psm.R` drops controls treated before that horizon, changing the
  specified "defer at least 24h" strategy into horizon-specific continued non-treatment. Primary
  analyses should allow treatment after the 24-hour defer grace period or label the censoring as a
  separate per-protocol sensitivity.

**Effect modifier.** Baseline eGFR is retained as the primary modifier because renal reserve is the
biologically proximal vulnerability axis for a renal outcome and has a plausible interaction with
albumin-associated hemodilution, volume, and bleeding pathways. Use the fewest supported strata,
starting with G1 `>=90`, G2 `60-89`, and G3+ `<60`; derive the modifier from the frozen baseline
creatinine anchor, match separately within each stratum, and remove both eGFR and redundant CKD from
the within-stratum PS.

**Falsification.** Retain hospital/7-day mortality as the requested falsification sentinel and expect
a null association. Pushback: mortality is not a perfect negative-control outcome because albumin
could plausibly affect it through bleeding, AKI, or support complications. A non-null mortality
result must trigger a confounding/mediation probe; it must not be used to select an estimator.

**Positive control candidate.** The closest RCT benchmark is ALBICS major bleeding: RR `1.73`
(95% CI `1.12-2.68`), with observed risks approximately 7.5% versus 4.3%; that risk contrast
corresponds to an unadjusted OR of about `1.80`. Resternotomy was RR `1.85` and infection RR `1.45`.
Because ALBICS used 4% albumin as CPB prime plus perioperative replacement while this study captures
postoperative ICU 5%/25% albumin, an exact effect-size reproduction is not a valid pass/fail test
unless the team first freezes an ALBICS-compatible outcome and accepts the exposure mismatch. Codex
recommends an ALBICS-like MIMIC bleeding definition (drainage `>20 mL/kg` at 18h or `>=5` RBC units)
with expected harm direction and OR benchmark near `1.8`; keep the current `>1500 mL`/`>=4`-unit
proxies as separately labeled sensitivities.

### Validated drift inventory (`PLAN.md §2`)

| Area | Live-file finding | Verdict / correction |
|---|---|---|
| Primary estimator | Both `02_psm.R` risk-set and `02_psm_v2.R` landmark exist. | Row correct, but “risk-set implementation” is only partial: no eGFR-stratified matching and covariates are not indexed to each risk-set T0. |
| T0 | `02_psm.R` uses treated first-albumin time; v2 uses ICU0/24h. | Row correct. Add the post-24h crossover inconsistency described above. |
| Matching | Risk-set code reuses controls; v2 removes selected controls. | Row correct. v2 also lacks HC1 robust inference. |
| Imputation | Both default to m=20; v2 accepts an m override and the presented run used m=5. | Correct. Risk-set code averages completed covariate values; v2 averages PS predictions, so the two scripts do not implement the same imputation estimand. |
| Trigger albumin | Primary omits it; `sens_a` uses continuous `last_albumin`; no `alb_cat`. | Correct but incomplete. Static `peri_admission_alb` uses `[-48,+6]` hours from ICU0 and can be post-infusion. `alb_cat` must be computed strictly pre-index T0 for treated and each candidate control, not once per patient in ETL. |
| Headline | `STUDY_DESIGN.md` leads with landmark main-effect OR 2.55. `03_hte.R` labels albumin strata primary and eGFR secondary. | Correct the row: the live code does **not** yet implement the proposed eGFR headline. It only tests binary `eGFR<60` interaction after globally matched pairs. |
| eICU PS | v2 creates vaso/MAP objects but excludes them from `PS_SHARED`. | Correct. Retain this exclusion; probe hospital-level missingness. |
| Committed truth | `.gitignore` ignores `results/` and all `*.csv`. | Correct. The proposed Phase 1 whitelist is unsafe unless it also excludes `did_binary_pairs_*`, `matched_pairs_*`, LLM cohort/checkpoint/output, and `llm_qc_spotcheck.txt` (IDs/note excerpts). |
| Freeze/state | Live `STUDY_DESIGN.md` is the landmark design and no state dump exists. | Correct. Do not freeze until Phase 2 and Yan sign-off. |
| Probes | `qc_probe.py` exists; no question-specific `probe_*` files exist. | Correct. `qc_probe.py` is coverage reporting, not a clean/pass-fail validator. |
| HTE wiring | `03_hte.R` reads `did_pairs_primary_yet_untreated_*` and subsets on treated covariates. | Filename/pair preservation correct, but “already aligned” is wrong: eGFR is secondary, missing albumin is accidentally coded as the low/reference group in one interaction, outcomes are separately recomputed, and pairs were not eGFR-stratified. Verify and repair in the HTE phase. |
| Baseline/outcome | Not listed in the draft inventory. | Add critical drift: `01_etl.py` checks for pre-T0 Cr eligibility but writes `first_cr` from the earliest post-ICU Cr, while `02_psm.R` recomputes the last pre-T0 Cr. Fallback Cr is not exported in `did_cr_all_*` because negative offsets are dropped. eGFR, prevalent-AKI exclusion, and outcome baselines are therefore not canonical. |
| Missing post-T0 outcome | Not listed as live drift. | Add critical drift: risk-set continuous outcomes require both post labs; binary `compute_kdigo()` returns NA with no post lab and deletes the pair. This violates the frozen non-event rule and disagrees with `03_hte.R`, which returns zero. |
| Outcome definition | Draft says creatinine-only KDIGO and RRT descriptive. | Live `02_psm.R` promotes in-window RRT to cumulative AKI stage 3. Resolve at freeze; current code contradicts the plan. |
| CONSORT | Draft expects `did_consort_{db}.csv`. | Live ETL writes one wide `did_consort.csv`. Phase 1 should emit one auditable long-form per-database aggregate (or update every contract consistently). |
| External validation | No `iuh/` directory. | Correct. |
| LLM endpoints | Five-file scaffold exists locally. | Correct for source state. Execution/result state was not re-run or remotely verified in Phase 0. |

### Critique of `PLAN.md` / `PHASE1.md` and engine-directed changes

1. **Do not build one static `alb_cat` in `did_all_*`.** In risk-set matching, a control's index time is
   the treated patient's T0 and can differ across reused control slots. The current `[-48,+6]` ICU0
   albumin window may also include post-infusion values. Phase 1 should retain/audit timestamped raw
   albumin; Phase 3 should derive `alb_cat(index_t0)` using only measurements strictly before that
   index. A treated-only own-T0 category may be emitted for QC but is not the PS covariate.
2. **The creatinine anchor must be made canonical before ETL is accepted.** The live `first_cr`,
   eGFR, prevalent-AKI check, and downstream R baselines are different constructs. Freeze a hierarchy
   that distinguishes the preoperative/reference Cr used for KDIGO/eGFR from merely the last
   pre-albumin postoperative Cr. Never silently promote a post-CPB value to “preoperative.”
3. **The Phase 1 `probe_nopost_cr.R` gate is premature.** There is no estimand-valid control arm or
   control index T0 until matching. In Phase 1, report treated own-T0 and candidate-risk-set
   descriptives only. Run the required arm-level/pair-level no-post-Cr probe immediately after
   primary pairs are created in Phase 3 and before binary results are accepted.
4. **The draft Phase 1 command is invalid.** `01b_covariates.py` requires `{mimic|eicu}` and does not
   loop both. `01c_endpoints.py` is MIMIC-only. Run explicit database commands with separate logs.
5. **`qc_probe.py` has no failure assertions.** Treat its output as descriptive. Add explicit
   acceptance checks in the focused probes and fail on schema/timing violations.
6. **Default-deny result versioning is safer.** Ignore `results/*` and unignore only reviewed
   aggregate files. Do not commit `llm_qc_spotcheck.txt`: it contains identifiers and note excerpts.
   Never `git add -f` a wildcard before inspecting every matched path.
7. **Mortality is a sentinel, not a guaranteed negative control.** Keep it because it is binding, but
   interpret a signal as a reason to probe, not automatic proof of residual confounding.
8. **ALBICS magnitude is not transportable without harmonization.** Pre-specify the exact
   ALBICS-like bleeding endpoint before treating RR 1.73 / OR about 1.8 as a benchmark.
9. **Phase ordering has an implementation gap.** Phase 2 freezes design but Phase 3 is written as
   though `02_psm.R` already satisfies it. Phase 3 must explicitly include code repair plus static
   tests before the first primary run: index-time covariates, eGFR-stratified PS, canonical baseline,
   non-event missing-outcome coding, and balance exports.

### Concrete Phase 1 execution plan (after `APPROVED: Phase 1`)

**P1.1 — Safety/preflight (no data mutation).**

```bash
# local
cd /Users/haining/Desktop/github/albumin_aki
git status --short --branch
git log -1 --oneline
git branch --list backup/pre-engine-realign-2026-07-18
git tag --list pre-engine-realign-2026-07-18

# Tempest: require a clean checkout before pull; STOP if dirty/diverged
ssh tempest 'cd ~/albumin_aki && git status --porcelain=v1 && git branch --show-current && git log -1 --oneline'
ssh tempest 'cd ~/albumin_aki && git pull --ff-only origin main'
ssh tempest 'sinfo -h -o "%P %a %l" | head'
```

Acceptance: local and Tempest are on `main`; backup branch/tag exist; remote checkout is clean and
fast-forwarded; no patient file is copied locally.

**P1.2 — Repository hygiene.**

- Replace blanket `*.csv` logic with default-deny `results/*` plus explicit aggregate allow-list.
- Keep all row-level streams/cohorts/pairs/checkpoints/LLM endpoints/spot-check excerpts ignored,
  including `did_binary_pairs_*`, `matched_pairs_*`, `cardiac_surgery_cohort_*`,
  `llm_qc_spotcheck.txt`, `dx_infection_*`, and all `strm_*`, `labs_ext_*`, `cr_variants_*`.
- Add `.Rhistory`; keep `codex_kickoff_prompt.md` untracked unless the supervisor separately requests
  it in history.
- Before every commit:

```bash
git status --short
git diff --check
git diff --cached --name-only
git check-ignore -v results/did_all_mimic.csv results/did_binary_pairs_mimic.csv \
  results/llm_endpoints_mimic.csv results/llm_qc_spotcheck.txt
```

Acceptance: patient-level examples are ignored; only individually inspected aggregate artifacts can
be staged.

**P1.3 — Probe current raw ascertainment before changing ETL.**

Create single-question, non-pipeline probes with CLI contracts:

- `probe_alb_ascertainment.py {mimic|eicu}`: raw source rows, item/pattern/source counts, cancelled or
  rewritten rows, route missingness, duplicate source overlap, first administration distribution,
  `>24h` late/rescue share, and confirmation that each treated T0 maps to a raw row.
- `probe_baseline_anchor.py {mimic|eicu}`: candidate reference-Cr tiers, timestamps relative to ICU0
  and treated T0, fallback reliance, values/eGFR distribution, baseline `>=4`, and prevalent AKI at
  T0. It must read raw labs, because current `did_cr_all_*` discards negative offsets.
- `probe_alb_cat_coverage.py {mimic|eicu}`: albumin timing relative to own T0 for treated patients;
  counts for strictly pre-T0 low/normal/missing under the approved cut; explicitly count how many
  current `peri_admission_alb` values occur after infusion.
- Move `probe_nopost_cr.R` to the Phase 3 gate for matched, pair-indexed arm estimates. A Phase 1
  descriptive version may be run but cannot satisfy that later gate.

Run:

```bash
ssh tempest 'cd ~/albumin_aki && module purge && module load Python/3.10.8-GCCcore-12.2.0 && source ~/alcrx/.venv/bin/activate && mkdir -p logs && python probe_alb_ascertainment.py mimic 2>&1 | tee logs/probe_alb_mimic.log && python probe_alb_ascertainment.py eicu 2>&1 | tee logs/probe_alb_eicu.log && python probe_baseline_anchor.py mimic 2>&1 | tee logs/probe_baseline_mimic.log && python probe_baseline_anchor.py eicu 2>&1 | tee logs/probe_baseline_eicu.log && python probe_alb_cat_coverage.py mimic 2>&1 | tee logs/probe_albcat_mimic.log && python probe_alb_cat_coverage.py eicu 2>&1 | tee logs/probe_albcat_eicu.log'
```

Acceptance: no post-index value is labeled baseline/trigger; every exposure T0 is traceable to an
accepted raw administration row; all fallback and missing-category counts are machine-emitted. Any
surprising count or timing violation triggers STOP, not an automatic ETL patch.

**P1.4 — Implement only the supervisor-approved Phase 1 ETL contract.**

- Add the approved albumin cut as a named constant, with boundary `low < cut`, `normal >= cut`.
- Preserve time-stamped albumin and creatinine inputs needed for index-time construction.
- Emit one canonical reference baseline value, source tier, and timestamp per patient only after the
  anchor hierarchy is approved; derive eGFR from that same value.
- Do not add a static control `alb_cat` as if it were index-time aligned.
- Emit auditable per-database CONSORT aggregates with ordered steps and exclusion deltas.
- Re-read every edited file and run local syntax checks before syncing:

```bash
python3 -m compileall -q 00_config.py 01_etl.py 01b_covariates.py 01c_endpoints.py \
  qc_probe.py probe_alb_ascertainment.py probe_baseline_anchor.py probe_alb_cat_coverage.py
git diff --check
```

**P1.5 — Run ETL explicitly by database on Tempest.**

```bash
ssh tempest 'cd ~/albumin_aki && git pull --ff-only origin main && module purge && module load Python/3.10.8-GCCcore-12.2.0 && source ~/alcrx/.venv/bin/activate && mkdir -p logs && python 01_etl.py mimic 2>&1 | tee logs/01_etl_mimic.log && python 01_etl.py eicu 2>&1 | tee logs/01_etl_eicu.log && python 01b_covariates.py mimic 2>&1 | tee logs/01b_mimic.log && python 01b_covariates.py eicu 2>&1 | tee logs/01b_eicu.log && python 01c_endpoints.py 2>&1 | tee logs/01c_mimic.log && python qc_probe.py 2>&1 | tee logs/qc_probe.log'
```

Acceptance:

- both databases emit `did_all_*`, `did_cr_all_*`, `did_labs_all_*`, and per-DB CONSORT aggregates;
- accepted baseline tier/timing/eGFR invariants pass and fallback reliance is reported;
- all treated T0s trace to raw administration records;
- pre-T0 albumin coverage and post-infusion contamination are explicitly reported;
- `qc_probe.py` completes, but focused probe assertions are the actual gate;
- no PSM/HTE/landmark script runs;
- no row-level artifact is staged or copied off Tempest.

**P1.6 — Gate and commit.** Inspect aggregate files for identifiers/small-cell disclosure, commit only
approved aggregate CONSORT plus source/probe changes, append Entry 2, push, and STOP. The matched-arm
no-post-Cr gate remains pending for Phase 3.

### Gate criteria (from `PLAN.md §4`)

- [✅] T0 and treatment strategy named — first IV albumin administration; initiate now versus defer
  at least 24h in a yet-untreated risk set.
- [✅] Estimand named — ATT-like effect among matchable treated index events, within eGFR strata,
  estimated by PSM+DiD.
- [✅] Modifier and rationale named — baseline eGFR/renal reserve; G1/G2/G3+ starting strata, subject
  to sparse-cell support.
- [✅] Falsification named — mortality retained as a null-expected sentinel, with the causal caveat
  above.
- [❌] Positive-control magnitude frozen — a defensible ALBICS benchmark was identified, but the
  team must approve the endpoint harmonization and magnitude target below.
- [✅] Drift inventory validated file-by-file — corrected inventory above.
- [✅] Yan sign-off requested — still blocking the Phase 2 freeze, not Phase 1 probes.

**Probes run.** None. Phase 0 was repository/code inspection only; no patient-level data or HPC job was
opened. The required Phase 1 probes and their acceptance checks are specified above.

### DECISION NEEDED — Yan sign-off on primary/sensitivity ordering (blocking Phase 2)

- Question: Does Yan approve **risk-set primary + ICU0/24h landmark sensitivity**, despite the prior
  presentation using landmark primary?
- Options: A risk-set primary + landmark sensitivity / B landmark primary (requires explicit override
  of D1) / C co-primary (changes multiplicity and interpretation).
- Codex recommends: A. Administration-time T0 is feasible; the lab-coverage objection applies to a
  lab-anchored T0 that this design does not use. Preserve the landmark analysis as a named,
  co-reported sensitivity.
- Default if no answer: none — blocking for Phase 2.

### DECISION NEEDED — positive-control endpoint and magnitude (Phase 0 gate)

- Question: Should the positive control be an ALBICS-compatible MIMIC major-bleeding endpoint with
  expected harm OR near 1.8 (published RR 1.73), or only a directional bleeding/support benchmark?
- Options: A exact ALBICS-like bleeding definition and OR benchmark about 1.8 / B direction-only
  benchmark because exposure products/timing differ / C select a closer observational
  postoperative-albumin result with an operationally matched exposure and endpoint.
- Codex recommends: A for MIMIC plus B as the interpretation: freeze the exact ALBICS-like endpoint,
  treat OR about 1.8 as a benchmark rather than an equivalence pass/fail threshold, and require only
  direction in eICU where bleeding detail is inadequate. Resternotomy RR 1.85 and infection RR 1.45
  remain secondary checks after LLM validation.
- Default if no answer: none — blocking before the positive control is analyzed.

### DECISION NEEDED — `alb_cat` timing and cut (blocking final Phase 1 ETL)

- Question: Confirm both (1) cut `3.5 g/dL` with `low <3.5`, `normal >=3.5`, and (2) index-time
  derivation from the most recent qualifying albumin strictly before each treated/candidate-control
  index T0, rather than static `peri_admission_alb` from ICU0 `[-48,+6]`.
- Options: A 3.5 and strict pre-index derivation / B 3.0 and strict pre-index derivation / C another
  clinically specified cut/window.
- Codex recommends: A. It obeys the no-downstream-covariate guard rail and preserves a missing level
  without contaminating it with post-infusion measurements.
- Default if no answer: none — `PLAN.md §7.5` is an open clinical decision.

**Surprises & resolution.**

- The named engine skill was not installed despite the kickoff assumption. The local packaged skill
  was found, validated, installed, checksum-verified, and read before design judgment.
- The first commit attempt was correctly stopped by repository hooks that formatted `10_nlp.py`.
  The formatting diff was reviewed, AST-checked, staged, and the successful commit was pushed.
- The largest scientific surprise is that the supposedly ready risk-set primary is not eGFR
  stratified and uses future control labs. This is logged as Phase 3 repair work, not silently fixed
  during Phase 0.

**Files written.**

- Aggregate/source committed in Step 0: `.gitignore`, `.pre-commit-config.yaml`, `10_nlp.py`,
  `AGENTS.md`, `CODEX_LLM_TASK.md`, `JOURNAL.md`, `LESSONS.md`, `PHASE1.md`, `PLAN.md`, `README.md`,
  `codex.md`, `yan_protocol_gap_analysis.md` at commit `e8c2303`.
- Phase 0 gate report: this append-only Entry 1 in `JOURNAL.md`.
- Patient-level (HPC only): none read, written, copied, or committed.
- Pipeline files changed in Phase 0: none.

**State block (for future self).** Frozen: D1-D4 remain binding unless the supervisor explicitly
changes them; no study design has yet been frozen. Pending: three decisions above, especially the
positive-control gate and index-time `alb_cat`; exact baseline hierarchy must be accepted after the
Phase 1 raw-data probe. Stopped at: Phase 0 gate. Do not edit ETL or run Tempest jobs until the
supervisor appends `APPROVED: Phase 1`.

>>> STOP. Awaiting supervisor approval for Phase 1. <<<
