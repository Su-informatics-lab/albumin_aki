#!/usr/bin/env Rscript

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(dirname(normalizePath(file_arg)))
source(file.path(repo, "R", "causal_helpers.R"))
source(file.path(repo, "R", "covariate_registry.R"))

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
stopifnot(
  identical(names(COVARIATE_SETS), paste0("S", 0:6)),
  all(vapply(seq_len(6), function(i) {
    all(COVARIATE_SETS[[i]] %in% COVARIATE_SETS[[i + 1]])
  }, logical(1))),
  identical(setdiff(COVARIATE_SETS$S1, COVARIATE_SETS$S0), "vaso_at_t0"),
  identical(
    setdiff(COVARIATE_SETS$S2, COVARIATE_SETS$S1),
    c("map_before_t0", "vent_at_t0")
  ),
  identical(
    setdiff(COVARIATE_SETS$S4, COVARIATE_SETS$S3),
    c("rbc_before_t0", "crystalloid_before_t0", "urine_before_t0")
  ),
  !any(c(
    "calcium", "last_calcium", "adm_emergency", "continuous_albumin",
    "sofa", "apache", "lvef"
  ) %in% unlist(COVARIATE_SETS)),
  !any(grepl("post|outcome|death|rrt|intraop", unlist(COVARIATE_SETS)))
)
stopifnot(
  identical(MAIN_PS_SET, "S2"),
  identical(main_ps_vars("mimic", "pooled"), COVARIATE_SETS$S2),
  identical(
    main_ps_vars("mimic", "egfr"),
    setdiff(COVARIATE_SETS$S2, c("egfr", "ckd"))
  ),
  identical(main_ps_vars("eicu", "pooled"), c(PS_BASE, "vent_at_t0")),
  !any(c("vaso_at_t0", "map_before_t0") %in%
         main_ps_vars("eicu", "pooled")),
  !any(c("egfr", "ckd") %in% main_ps_vars("eicu", "egfr"))
)

death <- fixed_window_death(c(NA, 12, 70, 200), rep(10, 4), 48)
stopifnot(identical(death, c(0L, 1L, 0L, 0L)))

if (requireNamespace("sandwich", quietly = TRUE) &&
    requireNamespace("lmtest", quietly = TRUE)) {
  estimate <- pair_or_rd(
    c(rep(1, 20), rep(0, 80)),
    c(rep(1, 10), rep(0, 90))
  )
  stopifnot(
    is.finite(estimate$or), is.finite(estimate$rd),
    abs(estimate$rd - 0.1) < 1e-12,
    estimate$or_ci_lo < estimate$or,
    estimate$or_ci_hi > estimate$or
  )
}

cat(
  "PASS: non-event coding, two-reference baseline/tie rule, ",
  "within-stratum matching, frozen S2 database contract, ",
  "fixed mortality, OR/RD utility\n",
  sep = ""
)
