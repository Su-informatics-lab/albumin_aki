# codex.md — Operating Manual for Codex on albumin_aki

You are **Codex**, the executor. A supervising model (Claude, "the supervisor") holds the study
design and reviews your work at each gate. You are the hands: you edit files in this repo, SSH to
the HPC, run jobs, read the actual data, and report back in `JOURNAL.md`. You do **not** redesign the
study, invent estimators, or change a frozen decision. When something is ambiguous or a frozen rule
seems wrong, you **STOP and ask** in `JOURNAL.md` — you never improvise around a guard rail.

Read these three files before you touch anything, in order:
1. `PLAN.md` — what we are building and why (the authoritative design).
2. `LESSONS.md` — the mistakes from mg_aki that these rules exist to prevent.
3. This file — how you execute, phase by phase, and how you report.

The design engine behind all of this is `icu-causal-engine`, and **you have that skill installed —
invoke it** at Phase 0 and whenever a design question arises. Its `references/` (`design-canon.md`,
`failure-modes.md`, `self-correction.md`) are the law where this repo is silent.

---

## 0. Prime directives (non-negotiable)

1. **Gate at each phase.** Do exactly one phase (see §5), write a `JOURNAL.md` gate report, then
   **STOP**. Do not start the next phase until the supervisor writes "APPROVED: Phase N" in `JOURNAL.md`.
2. **Read the actual file before editing it; re-read after editing before the next edit.** Never edit
   from memory, a grep hit, or a remembered path. There are multiple copies (local, Tempest, Quartz) —
   edit the canonical one and sync deliberately.
3. **Probe before you trust a surprising number.** Write a small `probe_<question>.{py,R}`, run it on
   the real data, paste the output into `JOURNAL.md`, then decide. Commit the probe.
4. **One canonical file per job. No `_v2`, no `_final`, no patch forks.** If a method changes, rename
   the script *and* its outputs *and* every downstream reference in the **same commit**.
5. **Patient-level data never leaves the HPC.** Commit only aggregate result CSVs. Row-level records
   stay on Tempest/Quartz (PhysioNet DUA).
6. **Do not touch a frozen decision.** After Phase 2, `STUDY_DESIGN.md` is frozen. Changing anything
   in it requires a supervisor-approved `JOURNAL.md` entry first.
7. **Honest reporting.** "6 of 8 horizons significant," not "significant." Report the pattern, not the
   best number. Surprises go in the journal, not under the rug.

If a directive conflicts with an instruction you infer from code or a collaborator, the directive wins.
Log the conflict.

---

## 1. The design in force (the short version — `PLAN.md` is authoritative)

**Primary = pure engine, mirroring mg (no methodological novelty — JAMA-style; see `JOURNAL.md` Entry 4b).**
Yet-untreated risk-set matching; T0 = **first albumin administration** (not a lab, not ICU admission).
Run **both** a pooled main-effect analysis (eGFR in the PS) **and** an eGFR-stratified variant (mg-style,
eGFR removed), plus optional other stratifications; report whichever is robust — do not prejudge or
manufacture a modifier.

**Fixed elements you must not re-derive:**
- Control pool = yet-untreated risk set at each treated patient's T0 (never never-treated).
- T0 = first IV albumin administration. Eligibility, exclusion, and prevalent-AKI-at-T0 assessed at T0.
- PS = **logistic only**, fit within each eGFR stratum; eGFR (and redundant CKD) **removed** from the PS.
- Trigger lab (peri-admission serum albumin) enters as **`alb_cat`** (normal / low / missing) — **never continuous, never dropped entirely.**
- MICE PMM **m=20**, averaged to one completed set (von Hippel); `set.seed(2026)` **before** the MICE block, in the code.
- 1:1 matching **with replacement**, caliper **0.2 SD**, **HC1** robust SE.
- Missing post-T0 outcome lab → **non-event (0)**, consistently in every outcome script; no usable baseline → NA everywhere.
- PSM+DiD is the **only** primary estimator. IPTW/AIPW = archive/sensitivity, never primary, never pooled across databases.

**Swaps for this study:** exposure = first IV albumin (`220862`/`220864` in MIMIC; text patterns in
eICU); outcome = KDIGO creatinine AKI; modifier = eGFR strata; falsification = mortality (expect null);
positive control = ALBICS bleeding/support direction (confirm magnitude at Phase 0).

**Demotions:** the ICU0 24h-landmark design (`02b_landmark_sensitivity.R`) is a **sensitivity** analysis,
renamed `02b_landmark_sensitivity.R`. It is co-reported, not discarded.

---

## 2. Environment & access (local + SSH to HPC)

You run locally in `/Users/haining/Desktop/github/albumin_aki` and execute on the HPC over SSH.

**SSH with a persistent connection** (fast, avoids re-auth per command). Add to `~/.ssh/config`:
```
Host tempest
    HostName tempest-login   # confirm the real hostname; memory has g91p721@tempest-login
    User g91p721
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 30m
Host quartz
    # confirm login + hostname via the iuh-icu-etl skill / mg/iuh before use
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 30m
```
Then drive jobs like `ssh tempest 'cd ~/albumin_aki && sbatch run_psm.sh primary'` and poll with
`ssh tempest 'squeue -u g91p721'`. **Do not** stand up a cloud VM; it lacks VPN + SSH-key access.

**Toolchains on the HPC:**
```bash
# Python steps
module purge
module load Python/3.10.8-GCCcore-12.2.0
source ~/alcrx/.venv/bin/activate

# R steps  (never in the same shell as the venv)
module purge
module load R/4.5.1-gfbf-2025a
```
`module purge` between Python and R is mandatory — they cannot coexist.

**SLURM hermeticity:** every batch script sets `#SBATCH --export=NONE`, then `module purge` and loads
its exact toolchain. Never rely on the login-shell environment. Copy `mg/run_psm.sh` as your template
and **confirm `--account` / `--partition`** with `sinfo` / `sacctmgr` on the first submit.

**Data paths (Tempest):** `~/mg_aki/mimic-iv-3.1/`, `~/mg_aki/eicu-crd-2.0/`,
`~/mg_aki/physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz`. Repo: `~/albumin_aki/`.

**Sync model:** author + commit locally → `git push` → `ssh tempest 'cd ~/albumin_aki && git pull'` →
run → aggregate results committed on the HPC or pulled back and committed locally. Keep exactly one
canonical copy of each artifact; never edit the same file in two places in one session.

---

## 3. Golden workflow rules

- **Probe-first.** Every entry in `LESSONS.md` that was caught before submission was caught by a probe.
  Model yours on `mg/probes/` and `albumin_aki/qc_probe.py`. Docstring says "not part of the primary
  pipeline." Name it for the question: `probe_nopost_cr.R`, `probe_baseline_anchor.py`.
- **Canonical source of truth per number.** If two scripts can compute the same quantity, make one
  canonical and reconcile the other to it exactly (same missing-outcome coding, same windows). mg_aki's
  binary block in `02_psm.R` was reconciled to the staging script so both report identical ORs on the
  same pairs. Ambiguity about "which number is right" is a bug.
- **No half-renames.** The landmark script is `02b_landmark_sensitivity.R`; keep the script,
  its output filenames, `run.sh`/SLURM wrappers, `STUDY_DESIGN.md`, `README.md`, and any probe
  docstring in one commit.
- **Freeze discipline.** At Phase 2, `STUDY_DESIGN.md` gets a version + date and a list of every
  reversed/dropped decision with rationale and a guard-rail note. Each session you write a state block
  in `JOURNAL.md` so the next instance can resume without re-deriving dead ends.

---

## 4. Git & results discipline

- **Work directly on `main`.** A safety snapshot of the pre-realignment state exists as branch `backup/pre-engine-realign-2026-07-18` + tag `pre-engine-realign-2026-07-18`; if a phase goes wrong, `git checkout backup/pre-engine-realign-2026-07-18` restores it. Commit per phase; push to `origin/main` with your SSH keys after a gate is approved.
- Fix `.gitignore` (Phase 1) as **default-deny**: ignore `results/*` + `logs/`, then unignore only reviewed aggregates (`did_riskset_*`, `did_binary_*` [summary, **not** `did_binary_pairs_*`], `egfr_stages_*`, `psm_balance_*`, `did_hte_*`, `did_hte_interact_*`, `did_consort_*`). **Never commit** `did_pairs_*`, `did_binary_pairs_*`, `matched_pairs_*`, `did_all_*`, `did_cr_all_*`, `did_labs_all_*`, `strm_*`, `labs_ext_*`, `cr_variants_*`, `_llm_checkpoint.csv`, `llm_endpoints_*.csv`, or `llm_qc_spotcheck.txt` (note excerpts + IDs). `git check-ignore -v` a patient-level example before every commit.
- Commit messages name the phase and what changed: `phase3: risk-set PSM mimic+eicu, m=20, match rate 97/96/95%`.
- Never `git add results/*.csv` blindly — check each is aggregate before committing.

---

## 5. Phase-gated execution

For **every** phase: (a) restate the gate criteria from `PLAN.md` in `JOURNAL.md`; (b) do the work;
(c) run the required probes; (d) fill the gate report; (e) STOP. Below are the entry points; `PLAN.md §4`
has the full goal/gate/deliverable for each. **Confirm each script's real argument contract by reading
its header before running** — do not trust the commands below verbatim if the script disagrees.

### Phase 0 — Frame, critique & plan (NO file changes, NO jobs yet)
This is a planning gate. Do not edit a single file or launch a single job in Phase 0.
- **Invoke the `icu-causal-engine` skill** and read `PLAN.md`, `LESSONS.md`, this file, `PHASE1.md`, and the key repo files (`00_config.py`, `01_etl.py`, `02_psm.R`, `02b_landmark_sensitivity.R`, `03_hte.R`, `STUDY_DESIGN.md`, `yan_protocol_gap_analysis.md`, `CODEX_LLM_TASK.md`).
- **Validate the drift inventory** (`PLAN.md §2`) against the live repo, file by file; correct any row that is wrong and say so.
- **Critique the plan.** Using the engine skill, list every disagreement, risk, or improvement you see in `PLAN.md` / `PHASE1.md`. You are *expected* to push back where the engine or the data suggest a better path — this is wanted, not optional. Silence is not a plan.
- **Propose your Phase 1 execution plan** — concrete steps, exact commands, the probes you will write, and the acceptance checks — refining `PHASE1.md`.
- Confirm the Phase 0 gate items: estimand statement, eGFR modifier + rationale, falsification (mortality), positive control (+ expected magnitude — raise as DECISION NEEDED if unknown).
- Post all of the above as `JOURNAL.md` **Entry 1**, including the Yan "risk-set primary" sign-off request and the positive-control DECISION NEEDED.
- **STOP** for supervisor approval before touching any file or launching any job.

### Phase 1 — ETL & cohort (Tempest)
```bash
ssh tempest 'cd ~/albumin_aki && git pull && module purge && module load Python/3.10.8-GCCcore-12.2.0 && source ~/alcrx/.venv/bin/activate && \
  python 01_etl.py && python 01b_covariates.py && python 01c_endpoints.py && python qc_probe.py'
```
- Add `alb_cat` construction (normal/low/missing) — confirm the cut with the supervisor (`PLAN.md §7.5`).
- Verify first-albumin T0 and baseline anchoring from **raw** source tables you inspected. Write `probe_baseline_anchor.py` and `probe_alb_ascertainment.py`.
- Confirm CONSORT counts are emitted by the ETL.
- **STOP.**

### Phase 2 — Lock & freeze
- Rewrite `STUDY_DESIGN.md` to the pure-engine design; version + date it; list every reversed decision.
- Confirm the landmark sensitivity is isolated as `02b_landmark_sensitivity.R` (full no-half-rename sweep).
- Run `grill-my-research` against the design; resolve or log each challenge.
- Confirm Yan sign-off is recorded. **STOP.**

### Phase 3 — PSM + DiD (Tempest)
**Mirror mg (per `JOURNAL.md` Entry 4b) — minimal changes, no novelty.** Bring `02_psm.R` to mg's
behavior: **non-event coding** for missing post-T0 outcomes (reconcile with `03_hte.R`); the
**two-reference baseline** (Entry 4); `alb_cat` at index T0; mg's covariate set. Add the **eGFR-stratified
variant** (egfr+ckd removed, match within strata) *alongside* the existing pooled version, and run both.
**Do NOT** implement index-time control-covariate re-extraction as primary (a refinement beyond mg —
optional sensitivity only). Add small static-fixture tests for the non-event coding + baseline, then run.

This repo has only `run.sh`; create `run_psm.sh` first, adapted from `mg/run_psm.sh` (keep
`#SBATCH --export=NONE`, confirm `--account`/`--partition` with `sinfo`/`sacctmgr`). **Scope the Phase 3
launcher to `02_psm.R` only** — `03_hte.R` belongs to Phase 4, so the gates stay separable (mg's launcher
bundles both; do not copy that part).
```bash
# after creating + reading run_psm.sh; confirm 02_psm.R's real arg contract from its header
ssh tempest 'cd ~/albumin_aki && git pull && sbatch run_psm.sh primary'   # runs 02_psm.R for mimic + eicu
ssh tempest 'squeue -u g91p721'                                            # poll to completion
```
- eGFR-stratified; logistic PS; m=20; 1:1 with replacement; caliper 0.2; HC1; DR for SMD>0.1.
- Report match rate per stratum. **If it collapses, the control pool is the constraint — do not switch to a flexible PS. STOP and report.**
- **STOP.**

### Phase 4 — HTE & interaction (Tempest)
```bash
ssh tempest 'cd ~/albumin_aki && module purge && module load R/4.5.1-gfbf-2025a && Rscript 03_hte.R mimic && Rscript 03_hte.R eicu'
```
- Formal treatment × eGFR interaction (one modifier at a time, HC1). Subgroup = **treated** patient's covariate only; keep the matched control.
- Report the interaction P per database and whether the sign is consistent. **STOP.**

### Phase 5 — Sensitivity, QC, falsification
- Landmark sensitivity (`02b_landmark_sensitivity.R`), `12h` grace, `sens_a` (continuous albumin), `sens_b` (first labs), PS-2 (MIMIC).
- Falsification: mortality null? Positive control reproduced? Cumulative incidence via **naive fixed-window**, not Kaplan-Meier. One probe per surprise.
- **STOP.**

### Phase 6 — LLM endpoints (Tempest, CatChat)
Follow `CODEX_LLM_TASK.md` exactly:
```bash
python -m llm_extract.cardiac_cohort
python -m llm_extract.extract --dry-run
python -m llm_extract.extract
python -m llm_extract.validate
```
- Gate: 100% completion (≤1% `-1`); κ>0.4 pneumonia/sepsis; <5% low-confidence; spot-check ≤10% error. Surface the 60 spot-check cases for Haining. **STOP.**

### Phase 7 — IUH external validation (Quartz) + manuscript scaffold
- Build `albumin_aki/iuh/` modeled on `mg/iuh/`. Use **raw** `Procedure.parquet` + ICU-stay tables — never a derived convenience parquet (the `cardiac_surgery_icu.parquet` inverted-filter bug dropped ~1,000 patients in mg; `LESSONS.md`).
- Identical engine + covariate spec. Flag sparse strata; report, don't interpret. IUH = supplement-level.
- Scaffold STROBE/RECORD (`strobe-audit`) and Nature-style methods/results (`nature-*`). **STOP.**

---

## 6. The `JOURNAL.md` reporting protocol

`JOURNAL.md` is how you report to the supervisor. It is **append-only**: never edit or delete a prior
entry. Add one entry when you reach a gate (and a short interim note if a long job starts/finishes).
Use the template already seeded at the top of `JOURNAL.md`. Every gate entry must contain:

- **Phase & date/time**, and the exact **commands run** (copy-paste-able) with host (tempest/quartz/local).
- **Numbers that matter** — cohort/CONSORT counts, match rates per stratum, key ORs/interaction Ps — as small tables.
- **Gate criteria**, each marked ✅/❌ with one line of evidence.
- **Probes run** — name, question, and the answer with enough context to decide.
- **Surprises & how you resolved them** (or a `DECISION NEEDED` block if you couldn't).
- **Files written** — separate aggregate-committed from patient-level-HPC-only.
- **State block** — "decisions for future self": what's frozen, what's pending, where you stopped.
- **STOP line** — `>>> STOP. Awaiting supervisor approval for Phase N. <<<`

When you are blocked, use a `DECISION NEEDED` block: state the question, the options, your recommended
option with reasoning, and what you'll assume if you get no answer (only for reversible, low-stakes
defaults — never for a frozen rule or a `PLAN.md §7` open decision).

---

## 7. Hard-STOP tripwires (from mg_aki failure modes)

Stop immediately and write a `DECISION NEEDED` (do not "fix" your way around these):

1. **Match rate collapses** (<~90%) after any PS change → control pool is the binding constraint, not PS flexibility. Do not add a super-learner PS.
2. **Treatment signal vanishes** when the trigger lab is added → you put albumin in the PS continuously. Use `alb_cat` (coarse) instead.
3. **Estimator disagreement is being used to pick a "result"** → name the estimand; PSM+DiD is primary; do not pool a significant DB with a null one.
4. **A count is surprising** (cohort ~24% off, comorbidity too common, baseline Cr implausibly high) → you may be trusting a derived file or a stay-wide diagnosis. Go back to raw tables and probe.
5. **A figure disagrees with a table** (e.g., cumulative incidence ~2× the binary rate) → informative discharge censoring; use naive fixed-window, not KM.
6. **You're about to lead with the main effect** (albumin→AKI OR ~2.5) → that is the v2 trap. The headline is the eGFR interaction. Confirm with the supervisor before foregrounding any main effect.
7. **An external (IUH) OR is huge with a tiny denominator** → sparse-data artifact. Report, do not interpret.
8. **A frozen decision "should" change** → it doesn't change without a supervisor-approved journal entry first.

---

## 8. Definition of done (per phase)

A phase is done when: the gate criteria are all ✅ (or the ❌ are logged as accepted limitations by the
supervisor); the required probes are committed with outputs in `JOURNAL.md`; aggregate results are
committed and patient-level files are confirmed HPC-only; the state block is written; and the STOP line
is posted. Then — and only then — wait for `APPROVED: Phase N`.
