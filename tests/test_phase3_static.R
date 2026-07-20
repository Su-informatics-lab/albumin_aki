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
  identical(MAIN_PS_SET, "S2_PLUS_AORTIC"),
  length(main_ps_vars("mimic", "pooled")) == 23,
  identical(
    main_ps_vars("mimic", "pooled"),
    c(COVARIATE_SETS$S2, "surg_aortic")
  ),
  identical(
    main_ps_vars("mimic", "egfr"),
    setdiff(c(COVARIATE_SETS$S2, "surg_aortic"), c("egfr", "ckd"))
  ),
  identical(main_ps_vars("eicu", "pooled"), c(PS_BASE, "surg_aortic")),
  !any(c("vaso_at_t0", "map_before_t0", "vent_at_t0") %in%
         main_ps_vars("eicu", "pooled")),
  !any(c("egfr", "ckd") %in% main_ps_vars("eicu", "egfr")),
  identical(
    main_ps_vars("iuh", "pooled"),
    c(COVARIATE_SETS$S2, "surg_aortic")
  ),
  !any(c("egfr", "ckd") %in%
         main_ps_vars("iuh", "egfr_reported")),
  identical(
    main_ps_vars("mimic", "pooled", "s2_no_aortic"),
    COVARIATE_SETS$S2
  ),
  identical(
    main_ps_vars("eicu", "pooled", "s2_no_aortic"),
    PS_BASE
  ),
  identical(result_suffix("pooled", "mimic"), "pooled_mimic"),
  identical(
    result_suffix("pooled", "mimic", "s2_no_aortic"),
    "pooled_s2_no_aortic_mimic"
  )
)

# The baseline-at-T0 display unification is label-only: internal variables and
# their strict-before selector remain unchanged, while exported labels have one
# explicit convention and no mixed last_ / *_before_t0 / *_at_t0 wording.
timing_fixture <- data.frame(
  pid = c(1, 1, 2),
  lab_name = "hemoglobin",
  value = c(10, 20, 12),
  offset_h = c(4, 5, 4)
)
timing_index <- data.frame(pid = c(1, 2), index_h = c(5, 5))
timing_value <- last_value_before_index(
  timing_fixture, timing_index, lab_name = "hemoglobin"
)
stopifnot(timing_value["1"] == 10, timing_value["2"] == 12)
timing_codes <- c(
  "last_lactate", "last_heartrate", "last_hemoglobin", "alb_cat",
  "vaso_at_t0", "map_before_t0", "vent_at_t0"
)
timing_labels <- covariate_display_label(timing_codes)
stopifnot(
  all(grepl("^baseline \\(at ICU T0\\):", timing_labels)),
  !any(grepl("last_|_before_t0|_at_t0|@T0", timing_labels))
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
  interaction <- pair_interaction_or_rd(
    rep(c(0, 1), each = 50),
    c(rep(0, 75), rep(1, 25)),
    rep(c(0, 1), each = 50)
  )
  stopifnot(
    interaction$n == 100,
    is.finite(interaction$interaction_or),
    is.finite(interaction$interaction_rd),
    interaction$or_ci_lo < interaction$interaction_or,
    interaction$or_ci_hi > interaction$interaction_or
  )
}

cat(
  "PASS: non-event coding, two-reference baseline/tie rule, ",
  "within-stratum matching, frozen v3.3 S2+aortic database contract, ",
  "strict-before value-preserving labels, fixed mortality, OR/RD utility\n",
  sep = ""
)
