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
