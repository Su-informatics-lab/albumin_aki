#!/usr/bin/env Rscript
# Labeled full-eICU +MAP sensitivity. Frozen v3.3 outputs remain untouched.

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
})

RESULTS <- path.expand(Sys.getenv(
  "ALBUMIN_AKI_RESULTS", unset = "~/albumin_aki/results"
))
M_IMP <- 20
CALIPER_SD <- 0.2
PRIMARY_H <- 24
SEED <- 2026
OUTCOMES <- c("aki1_48h", "aki2_48h", "aki1_7d", "aki2_7d")

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
script_dir <- dirname(normalizePath(file_arg))
if (!file.exists(file.path(script_dir, "R", "causal_helpers.R"))) {
  script_dir <- getwd()
}
source(file.path(script_dir, "R", "causal_helpers.R"))
source(file.path(script_dir, "R", "covariate_registry.R"))

safe_read <- function(name) {
  path <- file.path(RESULTS, name)
  if (!file.exists(path)) stop("Required input missing: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

build_base_covariates <- function(all_pts, labs) {
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
  surg <- safe_read("surg_eicu.csv")
  all_pts$surg_aortic <- as.integer(
    surg$surg_aortic[match(all_pts$pid, surg$pid)]
  )
  all_pts$surg_aortic[is.na(all_pts$surg_aortic)] <- 0L

  map <- safe_read("eicu_map_at_t0_dual.csv")
  if (anyDuplicated(map$pid)) stop("Dual-source MAP file has duplicate pid")
  all_pts$map_before_t0 <- map$map_before_t0[match(all_pts$pid, map$pid)]
  all_pts$map_missing <- as.integer(is.na(all_pts$map_before_t0))
  expected_t <- sum(all_pts$treated == 1 & !is.na(all_pts$map_before_t0))
  expected_c <- sum(all_pts$treated == 0 & !is.na(all_pts$map_before_t0))
  if (expected_t != 2067L || expected_c != 14944L) {
    stop(sprintf(
      "Dual-source MAP coverage mismatch: treated=%d control=%d",
      expected_t, expected_c
    ))
  }
  all_pts
}

usable_ps_vars <- function(dat, vars) {
  missing <- setdiff(vars, names(dat))
  if (length(missing)) stop("Missing PS variables: ", paste(missing, collapse = ", "))
  keep <- vars[vapply(vars, function(v) {
    x <- dat[[v]]
    if (is.factor(x) || is.character(x)) length(unique(x[!is.na(x)])) > 1 else
      !all(is.na(x)) && var(x, na.rm = TRUE) > 1e-10
  }, logical(1))]
  dropped <- setdiff(vars, keep)
  if (length(dropped)) stop("Constant/all-missing PS variables: ",
                            paste(dropped, collapse = ", "))
  keep
}

average_ps <- function(dat, vars) {
  numeric_vars <- vars[!vapply(
    dat[vars], function(x) is.factor(x) || is.character(x), logical(1)
  )]
  impute_vars <- numeric_vars[vapply(
    numeric_vars, function(v) any(is.na(dat[[v]])), logical(1)
  )]
  base <- dat[, c("treated", numeric_vars), drop = FALSE]
  completed <- vector("list", M_IMP)
  if (length(impute_vars)) {
    methods <- rep("", ncol(base))
    names(methods) <- names(base)
    methods[impute_vars] <- "pmm"
    set.seed(SEED)
    imp <- mice(base, m = M_IMP, method = methods, maxit = 10, printFlag = FALSE)
    for (m in seq_len(M_IMP)) completed[[m]] <- complete(imp, m)
  } else {
    for (m in seq_len(M_IMP)) completed[[m]] <- base
  }
  preds <- matrix(NA_real_, nrow(dat), M_IMP)
  for (m in seq_len(M_IMP)) {
    model_dat <- dat[, vars, drop = FALSE]
    model_dat[numeric_vars] <- completed[[m]][numeric_vars]
    model_dat$treated <- dat$treated
    fit <- suppressWarnings(glm(
      reformulate(vars, response = "treated"),
      data = model_dat, family = binomial()
    ))
    preds[, m] <- predict(fit, newdata = model_dat, type = "response")
    if (m == 1L) dat[numeric_vars] <- model_dat[numeric_vars]
  }
  list(ps = rowMeans(preds), completed = dat)
}

smd_one <- function(x1, x0) {
  if (is.factor(x1) || is.character(x1)) {
    levels_all <- union(unique(as.character(x1)), unique(as.character(x0)))
    vals <- vapply(levels_all, function(level) {
      p1 <- mean(as.character(x1) == level)
      p0 <- mean(as.character(x0) == level)
      sp <- sqrt((p1 * (1 - p1) + p0 * (1 - p0)) / 2)
      if (is.na(sp) || sp < 1e-10) 0 else abs(p1 - p0) / sp
    }, numeric(1))
    return(max(vals))
  }
  sp <- sqrt((var(x1, na.rm = TRUE) + var(x0, na.rm = TRUE)) / 2)
  if (is.na(sp) || sp < 1e-10) 0 else
    abs(mean(x1, na.rm = TRUE) - mean(x0, na.rm = TRUE)) / sp
}

make_pair_outcomes <- function(pairs, all_pts, cr_list) {
  rrt_map <- setNames(all_pts$rrt_offset_h, as.character(all_pts$pid))
  alb_map <- setNames(all_pts$alb_offset_h, as.character(all_pts$pid))
  rows <- vector("list", nrow(pairs))
  for (i in seq_len(nrow(pairs))) {
    tp <- as.character(pairs$trt_pid[i])
    cp <- as.character(pairs$ctl_pid[i])
    t0 <- pairs$t0[i]
    ot <- scr_kdigo_outcomes(cr_list[[tp]], pairs$baseline_trt[i], t0, rrt_map[tp])
    oc <- scr_kdigo_outcomes(cr_list[[cp]], pairs$baseline_ctl[i], t0, rrt_map[cp])
    calb <- alb_map[cp]
    if (!is.na(calb) && calb <= t0 + 48) {
      names48 <- c("aki1_48h", "aki2_48h", "aki3_48h", "aki2_rrt_48h")
      ot[names48] <- NA_integer_
      oc[names48] <- NA_integer_
    }
    if (!is.na(calb) && calb <= t0 + 168) {
      names7d <- c("aki1_7d", "aki2_7d", "aki3_7d", "aki2_rrt_7d")
      ot[names7d] <- NA_integer_
      oc[names7d] <- NA_integer_
    }
    row <- data.frame(
      trt_pid = pairs$trt_pid[i], ctl_pid = pairs$ctl_pid[i],
      t0 = t0, baseline_trt = pairs$baseline_trt[i],
      baseline_ctl = pairs$baseline_ctl[i]
    )
    for (nm in names(ot)) {
      row[[paste0(nm, "_trt")]] <- ot[nm]
      row[[paste0(nm, "_ctl")]] <- oc[nm]
    }
    rows[[i]] <- row
  }
  do.call(rbind, rows)
}

effect_rows <- function(pair_outcomes, pairs, all_pts, adjust_vars,
                        analysis, methods) {
  rows <- list()
  for (outcome in OUTCOMES) {
    y_t <- pair_outcomes[[paste0(outcome, "_trt")]]
    y_c <- pair_outcomes[[paste0(outcome, "_ctl")]]
    for (method in methods) {
      adj_t <- adj_c <- NULL
      if (method == "dr") {
        adj_t <- all_pts[pairs$trt_idx, adjust_vars, drop = FALSE]
        adj_c <- all_pts[pairs$ctl_idx, adjust_vars, drop = FALSE]
      }
      est <- pair_or_rd(y_t, y_c, adj_t, adj_c)
      valid <- !is.na(y_t) & !is.na(y_c)
      rows[[length(rows) + 1L]] <- cbind(
        data.frame(
          db = "EICU", analysis = analysis, outcome = outcome,
          method = method, events_trt = sum(y_t[valid]),
          events_ctl = sum(y_c[valid]),
          sparse_lt20 = sum(y_t[valid]) < 20 || sum(y_c[valid]) < 20,
          adjustment_vars = if (method == "dr") {
            paste(adjust_vars, collapse = ";")
          } else {
            ""
          }, stringsAsFactors = FALSE
        ),
        est
      )
    }
  }
  do.call(rbind, rows)
}

cat("probe_eicu_map_sensitivity.R | START | labeled sensitivity\n")
all_pts <- safe_read("did_all_eicu.csv")
cr_all <- safe_read("did_cr_all_eicu.csv")
labs <- safe_read("did_labs_all_eicu.csv")
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
all_pts <- build_base_covariates(all_pts, labs)
raw_map <- all_pts$map_before_t0
rm(labs, cr_all)
gc()

early_value <- setNames(all_pts$cr_ref_early, as.character(all_pts$pid))
early_offset <- setNames(all_pts$cr_ref_early_offset_h, as.character(all_pts$pid))
all_pts$first_prevalent_h <- vapply(as.character(all_pts$pid), function(pid) {
  first_prevalent_aki_time(cr_list[[pid]], early_value[pid], early_offset[pid])
}, numeric(1))
treated_all <- which(all_pts$treated == 1 & !is.na(all_pts$alb_offset_h))
treated_ok <- treated_all[
  all_pts$cr_ref_early_offset_h[treated_all] <= all_pts$alb_offset_h[treated_all] &
    (is.na(all_pts$first_prevalent_h[treated_all]) |
       all_pts$first_prevalent_h[treated_all] > all_pts$alb_offset_h[treated_all]) &
    all_pts$icu_discharge_h[treated_all] > all_pts$alb_offset_h[treated_all] &
    (is.na(all_pts$death_offset_h[treated_all]) |
       all_pts$death_offset_h[treated_all] > all_pts$alb_offset_h[treated_all])
]
if (length(treated_ok) != 1981L) {
  stop("Eligibility drift: expected 1,981 eligible treated")
}

# 20 frozen clinical variables + MAP = 21; map_missing is an additional
# missingness-indicator design column, as prespecified.
ps_vars <- c(
  main_ps_vars("eicu", "pooled", "primary"),
  "map_before_t0", "map_missing"
)
ps_vars <- usable_ps_vars(all_pts, ps_vars)
ps_out <- average_ps(all_pts, ps_vars)
all_pts$ps <- ps_out$ps
all_pts[, ps_vars] <- ps_out$completed[, ps_vars, drop = FALSE]
caliper <- CALIPER_SD * sd(all_pts$ps, na.rm = TRUE)

matched_rows <- list()
for (ti in treated_ok) {
  t0 <- all_pts$alb_offset_h[ti]
  risk <- which(
    all_pts$pid != all_pts$pid[ti] &
      all_pts$icu_discharge_h > t0 &
      (is.na(all_pts$death_offset_h) | all_pts$death_offset_h > t0) &
      all_pts$cr_ref_early_offset_h <= t0 &
      (is.na(all_pts$first_prevalent_h) | all_pts$first_prevalent_h > t0) &
      (is.na(all_pts$alb_offset_h) | all_pts$alb_offset_h > t0 + PRIMARY_H)
  )
  if (!length(risk)) next
  distance <- abs(all_pts$ps[risk] - all_pts$ps[ti])
  candidates <- risk[order(distance)]
  candidates <- candidates[distance[order(distance)] <= caliper]
  if (!length(candidates)) next
  bt <- max_at_latest_before(
    cr_list[[as.character(all_pts$pid[ti])]], t0,
    all_pts$baseline_cr[ti], all_pts$baseline_cr_offset_h[ti]
  )
  if (is.na(bt["value"])) next
  chosen <- NA_integer_
  bc <- c(value = NA_real_, offset_h = NA_real_)
  for (ci in candidates) {
    bc_try <- max_at_latest_before(
      cr_list[[as.character(all_pts$pid[ci])]], t0,
      all_pts$baseline_cr[ci], all_pts$baseline_cr_offset_h[ci]
    )
    if (!is.na(bc_try["value"])) {
      chosen <- ci
      bc <- bc_try
      break
    }
  }
  if (is.na(chosen)) next
  matched_rows[[length(matched_rows) + 1L]] <- data.frame(
    trt_idx = ti, ctl_idx = chosen, trt_pid = all_pts$pid[ti],
    ctl_pid = all_pts$pid[chosen], t0 = t0,
    baseline_trt = bt["value"], baseline_ctl = bc["value"],
    baseline_trt_offset_h = bt["offset_h"],
    baseline_ctl_offset_h = bc["offset_h"], stratum = "Overall"
  )
}
pairs <- do.call(rbind, matched_rows)
match_rate <- nrow(pairs) / length(treated_ok)
if (match_rate < 0.90) {
  stop(sprintf("GUARD: +MAP match rate %.1f%% below 90%%", 100 * match_rate))
}

smds <- vapply(ps_vars, function(v) {
  smd_one(all_pts[[v]][pairs$trt_idx], all_pts[[v]][pairs$ctl_idx])
}, numeric(1))
raw_ctl_idx <- which(all_pts$treated == 0)
raw_smds <- vapply(ps_vars, function(v) {
  smd_one(all_pts[[v]][treated_ok], all_pts[[v]][raw_ctl_idx])
}, numeric(1))
balance <- data.frame(
  db = "EICU", analysis = "map_rematched", variable_code = ps_vars,
  variable = c(
    covariate_display_label(setdiff(ps_vars, c("map_before_t0", "map_missing"))),
    "baseline (at ICU T0): dual-source MAP", "dual-source MAP missing"
  ),
  raw_smd = as.numeric(raw_smds), smd = as.numeric(smds),
  balance_scale = "PS completed-data scale", stringsAsFactors = FALSE
)
balance <- rbind(
  balance,
  data.frame(
    db = "EICU", analysis = "map_rematched",
    variable_code = "map_before_t0_available_case",
    variable = "dual-source MAP available-case",
    raw_smd = smd_one(raw_map[treated_ok], raw_map[raw_ctl_idx]),
    smd = smd_one(raw_map[pairs$trt_idx], raw_map[pairs$ctl_idx]),
    balance_scale = "available-case descriptive", stringsAsFactors = FALSE
  )
)
violations <- names(smds[smds > 0.10])
pair_outcomes <- make_pair_outcomes(pairs, all_pts, cr_list)
rematched_effects <- effect_rows(
  pair_outcomes, pairs, all_pts, violations,
  "map_rematched", c("psm", "dr")
)

# Check: augment the existing frozen pairs with MAP in the outcome model.
frozen_pairs <- safe_read(
  "did_pairs_primary_yet_untreated_pooled_eicu.csv"
)
frozen_balance <- safe_read("psm_balance_pooled_eicu.csv")
frozen_violations <- frozen_balance$variable_code[
  frozen_balance$stratum == "Overall" & frozen_balance$smd > 0.10
]
augment_vars <- unique(c(frozen_violations, "map_before_t0", "map_missing"))
augmented_effects <- effect_rows(
  frozen_pairs, frozen_pairs, all_pts, augment_vars,
  "frozen_pairs_map_dr_augmented", "dr"
)
effects <- rbind(rematched_effects, augmented_effects)

match_summary <- data.frame(
  db = "EICU", analysis = "map_rematched",
  clinical_covariates = 21L, ps_design_columns = length(ps_vars),
  treated_eligible = length(treated_ok), matched = nrow(pairs),
  match_rate = match_rate, caliper = caliper,
  max_smd = max(smds), n_viol = length(violations),
  map_raw_smd = raw_smds["map_before_t0"],
  map_post_smd = smds["map_before_t0"],
  map_missing_raw_smd = raw_smds["map_missing"],
  map_missing_post_smd = smds["map_missing"],
  map_missing_raw_rate_trt = mean(all_pts$map_missing[treated_ok]),
  map_missing_raw_rate_ctl = mean(all_pts$map_missing[raw_ctl_idx]),
  map_missing_post_rate_trt = mean(all_pts$map_missing[pairs$trt_idx]),
  map_missing_post_rate_ctl = mean(all_pts$map_missing[pairs$ctl_idx])
)

reference_rows <- list()
for (tag in c("eicu", "mimic")) {
  ref <- safe_read(sprintf("did_binary_pooled_%s.csv", tag))
  ref <- ref[ref$stratum == "Overall" & ref$outcome %in% OUTCOMES, ]
  ref$analysis <- if (tag == "eicu") "frozen_eicu_20var" else "mimic_reference"
  ref$events_trt <- round(ref$rate_trt * ref$n)
  ref$events_ctl <- round(ref$rate_ctl * ref$n)
  ref$sparse_lt20 <- ref$events_trt < 20 | ref$events_ctl < 20
  reference_rows[[tag]] <- ref[, c(
    "db", "analysis", "outcome", "method", "events_trt", "events_ctl",
    "sparse_lt20", "n", "rate_trt", "rate_ctl", "or", "or_ci_lo",
    "or_ci_hi", "or_p", "rd", "rd_ci_lo", "rd_ci_hi", "rd_p"
  )]
}
sens_compare <- effects[, c(
  "db", "analysis", "outcome", "method", "events_trt", "events_ctl",
  "sparse_lt20", "n", "rate_trt", "rate_ctl", "or", "or_ci_lo",
  "or_ci_hi", "or_p", "rd", "rd_ci_lo", "rd_ci_hi", "rd_p"
)]
comparison <- rbind(reference_rows$eicu, sens_compare, reference_rows$mimic)

write.csv(
  match_summary,
  file.path(RESULTS, "eicu_map_sensitivity_match.csv"), row.names = FALSE
)
write.csv(
  balance,
  file.path(RESULTS, "eicu_map_sensitivity_balance.csv"), row.names = FALSE
)
write.csv(
  effects,
  file.path(RESULTS, "eicu_map_sensitivity_effects.csv"), row.names = FALSE
)
write.csv(
  comparison,
  file.path(RESULTS, "eicu_map_sensitivity_comparison.csv"), row.names = FALSE
)
write.csv(
  cbind(pairs, pair_outcomes),
  file.path(RESULTS, "eicu_map_sensitivity_pairs.csv"), row.names = FALSE
)
cat(sprintf(
  paste0(
    "probe_eicu_map_sensitivity.R | COMPLETE | matched=%d/%d (%.1f%%) | ",
    "maxSMD=%.3f violations=%d | labeled sensitivity\n"
  ),
  nrow(pairs), length(treated_ok), 100 * match_rate,
  max(smds), length(violations)
))
