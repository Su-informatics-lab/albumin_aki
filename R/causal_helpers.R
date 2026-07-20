# Shared frozen helpers for 02_psm.R, 03_hte.R, and static fixtures.

max_at_latest_before <- function(cr_pt, t0_h, fallback_value = NA_real_,
                                 fallback_offset = NA_real_) {
  if (!is.null(cr_pt) && nrow(cr_pt) > 0) {
    cand <- cr_pt[
      !is.na(cr_pt$offset_h) & cr_pt$offset_h >= 0 & cr_pt$offset_h < t0_h,
      , drop = FALSE
    ]
    if (nrow(cand) > 0) {
      selected_h <- max(cand$offset_h)
      at_time <- cand[cand$offset_h == selected_h, , drop = FALSE]
      return(c(value = max(at_time$labresult, na.rm = TRUE), offset_h = selected_h))
    }
  }
  if (!is.na(fallback_value) && !is.na(fallback_offset) &&
      fallback_offset < t0_h) {
    return(c(value = fallback_value, offset_h = fallback_offset))
  }
  c(value = NA_real_, offset_h = NA_real_)
}

first_prevalent_aki_time <- function(cr_pt, early_value, early_offset) {
  if (is.null(cr_pt) || nrow(cr_pt) == 0 || is.na(early_value) ||
      early_value <= 0 || is.na(early_offset)) {
    return(NA_real_)
  }
  post <- cr_pt[
    !is.na(cr_pt$offset_h) & cr_pt$offset_h > early_offset &
      !is.na(cr_pt$labresult),
    , drop = FALSE
  ]
  if (nrow(post) == 0) return(NA_real_)
  hit <- (post$labresult - early_value >= 0.3) |
    (post$labresult / early_value >= 1.5)
  if (!any(hit, na.rm = TRUE)) return(NA_real_)
  min(post$offset_h[hit], na.rm = TRUE)
}

scr_kdigo_outcomes <- function(cr_pt, baseline, t0_h, rrt_offset_h = NA_real_) {
  out <- c(
    aki1_48h = 0L, aki2_48h = 0L, aki3_48h = 0L,
    aki1_7d = 0L, aki2_7d = 0L, aki3_7d = 0L,
    aki2_rrt_48h = 0L, aki2_rrt_7d = 0L,
    nopost_48h = 1L, nopost_7d = 1L
  )
  if (is.na(baseline) || baseline <= 0) {
    out[] <- NA_integer_
    return(out)
  }
  post <- if (is.null(cr_pt) || nrow(cr_pt) == 0) {
    data.frame(labresult = numeric(), offset_h = numeric())
  } else {
    cr_pt[
      !is.na(cr_pt$offset_h) & cr_pt$offset_h > t0_h &
        cr_pt$offset_h <= t0_h + 168 & !is.na(cr_pt$labresult),
      , drop = FALSE
    ]
  }
  if (nrow(post) > 0) {
    rel_h <- post$offset_h - t0_h
    delta <- post$labresult - baseline
    ratio <- post$labresult / baseline
    stage1 <- (delta >= 0.3 & rel_h <= 48) | ratio >= 1.5
    stage2 <- ratio >= 2
    stage3 <- ratio >= 3 | (post$labresult >= 4 & delta >= 0.3)
    in48 <- rel_h <= 48
    out["nopost_48h"] <- as.integer(!any(in48))
    out["nopost_7d"] <- 0L
    out["aki1_48h"] <- as.integer(any(stage1 & in48))
    out["aki2_48h"] <- as.integer(any(stage2 & in48))
    out["aki3_48h"] <- as.integer(any(stage3 & in48))
    out["aki1_7d"] <- as.integer(any(stage1))
    out["aki2_7d"] <- as.integer(any(stage2))
    out["aki3_7d"] <- as.integer(any(stage3))
  }
  rrt48 <- !is.na(rrt_offset_h) && rrt_offset_h > t0_h &&
    rrt_offset_h <= t0_h + 48
  rrt7d <- !is.na(rrt_offset_h) && rrt_offset_h > t0_h &&
    rrt_offset_h <= t0_h + 168
  out["aki2_rrt_48h"] <- as.integer(out["aki2_48h"] == 1L || rrt48)
  out["aki2_rrt_7d"] <- as.integer(out["aki2_7d"] == 1L || rrt7d)
  out
}

egfr_stratum <- function(egfr) {
  factor(
    ifelse(
      is.na(egfr), NA_character_,
      ifelse(egfr >= 90, "G1", ifelse(egfr >= 60, "G2", "G3plus"))
    ),
    levels = c("G1", "G2", "G3plus")
  )
}

eligible_same_stratum <- function(candidate_strata, treated_stratum) {
  !is.na(candidate_strata) & candidate_strata == treated_stratum
}

safe_hc1 <- function(fit) {
  tryCatch(
    suppressWarnings(lmtest::coeftest(
      fit, vcov. = sandwich::vcovHC(fit, type = "HC1")
    )),
    error = function(e) tryCatch(lmtest::coeftest(fit), error = function(e2) NULL)
  )
}

pair_binary_or <- function(y_t, y_c, adjust_t = NULL, adjust_c = NULL) {
  valid <- !is.na(y_t) & !is.na(y_c)
  y_t <- y_t[valid]
  y_c <- y_c[valid]
  n <- length(y_t)
  events <- sum(y_t) + sum(y_c)
  base <- data.frame(
    n = n, rate_trt = if (n) mean(y_t) else NA_real_,
    rate_ctl = if (n) mean(y_c) else NA_real_,
    or = NA_real_, ci_lo = NA_real_, ci_hi = NA_real_, p = NA_real_
  )
  if (n < 30 || events < 5) return(base)
  dat <- data.frame(outcome = c(y_t, y_c), treated = rep(c(1L, 0L), each = n))
  if (!is.null(adjust_t) && ncol(adjust_t) > 0) {
    if (is.null(adjust_c) || !identical(names(adjust_t), names(adjust_c))) {
      stop("adjust_t and adjust_c must have identical columns")
    }
    adj_t <- adjust_t[valid, , drop = FALSE]
    adj_c <- adjust_c[valid, , drop = FALSE]
    for (nm in names(adj_t)) dat[[nm]] <- c(adj_t[[nm]], adj_c[[nm]])
  }
  rhs <- c("treated", if (!is.null(adjust_t)) names(adjust_t) else character())
  fit <- tryCatch(
    glm(reformulate(rhs, response = "outcome"), data = dat, family = quasibinomial()),
    error = function(e) NULL
  )
  if (is.null(fit)) return(base)
  ct <- safe_hc1(fit)
  if (is.null(ct) || !("treated" %in% rownames(ct))) return(base)
  estimate <- ct["treated", 1]
  se <- ct["treated", 2]
  base$or <- exp(estimate)
  base$ci_lo <- exp(estimate - 1.96 * se)
  base$ci_hi <- exp(estimate + 1.96 * se)
  base$p <- ct["treated", ncol(ct)]
  base
}

pair_or_rd <- function(y_t, y_c, adjust_t = NULL, adjust_c = NULL) {
  valid <- !is.na(y_t) & !is.na(y_c)
  y_t <- y_t[valid]
  y_c <- y_c[valid]
  n <- length(y_t)
  result <- data.frame(
    n = n,
    rate_trt = if (n) mean(y_t) else NA_real_,
    rate_ctl = if (n) mean(y_c) else NA_real_,
    or = NA_real_, or_ci_lo = NA_real_, or_ci_hi = NA_real_, or_p = NA_real_,
    rd = NA_real_, rd_ci_lo = NA_real_, rd_ci_hi = NA_real_, rd_p = NA_real_
  )
  if (n < 30 || sum(y_t) + sum(y_c) < 5) return(result)
  dat <- data.frame(
    outcome = c(y_t, y_c),
    treated = rep(c(1L, 0L), each = n)
  )
  if (!is.null(adjust_t) && ncol(adjust_t) > 0) {
    if (is.null(adjust_c) || !identical(names(adjust_t), names(adjust_c))) {
      stop("adjust_t and adjust_c must have identical columns")
    }
    adj_t <- adjust_t[valid, , drop = FALSE]
    adj_c <- adjust_c[valid, , drop = FALSE]
    for (nm in names(adj_t)) dat[[nm]] <- c(adj_t[[nm]], adj_c[[nm]])
  }
  rhs <- c("treated", if (!is.null(adjust_t)) names(adjust_t) else character())
  formula <- reformulate(rhs, response = "outcome")
  fit_or <- tryCatch(
    glm(formula, data = dat, family = quasibinomial()),
    error = function(e) NULL
  )
  fit_rd <- tryCatch(lm(formula, data = dat), error = function(e) NULL)
  ct_or <- if (is.null(fit_or)) NULL else safe_hc1(fit_or)
  ct_rd <- if (is.null(fit_rd)) NULL else safe_hc1(fit_rd)
  if (!is.null(ct_or) && "treated" %in% rownames(ct_or)) {
    estimate <- ct_or["treated", 1]
    se <- ct_or["treated", 2]
    result$or <- exp(estimate)
    result$or_ci_lo <- exp(estimate - 1.96 * se)
    result$or_ci_hi <- exp(estimate + 1.96 * se)
    result$or_p <- ct_or["treated", ncol(ct_or)]
  }
  if (!is.null(ct_rd) && "treated" %in% rownames(ct_rd)) {
    estimate <- ct_rd["treated", 1]
    se <- ct_rd["treated", 2]
    result$rd <- estimate
    result$rd_ci_lo <- estimate - 1.96 * se
    result$rd_ci_hi <- estimate + 1.96 * se
    result$rd_p <- ct_rd["treated", ncol(ct_rd)]
  }
  result
}

pair_interaction_or_rd <- function(y_t, y_c, modifier, modifier_scale = 1) {
  valid <- !is.na(y_t) & !is.na(y_c) & !is.na(modifier)
  y_t <- y_t[valid]
  y_c <- y_c[valid]
  modifier <- modifier[valid] / modifier_scale
  n <- length(y_t)
  result <- data.frame(
    n = n,
    events_trt = sum(y_t),
    events_ctl = sum(y_c),
    interaction_or = NA_real_,
    or_ci_lo = NA_real_,
    or_ci_hi = NA_real_,
    or_p = NA_real_,
    interaction_rd = NA_real_,
    rd_ci_lo = NA_real_,
    rd_ci_hi = NA_real_,
    rd_p = NA_real_
  )
  if (n < 50 || sum(y_t) + sum(y_c) < 5) return(result)
  dat <- data.frame(
    outcome = c(y_t, y_c),
    treated = rep(c(1L, 0L), each = n),
    modifier = rep(modifier, 2)
  )
  formula <- outcome ~ treated * modifier
  fit_or <- tryCatch(
    glm(formula, data = dat, family = quasibinomial()),
    error = function(e) NULL
  )
  fit_rd <- tryCatch(lm(formula, data = dat), error = function(e) NULL)
  ct_or <- if (is.null(fit_or)) NULL else safe_hc1(fit_or)
  ct_rd <- if (is.null(fit_rd)) NULL else safe_hc1(fit_rd)
  term <- "treated:modifier"
  if (!is.null(ct_or) && term %in% rownames(ct_or)) {
    estimate <- ct_or[term, 1]
    se <- ct_or[term, 2]
    result$interaction_or <- exp(estimate)
    result$or_ci_lo <- exp(estimate - 1.96 * se)
    result$or_ci_hi <- exp(estimate + 1.96 * se)
    result$or_p <- ct_or[term, ncol(ct_or)]
  }
  if (!is.null(ct_rd) && term %in% rownames(ct_rd)) {
    estimate <- ct_rd[term, 1]
    se <- ct_rd[term, 2]
    result$interaction_rd <- estimate
    result$rd_ci_lo <- estimate - 1.96 * se
    result$rd_ci_hi <- estimate + 1.96 * se
    result$rd_p <- ct_rd[term, ncol(ct_rd)]
  }
  result
}

fixed_window_death <- function(death_offset_h, t0_h, horizon_h) {
  as.integer(
    !is.na(death_offset_h) & death_offset_h > t0_h &
      death_offset_h <= t0_h + horizon_h
  )
}

pair_mean_difference <- function(y_t, y_c, adjust_t = NULL, adjust_c = NULL) {
  valid <- !is.na(y_t) & !is.na(y_c)
  y_t <- y_t[valid]
  y_c <- y_c[valid]
  n <- length(y_t)
  result <- data.frame(
    n = n, mean_trt = if (n) mean(y_t) else NA_real_,
    mean_ctl = if (n) mean(y_c) else NA_real_,
    did = NA_real_, did_ci_lo = NA_real_, did_ci_hi = NA_real_,
    did_p = NA_real_
  )
  if (n < 30) return(result)
  dat <- data.frame(value = c(y_t, y_c), treated = rep(c(1L, 0L), each = n))
  if (!is.null(adjust_t) && ncol(adjust_t) > 0) {
    if (is.null(adjust_c) || !identical(names(adjust_t), names(adjust_c))) {
      stop("adjust_t and adjust_c must have identical columns")
    }
    adj_t <- adjust_t[valid, , drop = FALSE]
    adj_c <- adjust_c[valid, , drop = FALSE]
    for (nm in names(adj_t)) dat[[nm]] <- c(adj_t[[nm]], adj_c[[nm]])
  }
  rhs <- c("treated", if (!is.null(adjust_t)) names(adjust_t) else character())
  fit <- tryCatch(
    lm(reformulate(rhs, response = "value"), data = dat),
    error = function(e) NULL
  )
  ct <- if (is.null(fit)) NULL else safe_hc1(fit)
  if (!is.null(ct) && "treated" %in% rownames(ct)) {
    estimate <- ct["treated", 1]
    se <- ct["treated", 2]
    result$did <- estimate
    result$did_ci_lo <- estimate - 1.96 * se
    result$did_ci_hi <- estimate + 1.96 * se
    result$did_p <- ct["treated", ncol(ct)]
  }
  result
}
