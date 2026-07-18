# AGENTS.md

This repository runs under a supervised, gated agent workflow. **Before doing anything, read, in order:**

1. `codex.md` — your operating manual (roles, environment, phase-gated workflow, guard rails, reporting).
2. `PLAN.md` — the authoritative study design and phase-by-phase plan.
3. `LESSONS.md` — the mistakes these rules exist to prevent (read before you're tempted to skip a rule).

Then report progress in `JOURNAL.md` (append-only) and **STOP at each phase gate** for supervisor
approval, exactly as `codex.md` specifies. Do not start a phase before the previous gate is approved,
and never change a frozen decision without a supervisor-approved journal entry first.

The design engine is `icu-causal-engine`; its `references/` (design-canon, failure-modes,
self-correction) are the law where this repo is silent.
