#!/usr/bin/env Rscript
# Aggregate-only guard probe for the Entry-18c HTE sweep.
# This does not alter any outcome, match, model, or patient-level artifact.

RESULTS <- path.expand("~/albumin_aki/results")
pairs <- read.csv(
  file.path(RESULTS, "did_pairs_primary_yet_untreated_pooled_mimic.csv"),
  stringsAsFactors = FALSE
)
kdigo <- read.csv(file.path(RESULTS, "hte_probe_kdigo_mimic.csv"),
                  stringsAsFactors = FALSE)
step1 <- read.csv(file.path(RESULTS, "hte_sweep_step1_tests_mimic.csv"),
                  stringsAsFactors = FALSE)

canonical_n <- c(
  `48` = sum(!is.na(pairs$aki1_48h_trt) & !is.na(pairs$aki1_48h_ctl)),
  `168` = sum(!is.na(pairs$aki1_7d_trt) & !is.na(pairs$aki1_7d_ctl))
)
pf_n <- setNames(
  kdigo$n[kdigo$component == "effect" &
            kdigo$definition == "absolute_delta_ge_0.3"],
  kdigo$horizon_h[kdigo$component == "effect" &
                    kdigo$definition == "absolute_delta_ge_0.3"]
)

ctl_tab <- table(pairs$ctl_pid)
rows <- data.frame(
  check = c(
    "canonical_complete_pairs_48h",
    "canonical_complete_pairs_7d",
    "p_f_pairs_48h",
    "p_f_pairs_7d",
    "p_f_excess_pairs_48h",
    "p_f_excess_pairs_7d",
    "matched_pairs",
    "unique_controls",
    "controls_reused",
    "max_control_reuse",
    "step1_tests",
    "step1_missing_or_global_p",
    "step1_missing_rd_global_p"
  ),
  value = c(
    canonical_n["48"], canonical_n["168"], pf_n["48"], pf_n["168"],
    pf_n["48"] - canonical_n["48"], pf_n["168"] - canonical_n["168"],
    nrow(pairs), length(ctl_tab), sum(ctl_tab > 1), max(ctl_tab),
    nrow(step1), sum(is.na(step1$or_global_p)), sum(is.na(step1$rd_global_p))
  ),
  interpretation = c(
    "frozen crossover-censored denominator",
    "frozen crossover-censored denominator",
    "current P-F denominator",
    "current P-F denominator",
    "should be zero if P-F preserves frozen censoring",
    "should be zero if P-F preserves frozen censoring",
    "frozen matched pairs",
    "matching with replacement",
    "random pair folds can place a reused control in multiple folds",
    "random pair folds can leak a repeated control outcome",
    "expected 24 tests x 4 outcomes = 96",
    "should be zero",
    "should be zero"
  ),
  stringsAsFactors = FALSE
)

write.csv(rows, file.path(RESULTS, "hte_probe_integrity_mimic.csv"),
          row.names = FALSE)
print(rows, row.names = FALSE)
