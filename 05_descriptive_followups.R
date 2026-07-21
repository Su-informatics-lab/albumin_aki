#!/usr/bin/env Rscript
# Entry-42 descriptive secondary analyses. Frozen v3.3 pairs are reused.
# Usage: Rscript 05_descriptive_followups.R {mimic|eicu} {volume|make}

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2 ||
    !(tolower(args[1]) %in% c("mimic", "eicu")) ||
    !(tolower(args[2]) %in% c("volume", "make"))) {
  stop("Usage: Rscript 05_descriptive_followups.R {mimic|eicu} {volume|make}")
}
tag <- tolower(args[1])
mode <- tolower(args[2])
if (mode == "volume" && tag != "mimic") {
  stop("eICU volume is not source-validated; MIMIC volume only")
}
db <- toupper(tag)
RESULTS <- path.expand(Sys.getenv(
  "ALBUMIN_AKI_RESULTS", unset = "~/albumin_aki/results"
))
M_IMP <- 20L
SEED <- 2026L
file_arg <- sub("^--file=", "", grep(
  "^--file=", commandArgs(trailingOnly = FALSE), value = TRUE
)[1])
script_dir <- dirname(normalizePath(file_arg))
source(file.path(script_dir, "R", "causal_helpers.R"))
source(file.path(script_dir, "R", "covariate_registry.R"))

safe_read <- function(name) {
  path <- file.path(RESULTS, name)
  if (!file.exists(path)) stop("Required Entry-42 input missing: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

build_covariates <- function(all_pts, labs, tag) {
  if (!("pid" %in% names(labs))) {
    lab_id <- if ("patientunitstayid" %in% names(labs)) {
      "patientunitstayid"
    } else if ("stay_id" %in% names(labs)) {
      "stay_id"
    } else {
      stop("Lab stream has no recognized patient identifier")
    }
    labs$pid <- labs[[lab_id]]
  }
  index_h <- ifelse(
    !is.na(all_pts$alb_offset_h),
    all_pts$alb_offset_h,
    all_pts$cr_ref_early_offset_h
  )
  index <- data.frame(pid = all_pts$pid, index_h = index_h)
  for (lab in c("albumin", "lactate", "heartrate", "hemoglobin")) {
    z <- last_value_before_index(labs, index, lab_name = lab)
    all_pts[[paste0("last_", lab)]] <- z[as.character(all_pts$pid)]
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
  if (tag == "mimic") {
    index <- data.frame(pid = all_pts$pid, index_h = index_h)
    vent <- safe_read("strm_vent_mimic.csv")
    vaso <- safe_read("strm_vaso_mimic.csv")
    map_stream <- safe_read("strm_map_mimic.csv")
    all_pts$vent_at_t0 <- state_at_index(vent, index)[as.character(all_pts$pid)]
    all_pts$vaso_at_t0 <- state_at_index(vaso, index)[as.character(all_pts$pid)]
    z <- last_value_before_index(
      transform(map_stream, value = map), index, value_col = "value"
    )
    all_pts$map_before_t0 <- z[as.character(all_pts$pid)]
  }
  all_pts
}

numeric_imputations <- function(dat, vars, m = M_IMP) {
  numeric_vars <- vars[!vapply(
    dat[vars], function(x) is.factor(x) || is.character(x), logical(1)
  )]
  base <- dat[, numeric_vars, drop = FALSE]
  impute_vars <- numeric_vars[vapply(
    numeric_vars, function(v) any(is.na(base[[v]])), logical(1)
  )]
  if (!length(impute_vars)) return(rep(list(base), m))
  methods <- rep("", ncol(base)); names(methods) <- names(base)
  methods[impute_vars] <- "pmm"
  set.seed(SEED)
  imp <- mice(base, m = m, method = methods, maxit = 10, printFlag = FALSE)
  lapply(seq_len(m), function(i) complete(imp, i))
}

complete_like_frozen <- function(dat, vars) {
  numeric_vars <- vars[!vapply(
    dat[vars], function(x) is.factor(x) || is.character(x), logical(1)
  )]
  base <- dat[, c("treated", numeric_vars), drop = FALSE]
  impute_vars <- numeric_vars[vapply(
    numeric_vars, function(v) any(is.na(base[[v]])), logical(1)
  )]
  if (length(impute_vars)) {
    methods <- rep("", ncol(base)); names(methods) <- names(base)
    methods[impute_vars] <- "pmm"
    set.seed(SEED)
    imp <- mice(
      base, m = M_IMP, method = methods, maxit = 10, printFlag = FALSE
    )
    completed <- complete(imp, 1)
  } else {
    completed <- base
  }
  dat[numeric_vars] <- completed[numeric_vars]
  dat
}

hc1_term <- function(fit, term) {
  ct <- safe_hc1(fit)
  if (is.null(ct) || !(term %in% rownames(ct))) {
    return(c(estimate = NA_real_, variance = NA_real_))
  }
  c(estimate = ct[term, 1], variance = ct[term, 2]^2)
}

rubin_pool <- function(estimates, variances) {
  ok <- is.finite(estimates) & is.finite(variances)
  q <- estimates[ok]; u <- variances[ok]; m <- length(q)
  if (!m) return(c(est = NA_real_, se = NA_real_, p = NA_real_))
  qbar <- mean(q); ubar <- mean(u)
  b <- if (m > 1) var(q) else 0
  total <- ubar + (1 + 1 / m) * b
  se <- sqrt(total)
  c(est = qbar, se = se, p = 2 * pnorm(-abs(qbar / se)))
}

fit_mi_term <- function(dat, completed, outcome, formula, term, scale) {
  estimates <- variances <- rep(NA_real_, length(completed))
  for (i in seq_along(completed)) {
    x <- dat
    x[names(completed[[i]])] <- completed[[i]]
    fit <- tryCatch(
      if (scale == "OR") {
        glm(formula, data = x, family = quasibinomial())
      } else {
        lm(formula, data = x)
      },
      error = function(e) NULL
    )
    if (!is.null(fit)) {
      z <- hc1_term(fit, term)
      estimates[i] <- z["estimate"]
      variances[i] <- z["variance"]
    }
  }
  z <- rubin_pool(estimates, variances)
  est <- z["est"]; se <- z["se"]
  data.frame(
    scale = scale,
    estimate = if (scale == "OR") exp(est) else est,
    ci_lo = if (scale == "OR") exp(est - 1.96 * se) else est - 1.96 * se,
    ci_hi = if (scale == "OR") exp(est + 1.96 * se) else est + 1.96 * se,
    p = z["p"],
    imputations = sum(is.finite(estimates))
  )
}

run_volume <- function() {
  all_pts <- safe_read("did_all_mimic.csv")
  labs <- safe_read("did_labs_all_mimic.csv")
  all_pts <- build_covariates(all_pts, labs, "mimic")
  pairs <- safe_read("did_pairs_primary_yet_untreated_pooled_mimic.csv")
  if (anyDuplicated(pairs$trt_pid)) stop("MIMIC pooled treated IDs are not unique")
  rows <- match(pairs$trt_pid, all_pts$pid)
  if (anyNA(rows)) stop("MIMIC treated pair IDs do not map to did_all")
  dat <- all_pts[rows, , drop = FALSE]
  dose <- safe_read("did_albumin_volume_24h_mimic.csv")
  dat$volume_ml <- dose$albumin_volume_ml_24h[match(dat$pid, dose$pid)]
  if (anyNA(dat$volume_ml) || any(dat$volume_ml < 0)) {
    stop("MIMIC volume is missing or negative for a matched treated patient")
  }
  for (outcome in c("aki1_48h", "aki2_48h", "aki1_7d", "aki2_7d")) {
    dat[[outcome]] <- pairs[[paste0(outcome, "_trt")]]
  }
  qs <- unname(quantile(dat$volume_ml, c(.25, 1/3, .5, 2/3, .75), type = 7))
  q1 <- qs[2]; q2 <- qs[4]
  if (!is.finite(q1) || !is.finite(q2) || q1 >= q2) {
    stop(sprintf("Volume tertiles collapse: cut1=%s cut2=%s", q1, q2))
  }
  dat$volume_tertile <- cut(
    dat$volume_ml, breaks = c(-Inf, q1, q2, Inf),
    labels = c("T1", "T2", "T3"), include.lowest = TRUE
  )
  iqr_ml <- IQR(dat$volume_ml)
  if (!is.finite(iqr_ml) || iqr_ml <= 0) stop("Volume IQR is not positive")
  dat$volume_per_250 <- dat$volume_ml / 250
  dat$volume_per_iqr <- dat$volume_ml / iqr_ml
  ps_vars <- main_ps_vars("mimic", "pooled", "primary")
  completed <- numeric_imputations(dat, ps_vars, M_IMP)
  adjustment <- paste(ps_vars, collapse = " + ")

  distribution <- data.frame(
    database = "MIMIC", population = "frozen pooled matched treated",
    window = "delivered volume in (T0,T0+24h]",
    n = nrow(dat), positive_volume_n = sum(dat$volume_ml > 0),
    zero_volume_n = sum(dat$volume_ml == 0), min_ml = min(dat$volume_ml),
    p25_ml = quantile(dat$volume_ml, .25), median_ml = median(dat$volume_ml),
    p75_ml = quantile(dat$volume_ml, .75), max_ml = max(dat$volume_ml),
    iqr_ml = iqr_ml, tertile_cut1_ml = q1, tertile_cut2_ml = q2
  )

  rate_rows <- list(); model_rows <- list()
  for (outcome in c("aki1_48h", "aki2_48h", "aki1_7d", "aki2_7d")) {
    for (level in levels(dat$volume_tertile)) {
      idx <- dat$volume_tertile == level & !is.na(dat[[outcome]])
      events <- sum(dat[[outcome]][idx])
      rate_rows[[length(rate_rows) + 1L]] <- data.frame(
        db = "MIMIC", outcome = outcome, volume_tertile = level,
        n = sum(idx), events = events, rate = mean(dat[[outcome]][idx]),
        sparse_lt20 = events < 20
      )
    }
    specifications <- list(
      per_250ml = list(variable = "volume_per_250", term = "volume_per_250"),
      per_iqr = list(variable = "volume_per_iqr", term = "volume_per_iqr"),
      tertile_T2_vs_T1 = list(variable = "volume_tertile", term = "volume_tertileT2"),
      tertile_T3_vs_T1 = list(variable = "volume_tertile", term = "volume_tertileT3")
    )
    for (spec in names(specifications)) {
      s <- specifications[[spec]]
      form <- as.formula(sprintf("%s ~ %s + %s", outcome, s$variable, adjustment))
      for (scale in c("OR", "RD")) {
        z <- fit_mi_term(dat, completed, outcome, form, s$term, scale)
        relevant <- if (grepl("T2", spec)) "T2" else if (grepl("T3", spec)) "T3" else NA
        sparse <- if (is.na(relevant)) {
          sum(dat[[outcome]], na.rm = TRUE) < 20
        } else {
          events <- rate_rows[[match(
            paste(outcome, relevant),
            vapply(rate_rows, function(r) paste(r$outcome, r$volume_tertile), character(1))
          )]]$events
          ref_events <- rate_rows[[match(
            paste(outcome, "T1"),
            vapply(rate_rows, function(r) paste(r$outcome, r$volume_tertile), character(1))
          )]]$events
          events < 20 || ref_events < 20
        }
        model_rows[[length(model_rows) + 1L]] <- cbind(
          data.frame(
            db = "MIMIC", population = "within_treated",
            outcome = outcome, specification = spec,
            method = "covariate_adjusted_mice20_hc1",
            n = sum(!is.na(dat[[outcome]])),
            events = sum(dat[[outcome]], na.rm = TRUE),
            sparse_lt20 = sparse
          ), z
        )
      }
    }
  }

  severity <- list()
  for (v in c("vaso_at_t0", "vent_at_t0")) {
    for (level in c(0, 1)) {
      x <- dat$volume_ml[!is.na(dat[[v]]) & dat[[v]] == level]
      severity[[length(severity) + 1L]] <- data.frame(
        db = "MIMIC", severity_axis = v, summary_type = "binary_group",
        level = as.character(level), n = length(x), median_volume_ml = median(x),
        p25_volume_ml = quantile(x, .25), p75_volume_ml = quantile(x, .75),
        spearman_rho = NA_real_, p = NA_real_
      )
    }
    p <- suppressWarnings(wilcox.test(dat$volume_ml ~ dat[[v]])$p.value)
    severity[[length(severity) - 1L]]$p <- p
    severity[[length(severity)]]$p <- p
  }
  for (v in c("map_before_t0", "last_lactate")) {
    ok <- is.finite(dat$volume_ml) & is.finite(dat[[v]])
    test <- suppressWarnings(cor.test(
      dat$volume_ml[ok], dat[[v]][ok], method = "spearman", exact = FALSE
    ))
    severity[[length(severity) + 1L]] <- data.frame(
      db = "MIMIC", severity_axis = v, summary_type = "spearman",
      level = "continuous", n = sum(ok), median_volume_ml = NA_real_,
      p25_volume_ml = NA_real_, p75_volume_ml = NA_real_,
      spearman_rho = unname(test$estimate), p = test$p.value
    )
  }
  comparison <- data.frame(
    database = c("MIMIC", "eICU"), volume_supported = c(TRUE, FALSE),
    median_volume_ml = c(distribution$median_ml, NA_real_),
    p25_volume_ml = c(distribution$p25_ml, NA_real_),
    p75_volume_ml = c(distribution$p75_ml, NA_real_),
    reason = c(
      "inputevents.amount source-audited as mL volume",
      paste(
        "not computed: exposure combines medication and intakeOutput text rows;",
        "no source-validated uniform infused-mL administration field"
      )
    )
  )
  write.csv(distribution, file.path(RESULTS, "volume_24h_distribution_mimic.csv"), row.names = FALSE)
  write.csv(do.call(rbind, rate_rows), file.path(RESULTS, "volume_24h_tertile_rates_mimic.csv"), row.names = FALSE)
  write.csv(do.call(rbind, model_rows), file.path(RESULTS, "volume_24h_dose_response_mimic.csv"), row.names = FALSE)
  write.csv(do.call(rbind, severity), file.path(RESULTS, "volume_24h_severity_mimic.csv"), row.names = FALSE)
  write.csv(comparison, file.path(RESULTS, "volume_24h_database_support.csv"), row.names = FALSE)
  cat(sprintf("Entry42 volume COMPLETE: n=%d median=%.1f IQR=%.1f-%.1f\n",
              nrow(dat), median(dat$volume_ml), quantile(dat$volume_ml, .25),
              quantile(dat$volume_ml, .75)))
}

compose_make <- function(aki2, rrt, death) {
  as.integer(aki2 == 1L | rrt == 1L | death == 1L)
}

run_make <- function() {
  all_pts <- safe_read(sprintf("did_all_%s.csv", tag))
  labs <- safe_read(sprintf("did_labs_all_%s.csv", tag))
  all_pts <- build_covariates(all_pts, labs, tag)
  rrt_map <- setNames(all_pts$rrt_offset_h, as.character(all_pts$pid))
  output <- list(); integrity <- list()
  for (variant in c("pooled", "egfr")) {
    pairs <- safe_read(sprintf(
      "did_pairs_primary_yet_untreated_%s_%s.csv", variant, tag
    ))
    balance <- safe_read(sprintf("psm_balance_%s_%s.csv", variant, tag))
    canonical <- safe_read(sprintf("did_binary_%s_%s.csv", variant, tag))
    strata <- unique(pairs$stratum)
    completed_by_stratum <- list()
    for (stratum in strata) {
      ps_vars <- main_ps_vars(tag, variant, "primary")
      subset <- if (variant == "pooled") rep(TRUE, nrow(all_pts)) else {
        egfr_stratum(all_pts$egfr) == stratum
      }
      completed_by_stratum[[stratum]] <- complete_like_frozen(
        all_pts[subset, , drop = FALSE], ps_vars
      )
      completed_by_stratum[[stratum]]$.original_row <- which(subset)
    }
    for (stratum in strata) {
      p <- pairs[pairs$stratum == stratum, , drop = FALSE]
      source_completed <- completed_by_stratum[[stratum]]
      lookup <- setNames(seq_len(nrow(source_completed)), source_completed$.original_row)
      tr <- as.integer(lookup[as.character(p$trt_idx)])
      ct <- as.integer(lookup[as.character(p$ctl_idx)])
      if (anyNA(tr) || anyNA(ct)) stop("Pair indices do not map to completed covariates")
      violations <- balance$variable_code[
        balance$stratum == stratum & balance$smd > 0.10
      ]
      for (horizon in c("48h", "7d")) {
        hours <- if (horizon == "48h") 48 else 168
        aki_t <- p[[paste0("aki2_", horizon, "_trt")]]
        aki_c <- p[[paste0("aki2_", horizon, "_ctl")]]
        bridge_t <- p[[paste0("aki2_rrt_", horizon, "_trt")]]
        bridge_c <- p[[paste0("aki2_rrt_", horizon, "_ctl")]]
        death_t <- p[[paste0("death_", horizon, "_all_trt")]]
        death_c <- p[[paste0("death_", horizon, "_all_ctl")]]
        rrt_t <- as.integer(
          !is.na(rrt_map[as.character(p$trt_pid)]) &
            rrt_map[as.character(p$trt_pid)] > p$t0 &
            rrt_map[as.character(p$trt_pid)] <= p$t0 + hours
        )
        rrt_c <- as.integer(
          !is.na(rrt_map[as.character(p$ctl_pid)]) &
            rrt_map[as.character(p$ctl_pid)] > p$t0 &
            rrt_map[as.character(p$ctl_pid)] <= p$t0 + hours
        )
        valid <- !is.na(bridge_t) & !is.na(bridge_c)
        reconstructed_t <- as.integer(aki_t == 1L | rrt_t == 1L)
        reconstructed_c <- as.integer(aki_c == 1L | rrt_c == 1L)
        if (any(bridge_t[valid] != reconstructed_t[valid]) ||
            any(bridge_c[valid] != reconstructed_c[valid])) {
          stop("AKI>=2 OR RRT does not reconcile to frozen aki2_rrt")
        }
        aki_t[!valid] <- aki_c[!valid] <- NA_integer_
        rrt_t[!valid] <- rrt_c[!valid] <- NA_integer_
        death_t[!valid] <- death_c[!valid] <- NA_integer_
        make_t <- make_c <- rep(NA_integer_, nrow(p))
        make_t[valid] <- compose_make(aki_t[valid], rrt_t[valid], death_t[valid])
        make_c[valid] <- compose_make(aki_c[valid], rrt_c[valid], death_c[valid])
        outcome_values <- list(
          make = list(make_t, make_c),
          aki2 = list(aki_t, aki_c),
          new_rrt = list(rrt_t, rrt_c),
          death = list(death_t, death_c)
        )
        for (outcome in names(outcome_values)) {
          y_t <- outcome_values[[outcome]][[1]]
          y_c <- outcome_values[[outcome]][[2]]
          for (method in c("psm", if (length(violations)) "dr")) {
            adj_t <- adj_c <- NULL
            if (method == "dr") {
              adj_t <- source_completed[tr, violations, drop = FALSE]
              adj_c <- source_completed[ct, violations, drop = FALSE]
            }
            z <- pair_or_rd(y_t, y_c, adj_t, adj_c)
            ok <- !is.na(y_t) & !is.na(y_c)
            output[[length(output) + 1L]] <- cbind(
              data.frame(
                db = db, variant = variant, stratum = stratum,
                horizon = horizon, outcome = outcome, method = method,
                composition = if (outcome == "make") {
                  "AKI stage>=2 OR new RRT OR fixed-window death"
                } else NA_character_,
                events_trt = sum(y_t[ok]), events_ctl = sum(y_c[ok]),
                sparse_lt20 = sum(y_t[ok]) < 20 || sum(y_c[ok]) < 20
              ), z
            )
          }
        }
        # Reproduce the frozen bridge estimate before trusting the new composite.
        for (method in c("psm", if (length(violations)) "dr")) {
          adj_t <- adj_c <- NULL
          if (method == "dr") {
            adj_t <- source_completed[tr, violations, drop = FALSE]
            adj_c <- source_completed[ct, violations, drop = FALSE]
          }
          got <- pair_or_rd(bridge_t, bridge_c, adj_t, adj_c)
          ref <- canonical[
            canonical$stratum == stratum &
              canonical$outcome == paste0("aki2_rrt_", horizon) &
              canonical$method == method,
          ]
          pass <- nrow(ref) == 1 &&
            (is.na(ref$or) && is.na(got$or) || abs(ref$or - got$or) < 1e-8) &&
            (is.na(ref$rd) && is.na(got$rd) || abs(ref$rd - got$rd) < 1e-8)
          integrity[[length(integrity) + 1L]] <- data.frame(
            db = db, variant = variant, stratum = stratum,
            horizon = horizon, method = method,
            frozen_or = if (nrow(ref)) ref$or else NA_real_,
            rebuilt_or = got$or,
            frozen_rd = if (nrow(ref)) ref$rd else NA_real_,
            rebuilt_rd = got$rd, pass = pass
          )
          if (!pass) stop("Frozen aki2_rrt estimator integrity check failed")
        }
      }
    }
  }
  write.csv(do.call(rbind, output),
            file.path(RESULTS, sprintf("make_components_%s.csv", tag)),
            row.names = FALSE)
  write.csv(do.call(rbind, integrity),
            file.path(RESULTS, sprintf("make_integrity_%s.csv", tag)),
            row.names = FALSE)
  cat(sprintf("Entry42 MAKE COMPLETE: %s\n", db))
}

# Static fixtures: exact OR composition and horizon-specific RRT logic.
stopifnot(identical(
  compose_make(c(0L, 1L, 0L, 0L), c(0L, 0L, 1L, 0L), c(0L, 0L, 0L, 1L)),
  c(0L, 1L, 1L, 1L)
))

if (mode == "volume") run_volume() else run_make()
