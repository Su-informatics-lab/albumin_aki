#!/usr/bin/env Rscript

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(dirname(normalizePath(file_arg)))
source(file.path(repo, "R", "causal_helpers.R"))

# Missing post-T0 Cr is a non-event for SCr outcomes, while new RRT remains
# available only in the labeled secondary.
empty_cr <- data.frame(labresult = numeric(), offset_h = numeric())
out <- scr_kdigo_outcomes(empty_cr, baseline = 1, t0_h = 10)
stopifnot(all(out[c(
  "aki1_48h", "aki2_48h", "aki3_48h",
  "aki1_7d", "aki2_7d", "aki3_7d"
)] == 0L))
stopifnot(out["nopost_48h"] == 1L, out["nopost_7d"] == 1L)
out_rrt <- scr_kdigo_outcomes(
  empty_cr, baseline = 1, t0_h = 10, rrt_offset_h = 20
)
stopifnot(out_rrt["aki3_48h"] == 0L, out_rrt["aki2_rrt_48h"] == 1L)

# Baseline is last strictly pre-T0; tied selected timestamps use maximum Cr.
fixture <- data.frame(
  labresult = c(0.8, 1.0, 1.3, 9.0),
  offset_h = c(1, 5, 5, 10)
)
baseline <- max_at_latest_before(fixture, t0_h = 10)
stopifnot(baseline["value"] == 1.3, baseline["offset_h"] == 5)
fallback <- max_at_latest_before(
  empty_cr, t0_h = 2, fallback_value = 0.9, fallback_offset = -1
)
stopifnot(fallback["value"] == 0.9, fallback["offset_h"] == -1)

# The stratified risk-set predicate cannot admit a different eGFR stratum.
candidate <- egfr_stratum(c(100, 75, 45, NA))
stopifnot(identical(
  eligible_same_stratum(candidate, "G2"),
  c(FALSE, TRUE, FALSE, FALSE)
))

cat("PASS: non-event coding, two-reference baseline/tie rule, within-stratum matching\n")
