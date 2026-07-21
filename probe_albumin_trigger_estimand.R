#!/usr/bin/env Rscript
# Clinician-guided trigger-lab and estimand sensitivities (Entry 39).
# Labeled sensitivity only: the frozen v3.3 primary is not modified.
# Usage: Rscript probe_albumin_trigger_estimand.R {mimic|eicu|iuh}

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1 || !(tolower(args[1]) %in% c("mimic", "eicu", "iuh"))) {
  stop("Usage: Rscript probe_albumin_trigger_estimand.R {mimic|eicu|iuh}")
}
tag <- tolower(args[1])
db <- toupper(tag)

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(normalizePath(file_arg))
source(file.path(repo, "R", "causal_helpers.R"))
source(file.path(repo, "R", "covariate_registry.R"))

RESULTS <- path.expand(Sys.getenv(
  "ALBUMIN_AKI_RESULTS", unset = "~/albumin_aki/results"
))
M_IMP <- 20L
CALIPER_SD <- 0.2
PRIMARY_H <- 24
SEED <- 2026L
CUTS <- c(3.5, 3.0, 2.5)
OUTCOMES <- c("aki1_48h", "aki2_48h", "aki1_7d", "aki2_7d")

safe_read <- function(name) {
  path <- file.path(RESULTS, name)
  if (!file.exists(path)) stop("Required sensitivity input missing: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

usable_vars <- function(dat, vars) {
  missing <- setdiff(vars, names(dat))
  if (length(missing)) stop("Missing registered variables: ", paste(missing, collapse = ", "))
  keep <- vars[vapply(vars, function(v) {
    x <- dat[[v]]
    if (is.factor(x) || is.character(x)) {
      length(unique(x[!is.na(x)])) > 1
    } else {
      !all(is.na(x)) && var(x, na.rm = TRUE) > 1e-10
    }
  }, logical(1))]
  dropped <- setdiff(vars, keep)
  if (length(dropped)) stop("Registered variables constant/all missing: ",
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
  logged_events <- 0L
  if (length(impute_vars)) {
    methods <- rep("", ncol(base))
    names(methods) <- names(base)
    methods[impute_vars] <- "pmm"
    set.seed(SEED)
    imp <- mice(base, m = M_IMP, method = methods, maxit = 10, printFlag = FALSE)
    logged_events <- if (is.null(imp$loggedEvents)) 0L else nrow(imp$loggedEvents)
    for (m in seq_len(M_IMP)) completed[[m]] <- complete(imp, m)
  } else {
    for (m in seq_len(M_IMP)) completed[[m]] <- base
  }
  preds <- matrix(NA_real_, nrow(dat), M_IMP)
  first <- dat
  for (m in seq_len(M_IMP)) {
    model_dat <- dat[, vars, drop = FALSE]
    model_dat[numeric_vars] <- completed[[m]][numeric_vars]
    model_dat$treated <- dat$treated
    fit <- suppressWarnings(glm(
      reformulate(vars, response = "treated"),
      data = model_dat, family = binomial()
    ))
    preds[, m] <- predict(fit, newdata = model_dat, type = "response")
    if (m == 1L) first[, vars] <- model_dat[, vars, drop = FALSE]
  }
  list(ps = rowMeans(preds), completed = first, logged_events = logged_events)
}

smd_one <- function(x1, x0) {
  if (is.factor(x1) || is.character(x1)) {
    levels_all <- union(unique(as.character(x1)), unique(as.character(x0)))
    return(max(vapply(levels_all, function(level) {
      p1 <- mean(as.character(x1) == level)
      p0 <- mean(as.character(x0) == level)
      sp <- sqrt((p1 * (1 - p1) + p0 * (1 - p0)) / 2)
      if (is.na(sp) || sp < 1e-10) 0 else abs(p1 - p0) / sp
    }, numeric(1))))
  }
  sp <- sqrt((var(x1, na.rm = TRUE) + var(x0, na.rm = TRUE)) / 2)
  if (is.na(sp) || sp < 1e-10) 0 else
    abs(mean(x1, na.rm = TRUE) - mean(x0, na.rm = TRUE)) / sp
}

weighted_smd <- function(x, treated, weight) {
  one_level <- function(z) {
    i1 <- treated == 1
    i0 <- treated == 0
    p1 <- weighted.mean(z[i1], weight[i1])
    p0 <- weighted.mean(z[i0], weight[i0])
    sp <- sqrt((p1 * (1 - p1) + p0 * (1 - p0)) / 2)
    if (is.na(sp) || sp < 1e-10) 0 else abs(p1 - p0) / sp
  }
  if (is.factor(x) || is.character(x)) {
    lev <- unique(as.character(x))
    return(max(vapply(lev, function(z) one_level(as.character(x) == z), numeric(1))))
  }
  i1 <- treated == 1
  i0 <- treated == 0
  m1 <- weighted.mean(x[i1], weight[i1])
  m0 <- weighted.mean(x[i0], weight[i0])
  v1 <- weighted.mean((x[i1] - m1)^2, weight[i1])
  v0 <- weighted.mean((x[i0] - m0)^2, weight[i0])
  sp <- sqrt((v1 + v0) / 2)
  if (is.na(sp) || sp < 1e-10) 0 else abs(m1 - m0) / sp
}

build_covariates <- function(all_pts, labs) {
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

set_alb_cat <- function(dat, cut) {
  dat$alb_cat <- factor(
    ifelse(
      is.na(dat$last_albumin), "missing",
      ifelse(dat$last_albumin < cut, "low", "normal")
    ),
    levels = c("normal", "low", "missing")
  )
  dat
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
      ot[c("aki1_48h", "aki2_48h")] <- NA_integer_
      oc[c("aki1_48h", "aki2_48h")] <- NA_integer_
    }
    if (!is.na(calb) && calb <= t0 + 168) {
      ot[c("aki1_7d", "aki2_7d")] <- NA_integer_
      oc[c("aki1_7d", "aki2_7d")] <- NA_integer_
    }
    row <- data.frame(
      trt_pid = pairs$trt_pid[i], ctl_pid = pairs$ctl_pid[i], t0 = t0,
      baseline_trt = pairs$baseline_trt[i], baseline_ctl = pairs$baseline_ctl[i]
    )
    for (outcome in OUTCOMES) {
      row[[paste0(outcome, "_trt")]] <- ot[outcome]
      row[[paste0(outcome, "_ctl")]] <- oc[outcome]
    }
    rows[[i]] <- row
  }
  do.call(rbind, rows)
}

match_risk_set <- function(dat, cr_list, treated_idx, ps_vars, allowed,
                           label) {
  subset_idx <- which(allowed)
  ps_out <- average_ps(dat[subset_idx, , drop = FALSE], ps_vars)
  analysis <- dat
  analysis$ps <- NA_real_
  analysis$ps[subset_idx] <- ps_out$ps
  analysis[subset_idx, ps_vars] <- ps_out$completed[, ps_vars, drop = FALSE]
  caliper <- CALIPER_SD * sd(analysis$ps[subset_idx], na.rm = TRUE)
  matched <- list()
  for (ti in treated_idx) {
    t0 <- analysis$alb_offset_h[ti]
    risk <- which(
      allowed & analysis$pid != analysis$pid[ti] &
        analysis$icu_discharge_h > t0 &
        (is.na(analysis$death_offset_h) | analysis$death_offset_h > t0) &
        analysis$cr_ref_early_offset_h <= t0 &
        (is.na(analysis$first_prevalent_h) |
           analysis$first_prevalent_h > t0) &
        (is.na(analysis$alb_offset_h) |
           analysis$alb_offset_h > t0 + PRIMARY_H)
    )
    if (!length(risk)) next
    distance <- abs(analysis$ps[risk] - analysis$ps[ti])
    ord <- order(distance)
    candidates <- risk[ord][distance[ord] <= caliper]
    if (!length(candidates)) next
    bt <- max_at_latest_before(
      cr_list[[as.character(analysis$pid[ti])]], t0,
      analysis$baseline_cr[ti], analysis$baseline_cr_offset_h[ti]
    )
    if (is.na(bt["value"])) next
    chosen <- NA_integer_
    bc <- c(value = NA_real_, offset_h = NA_real_)
    for (ci in candidates) {
      bc_try <- max_at_latest_before(
        cr_list[[as.character(analysis$pid[ci])]], t0,
        analysis$baseline_cr[ci], analysis$baseline_cr_offset_h[ci]
      )
      if (!is.na(bc_try["value"])) {
        chosen <- ci
        bc <- bc_try
        break
      }
    }
    if (is.na(chosen)) next
    matched[[length(matched) + 1L]] <- data.frame(
      trt_idx = ti, ctl_idx = chosen,
      trt_pid = analysis$pid[ti], ctl_pid = analysis$pid[chosen], t0 = t0,
      baseline_trt = bt["value"], baseline_ctl = bc["value"]
    )
  }
  pairs <- if (length(matched)) do.call(rbind, matched) else data.frame()
  match_rate <- nrow(pairs) / length(treated_idx)
  cat(sprintf("  %s: matched %d/%d (%.1f%%)\n", label, nrow(pairs),
              length(treated_idx), 100 * match_rate))
  if (!is.finite(match_rate) || match_rate < 0.90) {
    stop(sprintf("GUARD: %s match rate %.1f%% below 90%%", label,
                 100 * match_rate))
  }
  smds <- vapply(ps_vars, function(v) {
    smd_one(analysis[[v]][pairs$trt_idx], analysis[[v]][pairs$ctl_idx])
  }, numeric(1))
  raw_ctl <- which(allowed & analysis$treated == 0)
  raw_smds <- vapply(ps_vars, function(v) {
    smd_one(analysis[[v]][treated_idx], analysis[[v]][raw_ctl])
  }, numeric(1))
  list(
    analysis = analysis, pairs = pairs, match_rate = match_rate,
    caliper = caliper, smds = smds, raw_smds = raw_smds,
    violations = names(smds[smds > 0.10]),
    logged_events = ps_out$logged_events
  )
}

matched_effects <- function(fit, pair_outcomes, analysis_name, stratum,
                            cut) {
  rows <- list()
  for (outcome in OUTCOMES) {
    y_t <- pair_outcomes[[paste0(outcome, "_trt")]]
    y_c <- pair_outcomes[[paste0(outcome, "_ctl")]]
    for (method in c("psm", "dr")) {
      adj_t <- adj_c <- NULL
      if (method == "dr" && length(fit$violations)) {
        adj_t <- fit$analysis[fit$pairs$trt_idx, fit$violations, drop = FALSE]
        adj_c <- fit$analysis[fit$pairs$ctl_idx, fit$violations, drop = FALSE]
      }
      est <- pair_or_rd(y_t, y_c, adj_t, adj_c)
      valid <- !is.na(y_t) & !is.na(y_c)
      events_t <- sum(y_t[valid])
      events_c <- sum(y_c[valid])
      rows[[length(rows) + 1L]] <- cbind(
        data.frame(
          db = db, analysis = analysis_name, cut = cut, stratum = stratum,
          outcome = outcome, method = method,
          events_trt = events_t, events_ctl = events_c,
          sparse_lt20 = events_t < 20 || events_c < 20,
          match_rate = fit$match_rate, max_smd = max(fit$smds),
          n_viol = length(fit$violations),
          adjustment_vars = if (method == "dr") {
            paste(fit$violations, collapse = ";")
          } else "", stringsAsFactors = FALSE
        ), est
      )
    }
  }
  do.call(rbind, rows)
}

interaction_or_rd <- function(y_t, y_c, modifier, adjust_t, adjust_c) {
  valid <- !is.na(y_t) & !is.na(y_c) & !is.na(modifier)
  n <- sum(valid)
  modifier_valid <- as.character(modifier[valid])
  cell_events <- unlist(lapply(c("missing", "normal", "low"), function(level) {
    idx <- modifier_valid == level
    c(trt = sum(y_t[valid][idx]), ctl = sum(y_c[valid][idx]))
  }))
  min_cell_events <- min(cell_events)
  sparse_lt20 <- min_cell_events < 20
  dat <- data.frame(
    outcome = c(y_t[valid], y_c[valid]),
    treated = rep(c(1L, 0L), each = n),
    modifier = factor(rep(modifier[valid], 2),
                      levels = c("missing", "normal", "low"))
  )
  if (!is.null(adjust_t) && ncol(adjust_t)) {
    for (nm in names(adjust_t)) {
      dat[[nm]] <- c(adjust_t[[nm]][valid], adjust_c[[nm]][valid])
    }
  }
  adjustment <- setdiff(names(dat), c("outcome", "treated", "modifier"))
  adjustment <- adjustment[vapply(adjustment, function(v) {
    x <- dat[[v]]
    if (is.factor(x) || is.character(x)) length(unique(x)) > 1 else
      is.finite(var(x, na.rm = TRUE)) && var(x, na.rm = TRUE) > 1e-10
  }, logical(1))]
  rhs <- c("treated * modifier", adjustment)
  formula <- as.formula(paste("outcome ~", paste(rhs, collapse = " + ")))
  fits <- list(
    or = tryCatch(glm(formula, data = dat, family = quasibinomial()),
                  error = function(e) NULL),
    rd = tryCatch(lm(formula, data = dat), error = function(e) NULL)
  )
  rows <- list()
  for (scale in names(fits)) {
    fit <- fits[[scale]]
    if (is.null(fit)) next
    vc <- tryCatch(vcovHC(fit, type = "HC1"), error = function(e) NULL)
    if (is.null(vc)) next
    beta <- coef(fit)
    idx <- grep("^treated:modifier", names(beta))
    idx <- idx[is.finite(beta[idx])]
    if (!length(idx)) next
    vv <- vc[idx, idx, drop = FALSE]
    joint <- tryCatch(
      as.numeric(t(beta[idx]) %*% solve(vv, beta[idx])),
      error = function(e) NA_real_
    )
    rows[[length(rows) + 1L]] <- data.frame(
      scale = scale, term = "omnibus", estimate = NA_real_,
      ci_lo = NA_real_, ci_hi = NA_real_, p = pchisq(joint, length(idx),
                                                     lower.tail = FALSE),
      n = n, events_trt = sum(y_t[valid]), events_ctl = sum(y_c[valid]),
      min_cell_events = min_cell_events, sparse_lt20 = sparse_lt20,
      adjustment_vars = paste(adjustment, collapse = ";")
    )
    ct <- safe_hc1(fit)
    for (j in idx) {
      se <- sqrt(vc[j, j])
      estimate <- if (scale == "or") exp(beta[j]) else beta[j]
      lo <- if (scale == "or") exp(beta[j] - 1.96 * se) else beta[j] - 1.96 * se
      hi <- if (scale == "or") exp(beta[j] + 1.96 * se) else beta[j] + 1.96 * se
      rows[[length(rows) + 1L]] <- data.frame(
        scale = scale, term = names(beta)[j], estimate = estimate,
        ci_lo = lo, ci_hi = hi, p = ct[names(beta)[j], ncol(ct)],
        n = n, events_trt = sum(y_t[valid]), events_ctl = sum(y_c[valid]),
        min_cell_events = min_cell_events, sparse_lt20 = sparse_lt20,
        adjustment_vars = paste(adjustment, collapse = ";")
      )
    }
  }
  do.call(rbind, rows)
}

weighted_or_rd <- function(y, treated, weight) {
  valid <- !is.na(y) & !is.na(treated) & !is.na(weight) & weight > 0
  y <- y[valid]
  treated <- treated[valid]
  weight <- weight[valid]
  result <- data.frame(
    n = length(y), rate_trt = weighted.mean(y[treated == 1], weight[treated == 1]),
    rate_ctl = weighted.mean(y[treated == 0], weight[treated == 0]),
    or = NA_real_, or_ci_lo = NA_real_, or_ci_hi = NA_real_, or_p = NA_real_,
    rd = NA_real_, rd_ci_lo = NA_real_, rd_ci_hi = NA_real_, rd_p = NA_real_
  )
  dat <- data.frame(y = y, treated = treated, weight = weight)
  fit_or <- tryCatch(glm(y ~ treated, data = dat, weights = weight,
                         family = quasibinomial()), error = function(e) NULL)
  fit_rd <- tryCatch(lm(y ~ treated, data = dat, weights = weight),
                     error = function(e) NULL)
  for (kind in c("or", "rd")) {
    fit <- if (kind == "or") fit_or else fit_rd
    if (is.null(fit)) next
    ct <- safe_hc1(fit)
    if (is.null(ct) || !("treated" %in% rownames(ct))) next
    b <- ct["treated", 1]
    se <- ct["treated", 2]
    if (kind == "or") {
      result$or <- exp(b)
      result$or_ci_lo <- exp(b - 1.96 * se)
      result$or_ci_hi <- exp(b + 1.96 * se)
      result$or_p <- ct["treated", ncol(ct)]
    } else {
      result$rd <- b
      result$rd_ci_lo <- b - 1.96 * se
      result$rd_ci_hi <- b + 1.96 * se
      result$rd_p <- ct["treated", ncol(ct)]
    }
  }
  result
}

cat(sprintf("probe_albumin_trigger_estimand.R | %s | START\n", db))
all_pts <- safe_read(sprintf("did_all_%s.csv", tag))
cr_all <- safe_read(sprintf("did_cr_all_%s.csv", tag))
labs <- safe_read(sprintf("did_labs_all_%s.csv", tag))
cr_id <- if ("patientunitstayid" %in% names(cr_all)) "patientunitstayid" else "stay_id"
lab_id <- if ("patientunitstayid" %in% names(labs)) "patientunitstayid" else "stay_id"
cr_all$pid <- cr_all[[cr_id]]
labs$pid <- labs[[lab_id]]
cr_all <- cr_all[order(cr_all$pid, cr_all$offset_h, -cr_all$labresult), ]
cr_list <- split(cr_all[, c("labresult", "offset_h")], cr_all$pid)
all_pts <- build_covariates(all_pts, labs)
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
cat(sprintf("  eligible treated: %d/%d\n", length(treated_ok), length(treated_all)))

# Part 1: threshold sweep, each cut refits the PS and rematches.
threshold_balance <- list()
threshold_effects <- list()
threshold_prevalence <- list()
for (cut in CUTS) {
  dat <- set_alb_cat(all_pts, cut)
  ps_vars <- usable_vars(dat, main_ps_vars(tag, "pooled", "primary"))
  fit <- match_risk_set(
    dat, cr_list, treated_ok, ps_vars, rep(TRUE, nrow(dat)),
    sprintf("threshold %.1f", cut)
  )
  outcomes <- make_pair_outcomes(fit$pairs, fit$analysis, cr_list)
  threshold_effects[[length(threshold_effects) + 1L]] <- matched_effects(
    fit, outcomes, "threshold_sweep", "Overall", cut
  )
  threshold_balance[[length(threshold_balance) + 1L]] <- data.frame(
    db = db, cut = cut, variable_code = names(fit$smds),
    variable = covariate_display_label(names(fit$smds)),
    raw_smd = as.numeric(fit$raw_smds), smd = as.numeric(fit$smds),
    matched = nrow(fit$pairs), treated_eligible = length(treated_ok),
    match_rate = fit$match_rate, max_smd = max(fit$smds),
    n_viol = length(fit$violations), mice_m = M_IMP,
    mice_logged_events = fit$logged_events
  )
  source_groups <- list(
    overall = seq_len(nrow(dat)),
    treated_source = which(dat$treated == 1),
    control_source = which(dat$treated == 0),
    treated_eligible = treated_ok,
    matched_treated = fit$pairs$trt_idx,
    matched_control = fit$pairs$ctl_idx
  )
  for (population in names(source_groups)) {
    idx <- source_groups[[population]]
    measured <- !is.na(dat$last_albumin[idx])
    low <- measured & dat$last_albumin[idx] < cut
    threshold_prevalence[[length(threshold_prevalence) + 1L]] <- data.frame(
      db = db, cut = cut, population = population, n = length(idx),
      albumin_measured_n = sum(measured),
      albumin_measured_prevalence = mean(measured), low_n = sum(low),
      low_prevalence_all = mean(low),
      low_prevalence_measured = if (sum(measured)) mean(low[measured]) else NA_real_
    )
  }
}

# Part 2: albumin-stratified matching at the frozen 3.5-g/dL cut.
dat35 <- set_alb_cat(all_pts, 3.5)
strat_balance <- list()
strat_effects <- list()
strat_fits <- list()
strat_outcomes <- list()
for (stratum in c("low", "normal", "missing")) {
  allowed <- as.character(dat35$alb_cat) == stratum
  trt_idx <- treated_ok[allowed[treated_ok]]
  ps_vars <- setdiff(main_ps_vars(tag, "pooled", "primary"), "alb_cat")
  ps_vars <- usable_vars(dat35[allowed, , drop = FALSE], ps_vars)
  fit <- match_risk_set(
    dat35, cr_list, trt_idx, ps_vars, allowed,
    sprintf("albumin stratum %s", stratum)
  )
  outcomes <- make_pair_outcomes(fit$pairs, fit$analysis, cr_list)
  strat_fits[[stratum]] <- fit
  strat_outcomes[[stratum]] <- outcomes
  strat_effects[[length(strat_effects) + 1L]] <- matched_effects(
    fit, outcomes, "albumin_stratified", stratum, 3.5
  )
  strat_balance[[length(strat_balance) + 1L]] <- data.frame(
    db = db, cut = 3.5, stratum = stratum,
    variable_code = names(fit$smds),
    variable = covariate_display_label(names(fit$smds)),
    raw_smd = as.numeric(fit$raw_smds), smd = as.numeric(fit$smds),
    matched = nrow(fit$pairs), treated_eligible = length(trt_idx),
    match_rate = fit$match_rate, max_smd = max(fit$smds),
    n_viol = length(fit$violations), mice_m = M_IMP,
    mice_logged_events = fit$logged_events
  )
}

all_pairs <- do.call(rbind, lapply(names(strat_fits), function(s) {
  cbind(stratum = s, strat_fits[[s]]$pairs)
}))
all_outcomes <- do.call(rbind, lapply(names(strat_outcomes), function(s) {
  cbind(stratum = s, strat_outcomes[[s]])
}))
interaction_rows <- list()
union_viol <- unique(unlist(lapply(strat_fits, `[[`, "violations")))
combined_analysis <- dat35
for (s in names(strat_fits)) {
  idx <- which(as.character(dat35$alb_cat) == s)
  vars <- setdiff(names(strat_fits[[s]]$analysis), names(combined_analysis))
  if (length(vars)) combined_analysis[vars] <- strat_fits[[s]]$analysis[vars]
  common <- intersect(union_viol, names(combined_analysis))
  combined_analysis[idx, common] <- strat_fits[[s]]$analysis[idx, common, drop = FALSE]
}
adj_t <- if (length(union_viol)) {
  combined_analysis[all_pairs$trt_idx, union_viol, drop = FALSE]
} else NULL
adj_c <- if (length(union_viol)) {
  combined_analysis[all_pairs$ctl_idx, union_viol, drop = FALSE]
} else NULL
for (outcome in OUTCOMES) {
  x <- interaction_or_rd(
    all_outcomes[[paste0(outcome, "_trt")]],
    all_outcomes[[paste0(outcome, "_ctl")]],
    all_pairs$stratum, adj_t, adj_c
  )
  interaction_rows[[length(interaction_rows) + 1L]] <- cbind(
    data.frame(db = db, cut = 3.5, outcome = outcome), x
  )
}

# Part 3: conventional patient-level stabilized IPTW ATE association.
# A common treatment-decision T0 does not exist for never-treated patients in
# the frozen risk-set data. Therefore this deliberately different estimand uses
# each treated patient's first-albumin T0 and each never-treated patient's
# earliest qualifying ICU-creatinine reference as its index. It is labeled an
# associational ATE sensitivity and is never pooled with the matched estimand.
iptw_dat <- set_alb_cat(all_pts, 3.5)
control_idx <- which(
  iptw_dat$treated == 0 & !is.na(iptw_dat$cr_ref_early_offset_h) &
    iptw_dat$icu_discharge_h > iptw_dat$cr_ref_early_offset_h &
    (is.na(iptw_dat$death_offset_h) |
       iptw_dat$death_offset_h > iptw_dat$cr_ref_early_offset_h)
)
eligible_idx <- c(treated_ok, control_idx)
iptw_dat <- iptw_dat[eligible_idx, , drop = FALSE]
ps_vars <- usable_vars(iptw_dat, main_ps_vars(tag, "pooled", "primary"))
ps_out <- average_ps(iptw_dat, ps_vars)
iptw_dat <- ps_out$completed
iptw_dat$ps <- ps_out$ps
if (any(!is.finite(iptw_dat$ps)) || any(iptw_dat$ps <= 0) ||
    any(iptw_dat$ps >= 1)) {
  stop("IPTW positivity failure: non-finite or boundary propensity score")
}
p_treated <- mean(iptw_dat$treated == 1)
iptw_dat$sw <- ifelse(
  iptw_dat$treated == 1,
  p_treated / iptw_dat$ps,
  (1 - p_treated) / (1 - iptw_dat$ps)
)

iptw_outcomes <- matrix(NA_integer_, nrow(iptw_dat), length(OUTCOMES),
                        dimnames = list(NULL, OUTCOMES))
for (i in seq_len(nrow(iptw_dat))) {
  pid <- as.character(iptw_dat$pid[i])
  if (iptw_dat$treated[i] == 1) {
    t0 <- iptw_dat$alb_offset_h[i]
    baseline <- max_at_latest_before(
      cr_list[[pid]], t0, iptw_dat$baseline_cr[i],
      iptw_dat$baseline_cr_offset_h[i]
    )["value"]
  } else {
    t0 <- iptw_dat$cr_ref_early_offset_h[i]
    baseline <- iptw_dat$cr_ref_early[i]
  }
  out <- scr_kdigo_outcomes(
    cr_list[[pid]], baseline, t0, iptw_dat$rrt_offset_h[i]
  )
  iptw_outcomes[i, ] <- out[OUTCOMES]
}

iptw_balance <- data.frame(
  db = db, analysis = "stabilized_iptw_ate", variable_code = ps_vars,
  variable = covariate_display_label(ps_vars),
  raw_smd = vapply(ps_vars, function(v) {
    smd_one(iptw_dat[[v]][iptw_dat$treated == 1],
            iptw_dat[[v]][iptw_dat$treated == 0])
  }, numeric(1)),
  weighted_smd = vapply(ps_vars, function(v) {
    weighted_smd(iptw_dat[[v]], iptw_dat$treated, iptw_dat$sw)
  }, numeric(1))
)
iptw_effects <- list()
for (outcome in OUTCOMES) {
  y <- iptw_outcomes[, outcome]
  est <- weighted_or_rd(y, iptw_dat$treated, iptw_dat$sw)
  events_t <- sum(y[iptw_dat$treated == 1], na.rm = TRUE)
  events_c <- sum(y[iptw_dat$treated == 0], na.rm = TRUE)
  iptw_effects[[length(iptw_effects) + 1L]] <- cbind(
    data.frame(
      db = db, analysis = "stabilized_iptw_ate", outcome = outcome,
      events_trt = events_t, events_ctl = events_c,
      sparse_lt20 = events_t < 20 || events_c < 20,
      n_treated = sum(iptw_dat$treated == 1),
      n_control = sum(iptw_dat$treated == 0),
      ess_total = sum(iptw_dat$sw)^2 / sum(iptw_dat$sw^2),
      ess_treated = sum(iptw_dat$sw[iptw_dat$treated == 1])^2 /
        sum(iptw_dat$sw[iptw_dat$treated == 1]^2),
      ess_control = sum(iptw_dat$sw[iptw_dat$treated == 0])^2 /
        sum(iptw_dat$sw[iptw_dat$treated == 0]^2),
      max_weighted_smd = max(iptw_balance$weighted_smd),
      n_weighted_viol = sum(iptw_balance$weighted_smd > 0.10),
      mice_m = M_IMP, mice_logged_events = ps_out$logged_events
    ), est
  )
}
iptw_weights <- data.frame(
  db = db, analysis = "stabilized_iptw_ate",
  treatment_prevalence = p_treated,
  n_treated = sum(iptw_dat$treated == 1),
  n_control = sum(iptw_dat$treated == 0),
  weight_min = min(iptw_dat$sw),
  weight_p01 = unname(quantile(iptw_dat$sw, 0.01)),
  weight_median = median(iptw_dat$sw),
  weight_p99 = unname(quantile(iptw_dat$sw, 0.99)),
  weight_max = max(iptw_dat$sw),
  ess_total = sum(iptw_dat$sw)^2 / sum(iptw_dat$sw^2),
  ess_treated = sum(iptw_dat$sw[iptw_dat$treated == 1])^2 /
    sum(iptw_dat$sw[iptw_dat$treated == 1]^2),
  ess_control = sum(iptw_dat$sw[iptw_dat$treated == 0])^2 /
    sum(iptw_dat$sw[iptw_dat$treated == 0]^2),
  max_raw_smd = max(iptw_balance$raw_smd),
  max_weighted_smd = max(iptw_balance$weighted_smd),
  n_weighted_viol = sum(iptw_balance$weighted_smd > 0.10),
  index_contract = paste0(
    "treated:first albumin; never-treated:earliest qualifying ICU Cr; ",
    "associational patient-level ATE sensitivity"
  )
)

outputs <- list(
  trigger_threshold_balance = do.call(rbind, threshold_balance),
  trigger_threshold_prevalence = do.call(rbind, threshold_prevalence),
  trigger_threshold_effects = do.call(rbind, threshold_effects),
  albumin_stratified_balance = do.call(rbind, strat_balance),
  albumin_stratified_effects = do.call(rbind, strat_effects),
  albumin_stratified_interaction = do.call(rbind, interaction_rows),
  iptw_ate_balance = iptw_balance,
  iptw_ate_effects = do.call(rbind, iptw_effects),
  iptw_ate_weights = iptw_weights
)
for (stem in names(outputs)) {
  write.csv(outputs[[stem]], file.path(RESULTS, sprintf("%s_%s.csv", stem, tag)),
            row.names = FALSE)
}
cat(sprintf(
  paste0(
    "probe_albumin_trigger_estimand.R | %s | COMPLETE | ",
    "thresholds=%d strata=%d IPTW_N=%d\n"
  ),
  db, length(CUTS), length(strat_fits), nrow(iptw_dat)
))
