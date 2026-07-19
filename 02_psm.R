#!/usr/bin/env Rscript
# Canonical frozen risk-set PSM for albumin and cardiac-surgery AKI.
# Usage: Rscript 02_psm.R {mimic|eicu} {pooled|egfr}

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
})

RESULTS <- path.expand("~/albumin_aki/results")
M_IMP <- 20
CALIPER_SD <- 0.2
PRIMARY_H <- 24
SEED <- 2026

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2 || !(tolower(args[1]) %in% c("mimic", "eicu")) ||
    !(tolower(args[2]) %in% c("pooled", "egfr"))) {
  stop("Usage: Rscript 02_psm.R {mimic|eicu} {pooled|egfr}")
}
tag <- tolower(args[1])
db <- toupper(tag)
variant <- tolower(args[2])
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
script_dir <- dirname(normalizePath(file_arg))
if (!file.exists(file.path(script_dir, "R", "causal_helpers.R"))) {
  script_dir <- getwd()
}
source(file.path(script_dir, "R", "causal_helpers.R"))

PS_BASE <- c(
  "age", "is_female", "bmi",
  "surg_cabg", "surg_valve", "surg_combined",
  "heart_failure", "hypertension", "diabetes", "ckd",
  "copd", "pvd", "stroke", "liver_disease", "egfr"
)
PS_VARS_POOLED <- c(
  PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
  "last_heartrate", "last_hemoglobin", "alb_cat"
)
PS_VARS_EGFR <- setdiff(PS_VARS_POOLED, c("egfr", "ckd"))
LAB_BASES <- c("albumin", "calcium", "lactate", "heartrate", "hemoglobin")

extract_static_last <- function(labs, all_pts) {
  for (lab in LAB_BASES) {
    sub <- labs[labs$lab_name == lab & labs$offset_h >= 0, , drop = FALSE]
    sub$own_t0 <- all_pts$alb_offset_h[match(sub$pid, all_pts$pid)]
    sub <- sub[is.na(sub$own_t0) | sub$offset_h < sub$own_t0, , drop = FALSE]
    if (nrow(sub) == 0) {
      all_pts[[paste0("last_", lab)]] <- NA_real_
      next
    }
    sub <- sub[order(sub$pid, -sub$offset_h, -sub$value), , drop = FALSE]
    sub <- sub[!duplicated(sub$pid), , drop = FALSE]
    all_pts[[paste0("last_", lab)]] <- sub$value[
      match(all_pts$pid, sub$pid)
    ]
  }
  all_pts$last_lactate_missing <- as.integer(is.na(all_pts$last_lactate))
  all_pts$alb_cat <- factor(
    ifelse(
      is.na(all_pts$last_albumin), "missing",
      ifelse(all_pts$last_albumin < 3.5, "low", "normal")
    ),
    levels = c("normal", "low", "missing")
  )
  all_pts
}

usable_ps_vars <- function(dat, vars) {
  missing <- setdiff(vars, names(dat))
  if (length(missing)) stop("Missing frozen PS variables: ", paste(missing, collapse = ", "))
  keep <- vars[vapply(vars, function(v) {
    x <- dat[[v]]
    if (is.factor(x) || is.character(x)) length(unique(x[!is.na(x)])) > 1
    else !all(is.na(x)) && var(x, na.rm = TRUE) > 1e-10
  }, logical(1))]
  dropped <- setdiff(vars, keep)
  if (length(dropped)) stop("Frozen PS variables are constant/all missing: ",
                            paste(dropped, collapse = ", "))
  keep
}

average_ps <- function(dat, vars) {
  numeric_vars <- vars[!vapply(dat[vars], function(x) is.factor(x) || is.character(x),
                               logical(1))]
  impute_vars <- numeric_vars[vapply(numeric_vars, function(v) any(is.na(dat[[v]])),
                                     logical(1))]
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
  mort_map <- setNames(all_pts$hosp_mortality, as.character(all_pts$pid))
  alb_map <- setNames(all_pts$alb_offset_h, as.character(all_pts$pid))
  rows <- vector("list", nrow(pairs))
  for (i in seq_len(nrow(pairs))) {
    tp <- as.character(pairs$trt_pid[i])
    cp <- as.character(pairs$ctl_pid[i])
    t0 <- pairs$t0[i]
    ot <- scr_kdigo_outcomes(cr_list[[tp]], pairs$baseline_trt[i], t0, rrt_map[tp])
    oc <- scr_kdigo_outcomes(cr_list[[cp]], pairs$baseline_ctl[i], t0, rrt_map[cp])
    calb <- alb_map[cp]
    censor48 <- !is.na(calb) && calb <= t0 + 48
    censor7d <- !is.na(calb) && calb <= t0 + 168
    if (censor48) {
      names48 <- c("aki1_48h", "aki2_48h", "aki3_48h", "aki2_rrt_48h")
      ot[names48] <- NA_integer_
      oc[names48] <- NA_integer_
    }
    if (censor7d) {
      names7d <- c("aki1_7d", "aki2_7d", "aki3_7d", "aki2_rrt_7d")
      ot[names7d] <- NA_integer_
      oc[names7d] <- NA_integer_
    }
    row <- data.frame(
      trt_pid = pairs$trt_pid[i], ctl_pid = pairs$ctl_pid[i],
      t0 = t0, baseline_trt = pairs$baseline_trt[i],
      baseline_ctl = pairs$baseline_ctl[i], stringsAsFactors = FALSE
    )
    for (nm in names(ot)) {
      row[[paste0(nm, "_trt")]] <- ot[nm]
      row[[paste0(nm, "_ctl")]] <- oc[nm]
    }
    row$hosp_mort_trt <- as.integer(mort_map[tp] == 1)
    row$hosp_mort_ctl <- as.integer(mort_map[cp] == 1)
    rows[[i]] <- row
  }
  do.call(rbind, rows)
}

cat(sprintf("\n02_psm.R | %s | %s | frozen main experiment\n", db, variant))
all_pts <- read.csv(file.path(RESULTS, sprintf("did_all_%s.csv", tag)),
                    stringsAsFactors = FALSE)
cr_all <- read.csv(file.path(RESULTS, sprintf("did_cr_all_%s.csv", tag)),
                   stringsAsFactors = FALSE)
labs <- read.csv(file.path(RESULTS, sprintf("did_labs_all_%s.csv", tag)),
                 stringsAsFactors = FALSE)
cr_id <- if ("patientunitstayid" %in% names(cr_all)) "patientunitstayid" else "stay_id"
lab_id <- if ("patientunitstayid" %in% names(labs)) "patientunitstayid" else "stay_id"
cr_all$pid <- cr_all[[cr_id]]
labs$pid <- labs[[lab_id]]
cr_all <- cr_all[order(cr_all$pid, cr_all$offset_h, -cr_all$labresult), ]
cr_list <- split(cr_all[, c("labresult", "offset_h")], cr_all$pid)
all_pts <- extract_static_last(labs, all_pts)
all_pts$egfr_stratum <- egfr_stratum(all_pts$egfr)
rm(labs)
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
cat(sprintf("  treated eligible after pair-time prevalent screen: %d/%d\n",
            length(treated_ok), length(treated_all)))

strata_to_run <- if (variant == "pooled") "Overall" else levels(all_pts$egfr_stratum)
all_match <- list()
all_balance <- list()
all_binary <- list()
all_pair_outcomes <- list()

for (stratum in strata_to_run) {
  in_stratum <- if (stratum == "Overall") rep(TRUE, nrow(all_pts)) else
    eligible_same_stratum(all_pts$egfr_stratum, stratum)
  trt_idx <- treated_ok[in_stratum[treated_ok]]
  ps_vars <- usable_ps_vars(all_pts[in_stratum, , drop = FALSE],
                            if (variant == "pooled") PS_VARS_POOLED else PS_VARS_EGFR)
  ps_out <- average_ps(all_pts[in_stratum, , drop = FALSE], ps_vars)
  all_pts$ps <- NA_real_
  all_pts$ps[in_stratum] <- ps_out$ps
  all_pts[in_stratum, ps_vars] <- ps_out$completed[, ps_vars, drop = FALSE]
  caliper <- CALIPER_SD * sd(all_pts$ps[in_stratum], na.rm = TRUE)

  matched_rows <- list()
  for (k in seq_along(trt_idx)) {
    ti <- trt_idx[k]
    t0 <- all_pts$alb_offset_h[ti]
    risk <- which(
      in_stratum & all_pts$pid != all_pts$pid[ti] &
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
      baseline_ctl_offset_h = bc["offset_h"], stratum = stratum
    )
  }
  pairs <- if (length(matched_rows)) do.call(rbind, matched_rows) else data.frame()
  n_match <- nrow(pairs)
  match_rate <- if (length(trt_idx)) n_match / length(trt_idx) else NA_real_
  cat(sprintf("  %s matched: %d/%d (%.1f%%), caliper %.5f\n",
              stratum, n_match, length(trt_idx), 100 * match_rate, caliper))
  if (is.na(match_rate) || match_rate < 0.90) {
    stop(sprintf("GUARD: %s match rate %.1f%% is below 90%%", stratum,
                 100 * match_rate))
  }

  smds <- vapply(ps_vars, function(v) {
    smd_one(all_pts[[v]][pairs$trt_idx], all_pts[[v]][pairs$ctl_idx])
  }, numeric(1))
  balance <- data.frame(
    db = db, variant = variant, stratum = stratum,
    variable = names(smds), smd = as.numeric(smds)
  )
  violations <- names(smds[smds > 0.10])
  cat(sprintf("    balance max=%.3f; violations=%d\n", max(smds),
              length(violations)))

  pair_outcomes <- make_pair_outcomes(pairs, all_pts, cr_list)
  outcomes <- c(
    "aki1_48h", "aki2_48h", "aki3_48h",
    "aki1_7d", "aki2_7d", "aki3_7d",
    "aki2_rrt_48h", "aki2_rrt_7d", "hosp_mort"
  )
  binary <- list()
  for (outcome in outcomes) {
    y_t <- pair_outcomes[[paste0(outcome, "_trt")]]
    y_c <- pair_outcomes[[paste0(outcome, "_ctl")]]
    methods <- c("psm", if (length(violations)) "psm_dr")
    for (method in methods) {
      adj_t <- adj_c <- NULL
      if (method == "psm_dr") {
        adj_t <- all_pts[pairs$trt_idx, violations, drop = FALSE]
        adj_c <- all_pts[pairs$ctl_idx, violations, drop = FALSE]
      }
      estimate <- pair_binary_or(y_t, y_c, adj_t, adj_c)
      binary[[length(binary) + 1L]] <- cbind(
        data.frame(db = db, variant = variant, stratum = stratum,
                   outcome = outcome, method = method),
        estimate
      )
    }
  }
  binary <- do.call(rbind, binary)
  all_match[[length(all_match) + 1L]] <- data.frame(
    db = db, variant = variant, stratum = stratum,
    treated_eligible = length(trt_idx), matched = n_match,
    match_rate = match_rate, caliper = caliper,
    max_smd = max(smds), n_viol = length(violations)
  )
  all_balance[[length(all_balance) + 1L]] <- balance
  all_binary[[length(all_binary) + 1L]] <- binary
  all_pair_outcomes[[length(all_pair_outcomes) + 1L]] <- merge(
    pairs, pair_outcomes,
    by = c("trt_pid", "ctl_pid", "t0", "baseline_trt", "baseline_ctl")
  )
}

match_summary <- do.call(rbind, all_match)
balance_all <- do.call(rbind, all_balance)
binary_all <- do.call(rbind, all_binary)
pairs_all <- do.call(rbind, all_pair_outcomes)
write.csv(match_summary,
          file.path(RESULTS, sprintf("did_riskset_%s_%s.csv", variant, tag)),
          row.names = FALSE)
write.csv(balance_all,
          file.path(RESULTS, sprintf("psm_balance_%s_%s.csv", variant, tag)),
          row.names = FALSE)
write.csv(binary_all,
          file.path(RESULTS, sprintf("did_binary_%s_%s.csv", variant, tag)),
          row.names = FALSE)
write.csv(pairs_all,
          file.path(RESULTS, sprintf(
            "did_pairs_primary_yet_untreated_%s_%s.csv", variant, tag
          )),
          row.names = FALSE)
cat(sprintf("02_psm.R | %s | %s | COMPLETE\n", db, variant))
