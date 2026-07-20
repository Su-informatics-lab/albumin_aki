#!/usr/bin/env Rscript
# Read-only Entry-27/29 surveillance/ascertainment probe on frozen pooled pairs.
# No propensity model is fit and no matching is performed.
# Usage: Rscript probe_surveillance_bias.R {mimic|eicu|iuh}

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1 || !(tolower(args[1]) %in% c("mimic", "eicu", "iuh"))) {
  stop("Usage: Rscript probe_surveillance_bias.R {mimic|eicu|iuh}")
}
tag <- tolower(args[1])
db <- toupper(tag)
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
script_dir <- dirname(normalizePath(file_arg))
if (!file.exists(file.path(script_dir, "R", "causal_helpers.R"))) {
  script_dir <- getwd()
}
source(file.path(script_dir, "R", "causal_helpers.R"))
source(file.path(script_dir, "R", "covariate_registry.R"))

RESULTS <- path.expand(Sys.getenv(
  "ALBUMIN_AKI_RESULTS", unset = "~/albumin_aki/results"
))
MIMIC_ROOT <- path.expand(Sys.getenv(
  "MIMIC_ROOT", unset = "~/mg_aki/mimic-iv-3.1"
))
OUTCOMES <- c("aki1_48h", "aki2_48h", "aki1_7d", "aki2_7d")
SEED <- 2026
M_IMP <- 20

safe_read <- function(name) {
  path <- file.path(RESULTS, name)
  if (!file.exists(path)) stop("Missing required frozen input: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

build_main_covariates_probe <- function(all_pts, labs, tag) {
  index_h <- ifelse(
    !is.na(all_pts$alb_offset_h),
    all_pts$alb_offset_h,
    all_pts$cr_ref_early_offset_h
  )
  index <- data.frame(pid = all_pts$pid, index_h = index_h)
  for (lab in c("albumin", "lactate", "heartrate", "hemoglobin")) {
    values <- last_value_before_index(labs, index, lab_name = lab)
    all_pts[[paste0("last_", lab)]] <- values[as.character(all_pts$pid)]
  }
  all_pts$last_lactate_missing <- as.integer(is.na(all_pts$last_lactate))
  all_pts$alb_cat <- factor(
    ifelse(
      is.na(all_pts$last_albumin), "missing",
      ifelse(all_pts$last_albumin < 3.5, "low", "normal")
    ),
    levels = c("normal", "low", "missing")
  )
  surg <- safe_read(sprintf("surg_%s.csv", tag))
  all_pts$surg_aortic <- as.integer(
    surg$surg_aortic[match(all_pts$pid, surg$pid)]
  )
  all_pts$surg_aortic[is.na(all_pts$surg_aortic)] <- 0L
  if (tag %in% c("mimic", "iuh")) {
    vent <- safe_read(sprintf("strm_vent_%s.csv", tag))
    vaso <- safe_read(sprintf("strm_vaso_%s.csv", tag))
    map_stream <- safe_read(sprintf("strm_map_%s.csv", tag))
    all_pts$vent_at_t0 <- state_at_index(vent, index)[as.character(all_pts$pid)]
    all_pts$vaso_at_t0 <- state_at_index(vaso, index)[as.character(all_pts$pid)]
    map_values <- last_value_before_index(
      transform(map_stream, value = map), index, value_col = "value"
    )
    all_pts$map_before_t0 <- map_values[as.character(all_pts$pid)]
  }
  all_pts
}

# Reproduce the first completed covariate set used by the frozen run without
# fitting a PS. This is needed only to apply the already-triggered DR correction.
complete_frozen_covariates <- function(dat, vars) {
  numeric_vars <- vars[
    !vapply(dat[vars], function(x) is.factor(x) || is.character(x), logical(1))
  ]
  impute_vars <- numeric_vars[
    vapply(numeric_vars, function(v) any(is.na(dat[[v]])), logical(1))
  ]
  if (length(impute_vars)) {
    base <- dat[, c("treated", numeric_vars), drop = FALSE]
    methods <- rep("", ncol(base))
    names(methods) <- names(base)
    methods[impute_vars] <- "pmm"
    set.seed(SEED)
    imp <- mice(
      base, m = M_IMP, method = methods, maxit = 10, printFlag = FALSE
    )
    completed <- complete(imp, 1)
    dat[numeric_vars] <- completed[numeric_vars]
  }
  dat
}

post_cr <- function(cr_pt, t0, horizon) {
  if (is.null(cr_pt) || !nrow(cr_pt)) {
    return(data.frame(labresult = numeric(), offset_h = numeric()))
  }
  cr_pt[
    !is.na(cr_pt$labresult) & !is.na(cr_pt$offset_h) &
      cr_pt$offset_h > t0 & cr_pt$offset_h <= t0 + horizon,
    c("labresult", "offset_h"), drop = FALSE
  ]
}

# "One per day" is operationalized identically in all databases as one peak in
# each T0-anchored 24-hour follow-up day; wall-clock dates are unavailable in
# the common eICU offset schema. Peak selection preserves any-threshold events.
daily_peak_cr <- function(cr_pt, t0) {
  x <- post_cr(cr_pt, t0, 168)
  if (!nrow(x)) return(x)
  x$day <- pmin(7L, floor((x$offset_h - t0 - 1e-10) / 24) + 1L)
  rows <- lapply(split(x, x$day), function(z) {
    peak <- max(z$labresult, na.rm = TRUE)
    at_peak <- z[z$labresult == peak, , drop = FALSE]
    at_peak[which.min(at_peak$offset_h), c("labresult", "offset_h"), drop = FALSE]
  })
  do.call(rbind, rows)
}

collapse_timestamp_ties <- function(x) {
  if (!nrow(x)) return(x)
  x <- x[order(x$offset_h, -x$labresult), , drop = FALSE]
  x[!duplicated(x$offset_h), c("labresult", "offset_h"), drop = FALSE]
}

# Entry 29 genuinely limits surveillance to one predesignated draw per
# T0-anchored day. The closest-anchor draw is chosen within its corresponding
# day, so the same draw cannot be reused at adjacent anchors. Exact-time ties
# retain the frozen max-Cr rule; equal anchor distances retain the earlier time.
scheduled_daily_cr <- function(cr_pt, t0, rule) {
  stopifnot(rule %in% c("closest_anchor", "first_of_day"))
  x <- collapse_timestamp_ties(post_cr(cr_pt, t0, 168))
  if (!nrow(x)) return(x)
  x$day <- pmin(7L, floor((x$offset_h - t0 - 1e-10) / 24) + 1L)
  rows <- lapply(split(x, x$day), function(z) {
    z <- z[order(z$offset_h), , drop = FALSE]
    if (rule == "first_of_day") {
      return(z[1, c("labresult", "offset_h"), drop = FALSE])
    }
    anchor <- t0 + 24 * z$day[1]
    distance <- abs(z$offset_h - anchor)
    z[order(distance, z$offset_h)[1], c("labresult", "offset_h"), drop = FALSE]
  })
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

measurement_hits <- function(cr_selected, baseline, t0, outcome) {
  horizon <- if (grepl("48h", outcome)) 48 else 168
  x <- post_cr(cr_selected, t0, horizon)
  if (!nrow(x) || is.na(baseline) || baseline <= 0) {
    return(list(x = x, hit = logical(nrow(x))))
  }
  x <- collapse_timestamp_ties(x)
  rel_h <- x$offset_h - t0
  delta <- x$labresult - baseline
  ratio <- x$labresult / baseline
  if (grepl("^aki1_", outcome)) {
    hit <- (delta >= 0.3 & rel_h <= 48) | ratio >= 1.5
  } else if (grepl("^aki2_", outcome)) {
    hit <- ratio >= 2
  } else {
    stop("Unsupported transient-blip outcome: ", outcome)
  }
  list(x = x, hit = hit)
}

# A flag is a confirmed isolated transient when exactly one selected value
# crosses the outcome threshold and it is followed by a selected value below
# threshold. The preceding comparison is the prior selected draw, or the
# unchanged baseline for the first post-T0 draw.
isolated_blip <- function(cr_selected, baseline, t0, outcome) {
  z <- measurement_hits(cr_selected, baseline, t0, outcome)
  if (sum(z$hit) != 1L) return(0L)
  j <- which(z$hit)
  if (j >= length(z$hit)) return(0L)
  left_below <- if (j == 1L) TRUE else !z$hit[j - 1L]
  right_below <- !z$hit[j + 1L]
  as.integer(left_below && right_below)
}

summarize_counts <- function(x) {
  data.frame(
    n = sum(!is.na(x)),
    q25 = as.numeric(quantile(x, 0.25, na.rm = TRUE)),
    median = median(x, na.rm = TRUE),
    q75 = as.numeric(quantile(x, 0.75, na.rm = TRUE)),
    mean = mean(x, na.rm = TRUE)
  )
}

estimate_outcomes <- function(pairs, outcomes, counts, all_pts, violations,
                              schemes = c(
                                "native", "daily_peak", "both_members_ge3_cr"
                              )) {
  rows <- list()
  methods <- c("psm", if (length(violations)) "dr")
  for (scheme in schemes) {
    for (outcome in OUTCOMES) {
      y_t <- outcomes[[paste0(scheme, "_", outcome, "_trt")]]
      y_c <- outcomes[[paste0(scheme, "_", outcome, "_ctl")]]
      for (method in methods) {
        adj_t <- adj_c <- NULL
        if (method == "dr") {
          adj_t <- all_pts[pairs$trt_idx, violations, drop = FALSE]
          adj_c <- all_pts[pairs$ctl_idx, violations, drop = FALSE]
        }
        est <- pair_or_rd(y_t, y_c, adj_t, adj_c)
        valid <- !is.na(y_t) & !is.na(y_c)
        rows[[length(rows) + 1L]] <- cbind(
          data.frame(
            db = db, sampling_scheme = scheme, outcome = outcome,
            method = method,
            events_trt = sum(y_t[valid]), events_ctl = sum(y_c[valid]),
            sparse_lt20 = sum(y_t[valid]) < 20 || sum(y_c[valid]) < 20,
            stringsAsFactors = FALSE
          ),
          est
        )
      }
    }
  }
  do.call(rbind, rows)
}

all_pts <- safe_read(sprintf("did_all_%s.csv", tag))
pairs <- safe_read(sprintf(
  "did_pairs_primary_yet_untreated_pooled_%s.csv", tag
))
cr_all <- safe_read(sprintf("did_cr_all_%s.csv", tag))
labs <- safe_read(sprintf("did_labs_all_%s.csv", tag))
cr_id <- if ("patientunitstayid" %in% names(cr_all)) {
  "patientunitstayid"
} else {
  "stay_id"
}
lab_id <- if ("patientunitstayid" %in% names(labs)) {
  "patientunitstayid"
} else {
  "stay_id"
}
cr_all$pid <- cr_all[[cr_id]]
labs$pid <- labs[[lab_id]]
cr_all <- cr_all[order(cr_all$pid, cr_all$offset_h, -cr_all$labresult), ]
cr_list <- split(cr_all[, c("labresult", "offset_h")], cr_all$pid)

all_pts <- build_main_covariates_probe(all_pts, labs, tag)
ps_vars <- main_ps_vars(tag, "pooled", "primary")
all_pts <- complete_frozen_covariates(all_pts, ps_vars)
balance <- safe_read(sprintf("psm_balance_pooled_%s.csv", tag))
violations <- balance$variable_code[balance$stratum == "Overall" & balance$smd > 0.1]
canonical <- safe_read(sprintf("did_binary_pooled_%s.csv", tag))

n_pairs <- nrow(pairs)
count48_t <- count48_c <- count7_t <- count7_c <- integer(n_pairs)
daily <- setNames(
  replicate(length(OUTCOMES) * 2, integer(n_pairs), simplify = FALSE),
  as.vector(outer(OUTCOMES, c("_trt", "_ctl"), paste0))
)
LIMITED_SCHEMES <- c("closest_anchor", "first_of_day")
limited_names <- as.vector(outer(
  as.vector(outer(LIMITED_SCHEMES, OUTCOMES, paste, sep = "_")),
  c("_trt", "_ctl"), paste0
))
limited <- setNames(
  replicate(length(limited_names), integer(n_pairs), simplify = FALSE),
  limited_names
)
blip <- setNames(
  replicate(
    length(c("native", LIMITED_SCHEMES)) * length(OUTCOMES) * 2,
    integer(n_pairs), simplify = FALSE
  ),
  as.vector(outer(
    as.vector(outer(c("native", LIMITED_SCHEMES), OUTCOMES, paste, sep = "_")),
    c("_trt", "_ctl"), paste0
  ))
)

for (i in seq_len(n_pairs)) {
  t0 <- pairs$t0[i]
  tp <- as.character(pairs$trt_pid[i])
  cp <- as.character(pairs$ctl_pid[i])
  t_cr <- cr_list[[tp]]
  c_cr <- cr_list[[cp]]
  count48_t[i] <- nrow(post_cr(t_cr, t0, 48))
  count48_c[i] <- nrow(post_cr(c_cr, t0, 48))
  count7_t[i] <- nrow(post_cr(t_cr, t0, 168))
  count7_c[i] <- nrow(post_cr(c_cr, t0, 168))
  ot <- scr_kdigo_outcomes(
    daily_peak_cr(t_cr, t0), pairs$baseline_trt[i], t0
  )
  oc <- scr_kdigo_outcomes(
    daily_peak_cr(c_cr, t0), pairs$baseline_ctl[i], t0
  )
  selected_t <- list(
    native = post_cr(t_cr, t0, 168),
    closest_anchor = scheduled_daily_cr(t_cr, t0, "closest_anchor"),
    first_of_day = scheduled_daily_cr(t_cr, t0, "first_of_day")
  )
  selected_c <- list(
    native = post_cr(c_cr, t0, 168),
    closest_anchor = scheduled_daily_cr(c_cr, t0, "closest_anchor"),
    first_of_day = scheduled_daily_cr(c_cr, t0, "first_of_day")
  )
  limited_t <- lapply(
    selected_t[LIMITED_SCHEMES], scr_kdigo_outcomes,
    baseline = pairs$baseline_trt[i], t0_h = t0
  )
  limited_c <- lapply(
    selected_c[LIMITED_SCHEMES], scr_kdigo_outcomes,
    baseline = pairs$baseline_ctl[i], t0_h = t0
  )
  for (outcome in OUTCOMES) {
    # Preserve the frozen horizon-specific crossover censor.
    native_t <- pairs[[paste0(outcome, "_trt")]][i]
    native_c <- pairs[[paste0(outcome, "_ctl")]][i]
    daily[[paste0(outcome, "_trt")]][i] <- if (is.na(native_t)) NA else ot[outcome]
    daily[[paste0(outcome, "_ctl")]][i] <- if (is.na(native_c)) NA else oc[outcome]
    for (scheme in LIMITED_SCHEMES) {
      limited[[paste0(scheme, "_", outcome, "_trt")]][i] <-
        if (is.na(native_t)) NA else limited_t[[scheme]][outcome]
      limited[[paste0(scheme, "_", outcome, "_ctl")]][i] <-
        if (is.na(native_c)) NA else limited_c[[scheme]][outcome]
    }
    for (scheme in c("native", LIMITED_SCHEMES)) {
      blip[[paste0(scheme, "_", outcome, "_trt")]][i] <-
        if (is.na(native_t)) NA else isolated_blip(
          selected_t[[scheme]], pairs$baseline_trt[i], t0, outcome
        )
      blip[[paste0(scheme, "_", outcome, "_ctl")]][i] <-
        if (is.na(native_c)) NA else isolated_blip(
          selected_c[[scheme]], pairs$baseline_ctl[i], t0, outcome
        )
    }
  }
}
counts <- list(
  "48h_trt" = count48_t, "48h_ctl" = count48_c,
  "7d_trt" = count7_t, "7d_ctl" = count7_c
)

# Sampling-density aggregate (pair weighted; reused controls retain each pair T0).
density_rows <- list()
for (horizon in c("48h", "7d")) {
  for (arm in c("trt", "ctl")) {
    z <- summarize_counts(counts[[paste0(horizon, "_", arm)]])
    density_rows[[length(density_rows) + 1L]] <- cbind(
      data.frame(
        db = db, population = "frozen_pair_members_pair_weighted",
        horizon = horizon, arm = if (arm == "trt") "treated" else "control"
      ),
      z
    )
  }
}
density <- do.call(rbind, density_rows)
for (horizon in c("48h", "7d")) {
  mt <- density$median[density$horizon == horizon & density$arm == "treated"]
  mc <- density$median[density$horizon == horizon & density$arm == "control"]
  density$treated_control_median_ratio[density$horizon == horizon] <- mt / mc
}

# Native, daily-peak, and >=3-draw-restricted outcomes.
outcome_vectors <- list()
for (outcome in OUTCOMES) {
  suffix <- if (grepl("48h", outcome)) "48h" else "7d"
  nt <- pairs[[paste0(outcome, "_trt")]]
  nc <- pairs[[paste0(outcome, "_ctl")]]
  dt <- daily[[paste0(outcome, "_trt")]]
  dc <- daily[[paste0(outcome, "_ctl")]]
  keep3 <- counts[[paste0(suffix, "_trt")]] >= 3 &
    counts[[paste0(suffix, "_ctl")]] >= 3
  outcome_vectors[[paste0("native_", outcome, "_trt")]] <- nt
  outcome_vectors[[paste0("native_", outcome, "_ctl")]] <- nc
  outcome_vectors[[paste0("daily_peak_", outcome, "_trt")]] <- dt
  outcome_vectors[[paste0("daily_peak_", outcome, "_ctl")]] <- dc
  outcome_vectors[[paste0("both_members_ge3_cr_", outcome, "_trt")]] <-
    ifelse(keep3, nt, NA)
  outcome_vectors[[paste0("both_members_ge3_cr_", outcome, "_ctl")]] <-
    ifelse(keep3, nc, NA)
}
comparison <- estimate_outcomes(
  pairs, outcome_vectors, counts, all_pts, violations
)

# Entry-29 scheduled single-draw-per-day comparison, on the same pairs and
# using the same frozen DR trigger/covariates.
limited_outcome_vectors <- list()
for (outcome in OUTCOMES) {
  limited_outcome_vectors[[paste0("native_", outcome, "_trt")]] <-
    pairs[[paste0(outcome, "_trt")]]
  limited_outcome_vectors[[paste0("native_", outcome, "_ctl")]] <-
    pairs[[paste0(outcome, "_ctl")]]
  for (scheme in LIMITED_SCHEMES) {
    limited_outcome_vectors[[paste0(scheme, "_", outcome, "_trt")]] <-
      limited[[paste0(scheme, "_", outcome, "_trt")]]
    limited_outcome_vectors[[paste0(scheme, "_", outcome, "_ctl")]] <-
      limited[[paste0(scheme, "_", outcome, "_ctl")]]
  }
}
limited_comparison <- estimate_outcomes(
  pairs, limited_outcome_vectors, counts, all_pts, violations,
  schemes = c("native", LIMITED_SCHEMES)
)

blip_rows <- list()
for (scheme in c("native", LIMITED_SCHEMES)) {
  for (outcome in OUTCOMES) {
    for (arm in c("trt", "ctl")) {
      flags <- limited_outcome_vectors[[paste0(scheme, "_", outcome, "_", arm)]]
      isolated <- blip[[paste0(scheme, "_", outcome, "_", arm)]]
      valid <- !is.na(flags)
      n_flags <- sum(flags[valid] == 1L)
      n_isolated <- sum(isolated[valid] == 1L & flags[valid] == 1L)
      blip_rows[[length(blip_rows) + 1L]] <- data.frame(
        db = db, sampling_scheme = scheme, outcome = outcome,
        arm = if (arm == "trt") "treated" else "control",
        n_evaluable = sum(valid), n_aki_flags = n_flags,
        n_isolated_blips = n_isolated,
        isolated_blip_fraction = if (n_flags) n_isolated / n_flags else NA_real_,
        aki_flag_sparse_lt20 = n_flags < 20,
        isolated_blip_sparse_lt20 = n_isolated < 20,
        sparse_lt20 = n_flags < 20 || n_isolated < 20
      )
    }
  }
}
limited_blip <- do.call(rbind, blip_rows)

# Hard integrity gates: daily peaks must preserve peak-any outcomes, and the
# reconstructed frozen DR adjustment must reproduce canonical native results.
daily_identity <- all(vapply(OUTCOMES, function(outcome) {
  nt <- outcome_vectors[[paste0("native_", outcome, "_trt")]]
  nc <- outcome_vectors[[paste0("native_", outcome, "_ctl")]]
  dt <- outcome_vectors[[paste0("daily_peak_", outcome, "_trt")]]
  dc <- outcome_vectors[[paste0("daily_peak_", outcome, "_ctl")]]
  same <- function(x, y) {
    all((is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y))
  }
  same(nt, dt) && same(nc, dc)
}, logical(1)))
if (!daily_identity) stop("Daily-peak outcome identity failed")

reconcile_rows <- list()
for (outcome in OUTCOMES) {
  for (method in c("psm", "dr")) {
    probe <- comparison[
      comparison$sampling_scheme == "native" &
        comparison$outcome == outcome & comparison$method == method,
    ]
    canon <- canonical[
      canonical$stratum == "Overall" & canonical$outcome == outcome &
        canonical$method == method,
    ]
    if (nrow(probe) != 1 || nrow(canon) != 1) {
      stop("Native reconciliation row missing")
    }
    max_diff <- max(
      abs(c(
        probe$or - canon$or,
        probe$rd - canon$rd,
        probe$or_ci_lo - canon$or_ci_lo,
        probe$or_ci_hi - canon$or_ci_hi,
        probe$rd_ci_lo - canon$rd_ci_lo,
        probe$rd_ci_hi - canon$rd_ci_hi
      )),
      na.rm = TRUE
    )
    reconcile_rows[[length(reconcile_rows) + 1L]] <- data.frame(
      db = db, outcome = outcome, method = method,
      max_absolute_difference = max_diff,
      pass = max_diff < 1e-10
    )
  }
}
reconciliation <- do.call(rbind, reconcile_rows)
if (!all(reconciliation$pass)) stop("Frozen native estimate reconciliation failed")

limited_native <- limited_comparison[
  limited_comparison$sampling_scheme == "native",
]
comparison_native <- comparison[comparison$sampling_scheme == "native",]
limited_native <- limited_native[
  order(limited_native$outcome, limited_native$method),
]
comparison_native <- comparison_native[
  order(comparison_native$outcome, comparison_native$method),
]
numeric_estimates <- c(
  "events_trt", "events_ctl", "n", "rate_trt", "rate_ctl", "or",
  "or_ci_lo", "or_ci_hi", "or_p", "rd", "rd_ci_lo", "rd_ci_hi", "rd_p"
)
if (
  nrow(limited_native) != nrow(comparison_native) ||
    max(abs(
      as.matrix(limited_native[numeric_estimates]) -
        as.matrix(comparison_native[numeric_estimates])
    ), na.rm = TRUE) > 1e-12
) {
  stop("Entry-29 native estimate reconciliation failed")
}

# Missing-post-T0 rates (all three DBs) and dropped-instead-of-zero sensitivity.
nopost_rows <- list()
for (horizon in c("48h", "7d")) {
  for (arm in c("trt", "ctl")) {
    x <- pairs[[paste0("nopost_", horizon, "_", arm)]]
    nopost_rows[[length(nopost_rows) + 1L]] <- data.frame(
      db = db, variant = "pooled", stratum = "Overall",
      horizon = horizon,
      arm = if (arm == "trt") "treated" else "control",
      n_pair_members = sum(!is.na(x)),
      no_post_cr = sum(x == 1, na.rm = TRUE),
      rate = mean(x, na.rm = TRUE)
    )
  }
}
nopost <- do.call(rbind, nopost_rows)

missing_drop <- data.frame()
if (tag %in% c("mimic", "eicu")) {
  rows <- list()
  for (outcome in OUTCOMES) {
    horizon <- if (grepl("48h", outcome)) "48h" else "7d"
    yt <- pairs[[paste0(outcome, "_trt")]]
    yc <- pairs[[paste0(outcome, "_ctl")]]
    yt[pairs[[paste0("nopost_", horizon, "_trt")]] == 1] <- NA
    yc[pairs[[paste0("nopost_", horizon, "_ctl")]] == 1] <- NA
    for (method in c("psm", "dr")) {
      adj_t <- adj_c <- NULL
      if (method == "dr") {
        adj_t <- all_pts[pairs$trt_idx, violations, drop = FALSE]
        adj_c <- all_pts[pairs$ctl_idx, violations, drop = FALSE]
      }
      est <- pair_or_rd(yt, yc, adj_t, adj_c)
      valid <- !is.na(yt) & !is.na(yc)
      rows[[length(rows) + 1L]] <- cbind(
        data.frame(
          db = db, missing_post_rule = "drop_pair_if_either_arm_missing",
          outcome = outcome, method = method,
          events_trt = sum(yt[valid]), events_ctl = sum(yc[valid]),
          sparse_lt20 = sum(yt[valid]) < 20 || sum(yc[valid]) < 20
        ),
        est
      )
    }
  }
  missing_drop <- do.call(rbind, rows)
}

# Baseline-nadir diagnostic on pair members.
early_value <- setNames(all_pts$cr_ref_early, as.character(all_pts$pid))
early_offset <- setNames(all_pts$cr_ref_early_offset_h, as.character(all_pts$pid))
dip_rows <- list()
for (arm in c("trt", "ctl")) {
  pid <- as.character(pairs[[paste0(arm, "_pid")]])
  baseline <- pairs[[paste0("baseline_", arm)]]
  baseline_offset <- pairs[[paste0("baseline_", arm, "_offset_h")]]
  early <- as.numeric(early_value[pid])
  early_h <- as.numeric(early_offset[pid])
  complete_times <- !is.na(early) & !is.na(early_h) & !is.na(baseline) &
    !is.na(baseline_offset)
  order_valid <- complete_times & early_h <= baseline_offset
  dip <- early[order_valid] - baseline[order_valid]
  dip_rows[[length(dip_rows) + 1L]] <- data.frame(
    db = db, population = "frozen_pair_members_pair_weighted",
    arm = if (arm == "trt") "treated" else "control",
    n_pair_members = length(pid), n_time_order_valid = sum(order_valid),
    n_time_order_invalid_or_missing = sum(!order_valid),
    n_missing_reference_or_baseline = sum(!complete_times),
    n_early_reference_after_pair_baseline = sum(
      complete_times & early_h > baseline_offset
    ),
    n_same_timestamp = sum(order_valid & early_h == baseline_offset),
    q25_dip = as.numeric(quantile(dip, 0.25)),
    median_dip = median(dip),
    q75_dip = as.numeric(quantile(dip, 0.75)),
    mean_dip = mean(dip),
    fraction_baseline_lower_than_early = mean(dip > 0),
    fraction_dip_ge_0_1 = mean(dip >= 0.1)
  )
}
baseline_dip <- do.call(rbind, dip_rows)

# MIMIC all-location mortality re-ascertainment from patients.dod.
mortality <- data.frame()
if (tag == "mimic") {
  icu <- read.csv(
    gzfile(file.path(MIMIC_ROOT, "icu", "icustays.csv.gz")),
    stringsAsFactors = FALSE
  )
  patients <- read.csv(
    gzfile(file.path(MIMIC_ROOT, "hosp", "patients.csv.gz")),
    stringsAsFactors = FALSE
  )
  icu$intime <- as.POSIXct(icu$intime, tz = "UTC")
  stay_to_subject <- setNames(icu$subject_id, as.character(icu$stay_id))
  stay_to_intime <- setNames(icu$intime, as.character(icu$stay_id))
  subject_to_dod <- setNames(as.Date(patients$dod), as.character(patients$subject_id))
  dod_outcome <- function(pid, t0) {
    subject <- as.character(stay_to_subject[pid])
    intime <- as.POSIXct(stay_to_intime[pid], origin = "1970-01-01", tz = "UTC")
    index_time <- intime + t0 * 3600
    dod <- as.Date(subject_to_dod[subject], origin = "1970-01-01")
    as.integer(
      !is.na(dod) & dod >= as.Date(index_time) &
        dod <= as.Date(index_time + 168 * 3600)
    )
  }
  dod_t <- mapply(
    dod_outcome, as.character(pairs$trt_pid), pairs$t0,
    USE.NAMES = FALSE
  )
  dod_c <- mapply(
    dod_outcome, as.character(pairs$ctl_pid), pairs$t0,
    USE.NAMES = FALSE
  )
  current_t <- pairs$death_7d_all_trt
  current_c <- pairs$death_7d_all_ctl
  definitions <- list(
    current_deathtime = list(t = current_t, c = current_c),
    patients_dod_calendar = list(t = dod_t, c = dod_c),
    combined_deathtime_or_dod = list(
      t = pmax(current_t, dod_t), c = pmax(current_c, dod_c)
    )
  )
  rows <- list()
  for (definition in names(definitions)) {
    yt <- definitions[[definition]]$t
    yc <- definitions[[definition]]$c
    for (method in c("psm", "dr")) {
      adj_t <- adj_c <- NULL
      if (method == "dr") {
        adj_t <- all_pts[pairs$trt_idx, violations, drop = FALSE]
        adj_c <- all_pts[pairs$ctl_idx, violations, drop = FALSE]
      }
      est <- pair_or_rd(yt, yc, adj_t, adj_c)
      valid <- !is.na(yt) & !is.na(yc)
      rows[[length(rows) + 1L]] <- cbind(
        data.frame(
          db = db, horizon = "7d", death_definition = definition,
          method = method, events_trt = sum(yt[valid]),
          events_ctl = sum(yc[valid]),
          sparse_lt20 = sum(yt[valid]) < 20 || sum(yc[valid]) < 20
        ),
        est
      )
    }
  }
  mortality <- do.call(rbind, rows)
}

write.csv(
  density,
  file.path(RESULTS, sprintf("surveillance_cr_density_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  comparison,
  file.path(RESULTS, sprintf("surveillance_aki_comparison_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  nopost,
  file.path(RESULTS, sprintf("surveillance_nopost_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  baseline_dip,
  file.path(RESULTS, sprintf("surveillance_baseline_dip_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  reconciliation,
  file.path(RESULTS, sprintf("surveillance_integrity_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  limited_comparison,
  file.path(RESULTS, sprintf("surveillance_limited_aki_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  limited_blip,
  file.path(RESULTS, sprintf("surveillance_limited_blip_%s.csv", tag)),
  row.names = FALSE
)
if (nrow(missing_drop)) {
  write.csv(
    missing_drop,
    file.path(RESULTS, sprintf("surveillance_missing_drop_%s.csv", tag)),
    row.names = FALSE
  )
}
if (nrow(mortality)) {
  write.csv(
    mortality,
    file.path(RESULTS, "surveillance_mortality_mimic.csv"),
    row.names = FALSE
  )
}

cat(sprintf(
  paste0(
    "probe_surveillance_bias.R | %s | COMPLETE | frozen pairs=%d | ",
    paste0(
      "daily-peak identity=%s | DR reconciliation=PASS | ",
      "scheduled-draw native reconciliation=PASS\n"
    )
  ),
  db, n_pairs, daily_identity
))
