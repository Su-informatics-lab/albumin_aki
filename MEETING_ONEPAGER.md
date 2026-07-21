# Albumin & AKI after cardiac surgery — clinician briefing (post-debug)

**For:** Dr. Su, Dr. Yan, Dr. Eadon, Dr. Meng · **From:** Haining (Su Lab) · **Date:** 2026-07-20
**Status:** analysis closed at v3.3; a strategic/framing decision is needed.

---

## Bottom line (candid)

Across three ICU databases, **we cannot defend a causal, generalizable "albumin → AKI" claim.** The one
strong signal (MIMIC) is **not our measurement artifact** — it survives an exhaustive ascertainment
audit — but it is **most consistent with confounding by indication plus single-center practice**, and it
**does not replicate** cleanly in eICU or IUH. This is a rigorous *cautionary* result, not a positive
finding.

---

## The evidence in three layers

**1. The association (MIMIC, risk-set PSM + doubly-robust).** Albumin is associated with more AKI, graded
by severity: AKI≥1 OR 1.88 [1.71–2.07], +12 pts (48h); AKI≥2 OR 1.97; the effect is strongest at mild
AKI and fades at AKI≥3 and at death.

**2. It is NOT our pipeline's fault (we checked hard).** The AKI/mortality definitions are identical
shared code across all three databases. The MIMIC signal survives creatinine-sampling density,
differential-by-arm surveillance, missing-lab coding, a hemodilution-nadir check, and a scheduled
one-creatinine-per-day rule (OR 1.88 → 1.81–1.87). So "MIMIC's ETL is broken" is ruled out.

**3. But it is not causal or general.**

- **Confounding by indication is large and credible.** Before matching, MIMIC albumin patients are far
  sicker: on vasopressors 58.5% vs 26.0% (SMD 0.70), pre-albumin transfusion 13.6% vs 1.0% (SMD 0.50),
  plus lower MAP and more ventilation. The E-value is ≈ 2.1–2.3 (CI to null ≈ 1.9–2.0) — an unmeasured
  confounder of that strength would erase the result, and a *composite* perioperative-severity/bleeding
  confounder of that size is entirely plausible here.
- **Population-level (IPTW/ATE) analysis gives OR ~1.9 in both MIMIC and eICU — the Gupta cautionary
  framing** — but with unstable weights (MIMIC treated effective n ≈ 926) it restates confounding by
  indication ("patients who receive albumin have higher AKI risk"), not causation. Clinician-suggested
  fixes did not rescue it: lowering the serum-albumin threshold (3.5→3.0→2.5) did not improve balance,
  and stratifying by baseline albumin revealed no credible, replicating effect modifier (as with eGFR).
- **No clean cross-database replication.** eICU AKI≥1 is weak (OR 1.24) and IUH is null (1.14, ns). This
  is not an artifact of eICU's handling: neither correcting its missing-outcome coding (1.32) nor
  recovering the under-extracted MAP covariate and re-adjusting (1.2–1.35) changes it — so eICU's weakness
  is genuine, not our under-adjustment. One large eICU teaching hospital (Northeast) shows a MIMIC-magnitude
  signal (DR OR 3.76), so MIMIC is not uniquely aberrant — but the pooled cross-hospital estimate includes
  null (1.31 [0.86–1.99], I² 71%) and is not independent replication.
- **Mortality points the same way.** Albumin tracks higher mortality in eICU (1.62) and IUH (1.93) but
  not MIMIC — the footprint of sicker patients getting albumin, i.e. residual confounding.

---

## What this means

We did the responsible thing and tried hard to break our own result. It held up as *measurement*, then
failed to hold up as *causation*. The honest scientific statement is: **the apparent albumin–AKI harm in
ICU data is largely confounding by indication and does not replicate across databases** — which is a
genuinely useful message given how many single-database association papers exist and given the long
colloid-vs-crystalloid debate.

## Options (your call, with clinical input)

1. **Cautionary / non-replication paper.** Report the multi-database non-replication + E-value +
   surveillance-robustness as a rigorous methods-and-caution contribution (e.g. *Critical Care*,
   *J Clin Epidemiol*, *npj Digital Medicine*). Honest and publishable; leads with what we can defend.
2. **Target-trial emulation with an active crystalloid comparator**, restricted to resuscitation-indicated
   patients. This is the correct causal fix for confounding by indication — but it is a *new* study, not a
   rescue of this one.
3. **Shelve albumin→AKI** and redirect the engine to a different exposure/outcome.

Recommendation: option 1 is the honest, near-term deliverable; option 2 is the right *next* study if the
team wants a causal answer.

## Decisions I need

1. Which direction — cautionary paper (1), TTE pivot (2), or shelve (3)?
2. Dr. Su / Dr. Yan clinical read: is MIMIC/BIDMC albumin practice idiosyncratic enough (sicker,
   bleeding, later timing) that confounding by indication is the leading explanation — or is there a
   real effect worth the TTE?
3. If option 1: target journal (sets length/format).

*All numbers from committed aggregate CSVs; patient-level data remain on Tempest/Quartz. Full audit trail
in `JOURNAL.md` Entries 27–32.*
