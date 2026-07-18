# LESSONS.md — Paid-for lessons from mg_aki, applied to albumin_aki

Every rule below cost real rework in `mg_aki` (six weeks of dead ends, a near desk-rejection) or was
caught only by a probe before a reviewer would have caught it. They are distilled from the
`icu-causal-engine` references (`design-canon.md`, `failure-modes.md`, `self-correction.md`). For each:
the **scar** (what went wrong), the **rule**, and **how albumin_aki applies it**.

The meta-lesson: **the six-week study becomes a three-week study whose result you can defend** — but
only if you keep the discipline below. Speed comes from not repeating these, not from skipping gates.

---

## 1. The pivot: a fragile main effect is not a paper; the effect modification is

**Scar.** mg_aki began as "IV magnesium reduces AKI" — a main effect, OR ~0.75 in one database, null in
the other, significant under some weightings and not others. Defending it (try another estimator, pool
the databases, find the sub-band that stays significant) is analysis-shopping, and a methodologist
reviewer recognizes it on sight. That version had ~15–20% acceptance odds.

**Rule.** Before committing to a headline, ask: is my robust, replicating signal the main effect or the
*modification*? If you are defending a borderline main effect by choice of estimator, stop and reframe.

**albumin_aki.** The v2 landmark headline is a **main effect** (severe AKI OR 2.55). That is the trap.
The replicating, cross-database signal — the one worth a paper — is the **albumin × eGFR interaction**
(memory: OR ~1.2 at eGFR≥90 rising to ~7.8 at eGFR 30–44, interaction P<0.0001). Lead with the
interaction. Report the main effect; do not build the paper on it.

---

## 2. Probe-first: never trust a surprising number

**Scar.** Almost every avoided mg_aki error was caught by a small diagnostic, not by intuition:
`probe_como_pret0.py` (comorbidity contamination <3% but stroke worst), `probe_nopost_cr.R`
(no-post-Cr missingness ~6.3% treated vs ~4.0% control), `probe_competing_risks.py` (CIF ≈ naive, so
no competing-risks machinery needed).

**Rule.** Isolate one question, compute it directly on the data, print the answer with enough context to
decide, commit it as `probe_<question>.{py,R}` with a "not part of the primary pipeline" docstring.

**albumin_aki.** `qc_probe.py` already carries this habit. Add probes for every albumin surprise:
baseline-anchor timing, first-albumin ascertainment, no-post-Cr missingness by arm, `alb_cat` coverage,
eICU vaso/MAP missingness. Model on `mg/probes/`.

---

## 3. One canonical number; no version-suffixed forks

**Scar.** In mg_aki, a script named `04c_fig_km_egfr.py` never produced a KM curve, and
`\includegraphics` pointed at a stale filename — a half-rename left the repo lying about its contents.
Two scripts computing the "same" OR differently is a bug that wastes a reviewer cycle.

**Rule.** One canonical file per job. If two scripts can compute the same quantity, reconcile the
non-canonical one to the canonical one exactly. When a method changes, rename the script **and** its
outputs **and** every downstream reference in the **same commit**. A half-rename is worse than none.

**albumin_aki.** The repo currently has **`02_psm.R` and `02_psm_v2.R`** side by side — the exact
anti-pattern. Fix: `02_psm.R` is the canonical primary (risk-set); `02_psm_v2.R` becomes
`02b_landmark_sensitivity.R` (a different analysis, named for what it computes), with a full sweep of
`run.sh`, SLURM wrappers, `STUDY_DESIGN.md`, and `README.md` in one commit.

---

## 4. Read the actual file; never guess a schema or trust a derived file

**Scar.** mg_aki's IUH cohort silently lost ~1,000 eligible patients because the ETL trusted a derived
`cardiac_surgery_icu.parquet` whose postop filter (`unitin_surg_diff <= 0`) was inverted — ICU stays
*span* surgery, so the filter dropped legitimate patients. The fix was to rebuild from raw
`Procedure.parquet` + ICU-stay tables.

**Rule.** Do not trust a derived file whose filtering logic you did not write and inspect. When a count
is surprising, go back to raw source tables. Read the current file immediately before editing; re-read
after each edit.

**albumin_aki.** Critical for **Phase 7 (IUH on Quartz)** — build from raw tables, not a convenience
parquet. Also for MIMIC/eICU: define albumin exposure from raw `inputevents` / medication tables you
inspected, not a derived exposure file.

---

## 5. Baseline must precede every insult the exposure modifies (surgical contamination)

**Scar.** mg_aki's baseline creatinine was first anchored pre-ICU, which for OR-to-ICU patients captured
intraoperative / post-CPB values inflated by bypass, contaminating the AKI definition. The honest fix
(anchor to the preoperative/admit-window value) *shrank* the cohort and *weakened* the finding
(interaction P .006 → .030) — and was reported anyway.

**Rule.** "Baseline" must precede every physiological insult. Get a clinician to pin the exact timing.
Expect the honest version to be less favorable, and report it.

**albumin_aki.** Anchor baseline Cr to the correct pre-exposure window with a documented fallback,
computed identically for treated and control. Record fallback reliance in CONSORT. State transparently
that MIMIC/eICU "preop" labs are in practice first *postoperative* ICU values (no OR-period data
exists) — this is a limitation, not a bug to hide.

---

## 6. The trigger lab: coarse-categorize, never continuous, never fully drop

**Scar.** Putting serum Mg (the exposure's indication lab) in the mg_aki PS as a continuous term
flattened the effect and produced near-positivity warnings — it had an enormous treated-vs-control SMD
(0.67–0.71) and absorbed the treatment-identifying variation. Entering it as a coarse category
(normal/low/missing) adjusted for indication without emptying calipers.

**Rule.** A near-perfect predictor of treatment does not belong in the PS in continuous form.
Coarse-categorize it (including a "missing" level); excluding it entirely drops indication from the
estimand.

**albumin_aki.** Peri-admission serum albumin is the trigger lab. Current `02_psm.R` **excludes** it
from `primary` and adds it **continuous** in `sens_a` — both wrong for the primary. Fix: build
**`alb_cat`** (normal / low / missing at a Yan-confirmed cut, e.g. 3.5 g/dL) and put it in the primary
PS, mirroring `mg_cat`. The "missing" level is dominant (~26% MIMIC coverage) and correctly absorbs the
unmeasured majority. Keep continuous albumin as the `sens_a` over-adjustment check only.

---

## 7. Risk set = yet-untreated; T0 = administration, not a lab

**Scar.** mg_aki (v7.0) briefly proposed restricting to never-treated controls "to remove the ambiguity"
of a patient appearing in both arms — this changes the estimand to a prevalent ever-vs-never contrast
and reintroduces immortal-time asymmetry. It was reverted.

**Rule.** Controls = everyone not yet treated at the treated patient's T0 (later-treated patients are
valid earlier-time controls). T0 = first exposure administration.

**albumin_aki — the specific confusion to avoid.** The v2 design abandoned the risk set partly on the
belief that a serum-albumin-**lab**-anchored T0 was infeasible (only 7.9% of treated have a pre-infusion
albumin lab). **True, but irrelevant:** the engine anchors T0 on first **administration**, known for
100% of treated. Do not conflate "no pre-infusion albumin lab" with "cannot do risk-set." The lab is the
trigger covariate (`alb_cat`), not the clock.

---

## 8. Missing post-T0 outcome lab → non-event, not dropped (collider)

**Scar.** In mg_aki the AKI rate and OR shifted depending on whether patients with a valid baseline but
no post-T0 creatinine were dropped. Dropping them conditions on a **post-treatment** variable (a
collider), and the missingness is mildly differential by arm (~6.3% treated vs ~4.0% control).

**Rule.** Code missing-post-T0 outcomes as **non-events (0)**, consistently in every outcome script.
Members with no usable baseline stay NA everywhere. If formal informative-censoring handling is ever
wanted, the tool is IPCW at estimation — never a PS covariate.

**albumin_aki.** Apply identically. Ensure `02_psm.R`, `02b_landmark_sensitivity.R`, and `03_hte.R` all
use the same coding so they report identical ORs on the same pairs.

---

## 9. Estimator hygiene: pick the estimand first, don't estimator-shop

**Scar.** mg_aki's near-rejection came from sequential migration to whichever weighting kept the main
effect significant, and from pooling a significant database with a null one to manufacture significance.

**Rule.** PSM+DiD is the primary estimator (a matched, within-pair-differenced estimand). IPTW/AIPW/IPCW
target a *different* estimand (population-weighted ATE) — their agreement or disagreement is **not** a
robustness signal. Keep them archived; never primary, never pooled across databases.

**albumin_aki.** IPTW/overlap-weighting are sensitivity-only. Do not pool MIMIC + eICU into one estimate;
report each database and let the interaction sign replicate across them.

---

## 10. Cumulative incidence in the ICU: naive fixed-window, not Kaplan-Meier

**Scar.** mg_aki's KM cumulative AKI curve read ~34% where the Table 2 binary endpoint said ~17% — KM's
product-limit form wrongly assumes discharged-well patients keep accruing risk on a shrinking risk set
(informative censoring by discharge).

**Rule.** Plot naive empirical cumulative incidence (events≤t / N_total; discharge = event-free
follow-up), which equals the fixed-window binary endpoint. Verify a competing-risks estimator agrees
when death-before-outcome is negligible; annotate the discharge fraction.

**albumin_aki.** Use naive fixed-window for any cumulative-incidence figure. Binary fixed-window ORs are
unaffected — only time-to-event curves are.

---

## 11. SLURM jobs must be hermetic

**Scar.** A leaked interactive Python 3.13 (from an activated venv) collided with R's Python dependency
and broke SLURM R jobs.

**Rule.** `#SBATCH --export=NONE`; `module purge` and load the exact toolchain inside the job. Never
rely on the login-shell environment. `module purge` between Python and R always.

**albumin_aki.** Copy `mg/run_psm.sh` (which already has `--export=NONE`) as the SLURM template; the repo
currently has only `run.sh` and needs a proper `*.sbatch`.

---

## 12. Calibrate claims; demote implausibly large effects; report the pattern

**Scar.** mg_aki's eGFR-stratified mortality ORs (0.30–2.41 for an electrolyte) were the single biggest
reviewer attack surface until they were demoted to the supplement. The DiD time course was reported as
"7 of 8 horizons significant," not "significant." When the honest baseline fix weakened the interaction,
that was reported, not reversed.

**Rule.** Foreground only what a skeptical expert will believe. Demote implausibly large secondary
effects to the supplement (keep the full numbers in committed CSVs for the rebuttal). Report the pattern,
not the best number. Tighten hedged language to match evidence strength.

**albumin_aki.** Watch the IUH sparse strata (a huge OR on ~20 vs ~3 events is an artifact — report,
don't interpret). Keep the mortality falsification in a table, never narrated. Calibrate the bleeding /
support / AKI language to the evidence in each database.

---

## 13. Falsification + positive control + cross-database replication, built in from Phase 0

**Scar / save.** mg_aki's mortality falsification stayed null (supporting adequate confounding control),
and it reproduced Xiong 2023's adjusted OR (1.47 vs 1.46) as a positive control — validating the whole
pipeline. Its main effect *failing* to replicate across databases is exactly what forced the (correct)
pivot to the effect-modification story.

**Rule.** Choose a falsification endpoint (the exposure should not affect it) and a positive control (a
known result you expect to reproduce) in Phase 0. Run the identical engine in ≥2 databases and, where
possible, an external site. Disagreement is informative.

**albumin_aki.** Falsification = mortality (v2 already null: OR 0.90, P 0.55 — good). Positive control =
ALBICS bleeding/support harm direction (confirm the expected magnitude with the team; do not fabricate).
Cross-database = MIMIC + eICU; external = IUH (supplement-level).

---

## The short version

Pre-specify the modifier (eGFR) and the controls (yet-untreated). Anchor T0 on administration, not a lab.
Coarse-categorize the trigger lab. Probe every surprise. Keep one canonical number and no `_v2` forks.
Read the real file; rebuild from raw tables. Missing-post-outcome = non-event. One estimand, no
estimator-shopping. Naive fixed-window, not KM. Hermetic SLURM. Falsify, positive-control, replicate.
Report the pattern, demote the implausible, freeze and record why.
