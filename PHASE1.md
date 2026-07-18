# PHASE1.md — Phase 1 Work Order (ETL & cohort, MIMIC + eICU on Tempest)

**Owner:** Codex. **Supervisor:** Claude. **Status:** supervisor-proposed draft — Codex critiques and
refines this in Phase 0 (`JOURNAL.md` Entry 1) *before* executing anything here.

> **Supervisor-approved revisions (2026-07-18) — `JOURNAL.md` Entry 1 + Entry 2 are authoritative where
> they differ from this draft.** Accepted: (1) run ETL with **explicit per-DB commands**
> (`01b_covariates.py` needs `{mimic|eicu}`; `01c_endpoints.py` is MIMIC-only) — the chained T3 command
> below is superseded. (2) **Default-deny `.gitignore`** excluding `llm_qc_spotcheck.txt` and all
> `*_pairs_*` (codex.md §4). (3) **`probe_nopost_cr` moves to Phase 3** (needs matched pairs/index T0);
> Phase 1 runs `probe_alb_ascertainment`, `probe_baseline_anchor`, `probe_alb_cat_coverage` with
> pass/fail assertions. (4) **No static `alb_cat`** — preserve timestamped albumin+Cr; derive at index
> T0 in Phase 3. (5) **Canonical baseline** emitted in ETL (last pre-exposure Cr + tier + timestamp;
> never post-CPB; eGFR from it). (6) `alb_cat` cut = **3.5 g/dL** default (Yan to confirm).

This expands `PLAN.md §4 → Phase 1`. Goal: analysis-ready per-patient tables with a defensible
pre-exposure baseline and audited first-albumin ascertainment, plus the repo hygiene that lets the
engine run reproducibly. The primary/sensitivity *ordering* is not needed for Phase 1 ETL (the cohort
tables serve both designs), so **Phase 1 can run before Yan's sign-off**; that sign-off blocks the
Phase 2 freeze, not the ETL.

## Scope boundary (do NOT do these in Phase 1)
- Do **not** rename `02_psm_v2.R` yet (that is the Phase 2 freeze action, tied to the Yan sign-off).
- Do **not** freeze `STUDY_DESIGN.md` (Phase 2).
- Do **not** run PSM/HTE (Phases 3–4).
- Do **not** add `alb_cat` to the PS model spec yet — Phase 1 only *builds and audits* the column; it enters the frozen PS at Phase 2.

## Preconditions
- Phase 0 approved in `JOURNAL.md` (drift inventory validated, plan critiqued, Phase 1 plan posted).
- On `main`; backup `backup/pre-engine-realign-2026-07-18` exists.
- Tempest reachable: `ssh tempest 'cd ~/albumin_aki && git pull'`.

## Tasks

### T1 — Repo hygiene (local, then push)
1. Commit the untracked-but-wanted files that belong in history: `.gitignore`, `README.md`,
   `CODEX_LLM_TASK.md`, `10_nlp.py`, `yan_protocol_gap_analysis.md`, `.pre-commit-config.yaml`
   (leave `.Rhistory` out — add it to `.gitignore`).
2. **Fix `.gitignore`** so aggregate truth is committable while patient-level stays out. Proposed:
   ```gitignore
   # patient-level / intermediate (PhysioNet DUA — never commit)
   results/did_pairs_*.csv
   results/did_all_*.csv
   results/did_cr_all_*.csv
   results/did_labs_all_*.csv
   results/strm_*.csv
   results/labs_ext_*.csv
   results/cr_variants_*.csv
   results/_llm_checkpoint.csv
   results/llm_endpoints_*.csv
   logs/
   __pycache__/
   *.pyc
   .DS_Store
   .idea/
   .Rhistory
   # aggregate truth IS committed — force-add explicitly:
   #   git add -f results/did_riskset_*.csv results/did_binary_*.csv results/egfr_stages_*.csv \
   #             results/psm_balance_*.csv results/did_hte_*.csv results/did_hte_interact_*.csv \
   #             results/did_consort_*.csv results/llm_qc_*.txt
   ```
   Confirm the exact aggregate filenames by reading what `02_psm.R` / `03_hte.R` actually write before committing (do not guess the stems).

### T2 — Build and audit `alb_cat` (the trigger-lab covariate)
- In `00_config.py`, add `ALB_LOW_CUT` with a documented default of **3.5 g/dL** (flag as a Yan
  DECISION NEEDED — see `PLAN.md §7.5`).
- Derive `alb_cat` from `peri_admission_alb` with three levels: `normal` (≥ cut), `low` (< cut),
  `missing` (no peri-admission albumin). This mirrors mg_aki's `mg_cat`. Build it where the other
  per-patient covariates are assembled (confirm the right file: likely `01b_covariates.py` output or a
  derived column in `02_psm.R` — read both and pick the canonical spot; do not create it twice).
- **Do not** put it in the PS spec yet (Phase 2). Phase 1 only produces the column and its coverage.

### T3 — Run the ETL on Tempest
```bash
ssh tempest 'cd ~/albumin_aki && git pull && module purge && \
  module load Python/3.10.8-GCCcore-12.2.0 && source ~/alcrx/.venv/bin/activate && \
  python 01_etl.py 2>&1 | tee logs/01_etl.log && \
  python 01b_covariates.py 2>&1 | tee logs/01b.log && \
  python 01c_endpoints.py 2>&1 | tee logs/01c.log && \
  python qc_probe.py 2>&1 | tee logs/qc_probe.log'
```
Confirm each script's real CLI contract from its header first (some take a `db` arg, some loop both).

### T4 — Probes (one question each; commit with output pasted into `JOURNAL.md`)
- `probe_alb_ascertainment.py` — first-albumin T0 built from raw `inputevents` (`220862`/`220864`) and eICU text patterns; how many treated, distribution of `alb_offset_h`, % with albumin >24h (late/rescue). Confirms exposure is from raw source, not a derived file (LESSONS.md §4).
- `probe_baseline_anchor.py` — baseline Cr timing vs T0; % relying on each fallback tier; sanity of baseline Cr distribution (no CPB-inflated values; LESSONS.md §5).
- `probe_nopost_cr.R` — fraction with valid baseline but no post-T0 Cr, **by arm** (differential? drives the non-event coding; LESSONS.md §8).
- `probe_alb_cat_coverage.py` — `alb_cat` level counts by arm and by database; confirm `missing` dominance is as expected (~26% MIMIC coverage).

### T5 — CONSORT
- Confirm `01_etl.py` emits `did_consort_{db}.csv` (build/patch it if absent). Every exclusion count from raw rows → analysis cohort must be machine-emitted, not hand-counted.

## Gate (Phase 1 → 2) — all must be ✅ or logged as an accepted limitation
- Baseline Cr anchored to the correct pre-exposure window; fallback reliance recorded in CONSORT.
- First-albumin T0 defined from raw source tables Codex inspected (not a derived convenience file).
- `qc_probe.py` runs clean; all four Phase 1 probes committed with outputs in `JOURNAL.md`.
- `alb_cat` built and its coverage audited (not yet in the PS).
- CONSORT counts emitted by the ETL for MIMIC and eICU.
- `.gitignore` fixed; aggregate results committable; no patient-level file staged.

## Deliverables
- Aggregate (committed): `did_consort_mimic.csv`, `did_consort_eicu.csv`; probe outputs (in `JOURNAL.md` and as committed scripts).
- Patient-level (HPC only, gitignored): `did_all_*`, `did_cr_all_*`, `did_labs_all_*`, `strm_*`, `labs_ext_*`.
- `JOURNAL.md` Entry 2 (Phase 1 gate report) + STOP.
