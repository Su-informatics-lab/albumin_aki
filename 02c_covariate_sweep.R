#!/usr/bin/env Rscript
# Entry 8b MIMIC pooled covariate sweep. No eICU/stratified/HTE execution.

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
})

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(normalizePath(file_arg))
source(file.path(repo, "R", "causal_helpers.R"))
source(file.path(repo, "R", "covariate_registry.R"))

RESULTS <- path.expand("~/albumin_aki/results")
M_IMP <- 5
CALIPER_SD <- 0.2
PRIMARY_H <- 24
SEED <- 2026

safe_read <- function(name) {
  path <- file.path(RESULTS, name)
  if (!file.exists(path)) stop("Required sweep input missing: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

usable_vars <- function(dat, vars) {
  missing <- setdiff(vars, names(dat))
  if (length(missing)) stop("Missing registered variables: ",
                            paste(missing, collapse = ", "))
  keep <- vars[vapply(vars, function(v) {
    x <- dat[[v]]
    if (is.factor(x) || is.character(x)) length(unique(x[!is.na(x)])) > 1
    else !all(is.na(x)) && var(x, na.rm = TRUE) > 1e-10
  }, logical(1))]
  dropped <- setdiff(vars, keep)
  if (length(dropped)) stop("Registered variables constant/all missing: ",
                            paste(dropped, collapse = ", "))
  keep
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

prepare_imputations <- function(dat, vars) {
  numeric_vars <- vars[!vapply(dat[vars], function(x) {
    is.factor(x) || is.character(x)
  }, logical(1))]
  methods <- rep("", length(c("treated", numeric_vars)))
  names(methods) <- c("treated", numeric_vars)
  missing_vars <- numeric_vars[vapply(numeric_vars, function(v) {
    any(is.na(dat[[v]]))
  }, logical(1))]
  methods[missing_vars] <- "pmm"
  set.seed(SEED)
  imp <- mice(
    dat[, c("treated", numeric_vars), drop = FALSE],
    m = M_IMP, method = methods, maxit = 10, printFlag = FALSE
  )
  list(
    numeric_vars = numeric_vars,
    completed = lapply(seq_len(M_IMP), function(m) complete(imp, m)),
    logged_events = if (is.null(imp$loggedEvents)) 0L else nrow(imp$loggedEvents)
  )
}

average_ps <- function(dat, vars, imputed) {
  preds <- matrix(NA_real_, nrow(dat), M_IMP)
  first <- dat
  numeric_vars <- intersect(vars, imputed$numeric_vars)
  for (m in seq_len(M_IMP)) {
    model_dat <- dat[, vars, drop = FALSE]
    model_dat[numeric_vars] <- imputed$completed[[m]][numeric_vars]
    model_dat$treated <- dat$treated
    fit <- suppressWarnings(glm(
      reformulate(vars, response = "treated"),
      data = model_dat, family = binomial()
    ))
    preds[, m] <- predict(fit, newdata = model_dat, type = "response")
    if (m == 1L) first[, vars] <- model_dat[, vars, drop = FALSE]
  }
  list(ps = rowMeans(preds), completed = first)
}

peak_delta <- function(cr_pt, baseline, t0, horizon) {
  if (is.null(cr_pt) || nrow(cr_pt) == 0 || is.na(baseline)) return(0)
  post <- cr_pt[
    cr_pt$offset_h > t0 & cr_pt$offset_h <= t0 + horizon,
    , drop = FALSE
  ]
  if (nrow(post) == 0) return(0)
  max(post$labresult, na.rm = TRUE) - baseline
}

make_outcomes <- function(pairs, all_pts, cr_list) {
  rrt <- setNames(all_pts$rrt_offset_h, as.character(all_pts$pid))
  death <- setNames(all_pts$death_offset_h, as.character(all_pts$pid))
  mortality <- setNames(all_pts$hosp_mortality, as.character(all_pts$pid))
  albumin <- setNames(all_pts$alb_offset_h, as.character(all_pts$pid))
  rows <- vector("list", nrow(pairs))
  for (i in seq_len(nrow(pairs))) {
    tp <- as.character(pairs$trt_pid[i])
    cp <- as.character(pairs$ctl_pid[i])
    t0 <- pairs$t0[i]
    ot <- scr_kdigo_outcomes(
      cr_list[[tp]], pairs$baseline_trt[i], t0, rrt[tp]
    )
    oc <- scr_kdigo_outcomes(
      cr_list[[cp]], pairs$baseline_ctl[i], t0, rrt[cp]
    )
    calb <- albumin[cp]
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
      trt_pid = pairs$trt_pid[i], ctl_pid = pairs$ctl_pid[i], t0 = t0,
      stringsAsFactors = FALSE
    )
    for (name in names(ot)) {
      row[[paste0(name, "_trt")]] <- ot[name]
      row[[paste0(name, "_ctl")]] <- oc[name]
    }
    for (horizon in c(48, 168)) {
      suffix <- if (horizon == 48) "48h" else "7d"
      dt <- fixed_window_death(death[tp], t0, horizon)
      dc <- fixed_window_death(death[cp], t0, horizon)
      row[[paste0("death_", suffix, "_all_trt")]] <- dt
      row[[paste0("death_", suffix, "_all_ctl")]] <- dc
      never <- is.na(calb)
      row[[paste0("death_", suffix, "_never_trt")]] <- if (never) dt else NA
      row[[paste0("death_", suffix, "_never_ctl")]] <- if (never) dc else NA
      crossed <- !is.na(calb) && calb > t0 && calb <= t0 + horizon
      row[[paste0("death_", suffix, "_censored_trt")]] <-
        if (crossed) NA else dt
      row[[paste0("death_", suffix, "_censored_ctl")]] <-
        if (crossed) NA else dc
    }
    row$hosp_mort_descriptive_trt <- as.integer(mortality[tp] == 1)
    row$hosp_mort_descriptive_ctl <- as.integer(mortality[cp] == 1)
    row$delta_cr_48h_trt <- peak_delta(
      cr_list[[tp]], pairs$baseline_trt[i], t0, 48
    )
    row$delta_cr_48h_ctl <- peak_delta(
      cr_list[[cp]], pairs$baseline_ctl[i], t0, 48
    )
    row$delta_cr_7d_trt <- peak_delta(
      cr_list[[tp]], pairs$baseline_trt[i], t0, 168
    )
    row$delta_cr_7d_ctl <- peak_delta(
      cr_list[[cp]], pairs$baseline_ctl[i], t0, 168
    )
    rows[[i]] <- row
  }
  do.call(rbind, rows)
}

cat("02c_covariate_sweep.R | MIMIC pooled | S0-S5\n")
all_pts <- safe_read("did_all_mimic.csv")
cr_all <- safe_read("did_cr_all_mimic.csv")
labs <- safe_read("did_labs_all_mimic.csv")
labs_ext <- safe_read("labs_ext_mimic.csv")
surg <- safe_read("surg_mimic.csv")
vent <- safe_read("strm_vent_mimic.csv")
vaso <- safe_read("strm_vaso_mimic.csv")
map_stream <- safe_read("strm_map_mimic.csv")
blood <- safe_read("strm_blood_mimic.csv")
fluid <- safe_read("strm_fluid_mimic.csv")
output_stream <- safe_read("strm_output_mimic.csv")
cr_all$pid <- cr_all$stay_id
labs$pid <- labs$stay_id
ordered <- cr_all[order(cr_all$pid, cr_all$offset_h, -cr_all$labresult), ]
cr_list <- split(ordered[, c("labresult", "offset_h")], ordered$pid)
all_pts <- build_sweep_covariates(
  all_pts, labs, labs_ext, surg, vent, vaso, map_stream,
  blood, fluid, output_stream
)
rm(labs, labs_ext, surg, vent, vaso, map_stream, blood, fluid, output_stream)
gc()

early_value <- setNames(all_pts$cr_ref_early, as.character(all_pts$pid))
early_offset <- setNames(all_pts$cr_ref_early_offset_h, as.character(all_pts$pid))
all_pts$first_prevalent_h <- vapply(as.character(all_pts$pid), function(pid) {
  first_prevalent_aki_time(cr_list[[pid]], early_value[pid], early_offset[pid])
}, numeric(1))
alive_at <- function(rows, time) {
  is.na(all_pts$death_offset_h[rows]) | all_pts$death_offset_h[rows] > time
}
treated_all <- which(all_pts$treated == 1 & !is.na(all_pts$alb_offset_h))
treated_ok <- treated_all[
  all_pts$cr_ref_early_offset_h[treated_all] <=
    all_pts$alb_offset_h[treated_all] &
    (is.na(all_pts$first_prevalent_h[treated_all]) |
       all_pts$first_prevalent_h[treated_all] >
         all_pts$alb_offset_h[treated_all]) &
    all_pts$icu_discharge_h[treated_all] > all_pts$alb_offset_h[treated_all] &
    alive_at(treated_all, all_pts$alb_offset_h[treated_all])
]
cat(sprintf("  treated eligible: %d/%d\n", length(treated_ok),
            length(treated_all)))

RUN_SETS <- paste0("S", 0:5)
union_vars <- unique(unlist(COVARIATE_SETS[RUN_SETS]))
union_vars <- usable_vars(all_pts, union_vars)
imputed <- prepare_imputations(all_pts, union_vars)
cat(sprintf("  MICE m=%d; logged events=%d\n", M_IMP,
            imputed$logged_events))

binary_outcomes <- c(
  "aki1_48h", "aki2_48h", "aki3_48h",
  "aki1_7d", "aki2_7d", "aki3_7d",
  "aki2_rrt_48h", "aki2_rrt_7d",
  "death_48h_all", "death_48h_never", "death_48h_censored",
  "death_7d_all", "death_7d_never", "death_7d_censored",
  "hosp_mort_descriptive"
)
continuous_outcomes <- c("delta_cr_48h", "delta_cr_7d")
output <- list()

for (set_name in RUN_SETS) {
  vars <- usable_vars(all_pts, COVARIATE_SETS[[set_name]])
  ps <- average_ps(all_pts, vars, imputed)
  analysis <- ps$completed
  analysis$ps <- ps$ps
  caliper <- CALIPER_SD * sd(analysis$ps, na.rm = TRUE)
  matched <- list()
  for (ti in treated_ok) {
    t0 <- analysis$alb_offset_h[ti]
    risk <- which(
      analysis$pid != analysis$pid[ti] &
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
      candidate_baseline <- max_at_latest_before(
        cr_list[[as.character(analysis$pid[ci])]], t0,
        analysis$baseline_cr[ci], analysis$baseline_cr_offset_h[ci]
      )
      if (!is.na(candidate_baseline["value"])) {
        chosen <- ci
        bc <- candidate_baseline
        break
      }
    }
    if (is.na(chosen)) next
    matched[[length(matched) + 1L]] <- data.frame(
      trt_idx = ti, ctl_idx = chosen,
      trt_pid = analysis$pid[ti], ctl_pid = analysis$pid[chosen],
      t0 = t0, baseline_trt = bt["value"], baseline_ctl = bc["value"]
    )
  }
  pairs <- do.call(rbind, matched)
  match_rate <- nrow(pairs) / length(treated_ok)
  if (match_rate < 0.90) {
    stop(sprintf("GUARD: %s match rate %.1f%% below 90%%",
                 set_name, 100 * match_rate))
  }
  smds <- vapply(vars, function(v) {
    smd_one(analysis[[v]][pairs$trt_idx], analysis[[v]][pairs$ctl_idx])
  }, numeric(1))
  violations <- names(smds[smds > 0.10])
  max_smd <- max(smds)
  cat(sprintf("  %s matched %d/%d (%.1f%%), max SMD %.3f, viol %d\n",
              set_name, nrow(pairs), length(treated_ok),
              100 * match_rate, max_smd, length(violations)))
  pair_outcomes <- make_outcomes(pairs, analysis, cr_list)
  for (outcome in binary_outcomes) {
    for (method in c("psm", "dr")) {
      adj_t <- adj_c <- NULL
      if (method == "dr" && length(violations)) {
        adj_t <- analysis[pairs$trt_idx, violations, drop = FALSE]
        adj_c <- analysis[pairs$ctl_idx, violations, drop = FALSE]
      }
      estimate <- pair_or_rd(
        pair_outcomes[[paste0(outcome, "_trt")]],
        pair_outcomes[[paste0(outcome, "_ctl")]],
        adj_t, adj_c
      )
      output[[length(output) + 1L]] <- cbind(
        data.frame(
          set = set_name, outcome = outcome, outcome_type = "binary",
          method = method, match_rate = match_rate, max_smd = max_smd,
          n_viol = length(violations), covariate_count = length(vars),
          mice_logged_events = imputed$logged_events
        ),
        estimate,
        data.frame(
          mean_trt = NA_real_, mean_ctl = NA_real_, did = NA_real_,
          did_ci_lo = NA_real_, did_ci_hi = NA_real_, did_p = NA_real_
        )
      )
    }
  }
  for (outcome in continuous_outcomes) {
    for (method in c("psm", "dr")) {
      adj_t <- adj_c <- NULL
      if (method == "dr" && length(violations)) {
        adj_t <- analysis[pairs$trt_idx, violations, drop = FALSE]
        adj_c <- analysis[pairs$ctl_idx, violations, drop = FALSE]
      }
      estimate <- pair_mean_difference(
        pair_outcomes[[paste0(outcome, "_trt")]],
        pair_outcomes[[paste0(outcome, "_ctl")]],
        adj_t, adj_c
      )
      output[[length(output) + 1L]] <- cbind(
        data.frame(
          set = set_name, outcome = outcome, outcome_type = "continuous",
          method = method, match_rate = match_rate, max_smd = max_smd,
          n_viol = length(violations), covariate_count = length(vars),
          mice_logged_events = imputed$logged_events
        ),
        data.frame(
          n = estimate$n, rate_trt = NA_real_, rate_ctl = NA_real_,
          or = NA_real_, or_ci_lo = NA_real_, or_ci_hi = NA_real_,
          or_p = NA_real_, rd = NA_real_, rd_ci_lo = NA_real_,
          rd_ci_hi = NA_real_, rd_p = NA_real_
        ),
        estimate[, c(
          "mean_trt", "mean_ctl", "did", "did_ci_lo", "did_ci_hi", "did_p"
        )]
      )
    }
  }
}

sweep <- do.call(rbind, output)
write.csv(
  sweep,
  file.path(RESULTS, "covariate_sweep_mimic_pooled.csv"),
  row.names = FALSE
)
cat("02c_covariate_sweep.R | COMPLETE\n")
