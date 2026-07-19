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
