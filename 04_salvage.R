#!/usr/bin/env Rscript
# Frozen-pair secondary analyses approved in JOURNAL Entry 24.
# Usage:
#   Rscript 04_salvage.R {mimic|eicu|iuh} gradient
#
# This script never estimates a propensity score and never rematches.

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(splines)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2 ||
    !(tolower(args[1]) %in% c("mimic", "eicu", "iuh")) ||
    tolower(args[2]) != "gradient") {
  stop("Usage: Rscript 04_salvage.R {mimic|eicu|iuh} gradient")
}
tag <- tolower(args[1])
db <- toupper(tag)
RESULTS <- path.expand(Sys.getenv(
  "ALBUMIN_AKI_RESULTS", unset = "~/albumin_aki/results"
))

all_pts <- read.csv(
  file.path(RESULTS, sprintf("did_all_%s.csv", tag)),
  stringsAsFactors = FALSE
)
pairs <- read.csv(
  file.path(
    RESULTS,
    sprintf("did_pairs_primary_yet_untreated_pooled_%s.csv", tag)
  ),
  stringsAsFactors = FALSE
)
tr <- match(pairs$trt_pid, all_pts$pid)
if (anyNA(tr)) stop("Treated pair IDs do not map to did_all")
egfr <- all_pts$egfr[tr]

# Fixed across databases: the clinical cut points are interior spline knots.
KNOTS <- c(60, 90)
BOUNDARY <- c(0, 200)
GRID <- seq(30, 120, by = 2)
OUTCOMES <- c("aki1_48h", "aki1_7d")

hc1 <- function(fit) {
  tryCatch(vcovHC(fit, type = "HC1"), error = function(e) NULL)
}

contrast_row <- function(fit, vcov, grid, scale) {
  new_t <- data.frame(treated = 1, egfr = grid)
  new_c <- data.frame(treated = 0, egfr = grid)
  tt <- delete.response(terms(fit))
  xt <- model.matrix(tt, new_t, contrasts.arg = fit$contrasts)
  xc <- model.matrix(tt, new_c, contrasts.arg = fit$contrasts)
  delta_x <- xt - xc
  beta <- coef(fit)
  keep <- !is.na(beta)
  beta <- beta[keep]
  delta_x <- delta_x[, keep, drop = FALSE]
  vcov <- vcov[keep, keep, drop = FALSE]

  if (scale == "OR") {
    estimate <- as.vector(delta_x %*% beta)
    se <- sqrt(pmax(0, rowSums((delta_x %*% vcov) * delta_x)))
    data.frame(
      estimate = exp(estimate),
      ci_lo = exp(estimate - 1.96 * se),
      ci_hi = exp(estimate + 1.96 * se),
      p = 2 * pnorm(-abs(estimate / se))
    )
  } else {
    estimate <- as.vector(delta_x %*% beta)
    se <- sqrt(pmax(0, rowSums((delta_x %*% vcov) * delta_x)))
    data.frame(
      estimate = estimate,
      ci_lo = estimate - 1.96 * se,
      ci_hi = estimate + 1.96 * se,
      p = 2 * pnorm(-abs(estimate / se))
    )
  }
}

interaction_term <- function(fit, scale) {
  ct <- coeftest(fit, vcov. = vcovHC(fit, type = "HC1"))
  term <- "treated:egfr30"
  if (!(term %in% rownames(ct))) stop("Linear interaction term not found")
  estimate <- ct[term, 1]
  se <- ct[term, 2]
  data.frame(
    scale = scale,
    estimate = if (scale == "OR") exp(estimate) else estimate,
    ci_lo = if (scale == "OR") {
      exp(estimate - 1.96 * se)
    } else {
      estimate - 1.96 * se
    },
    ci_hi = if (scale == "OR") {
      exp(estimate + 1.96 * se)
    } else {
      estimate + 1.96 * se
    },
    p = ct[term, ncol(ct)],
    log_estimate = if (scale == "OR") estimate else NA_real_,
    se = se
  )
}

spline_rows <- list()
interaction_rows <- list()
cell_rows <- list()

for (outcome in OUTCOMES) {
  yt <- pairs[[paste0(outcome, "_trt")]]
  yc <- pairs[[paste0(outcome, "_ctl")]]
  valid <- !is.na(yt) & !is.na(yc) & !is.na(egfr)
  yt <- yt[valid]
  yc <- yc[valid]
  eg <- egfr[valid]
  n <- length(eg)
  dat <- data.frame(
    outcome = c(yt, yc),
    treated = rep(c(1L, 0L), each = n),
    egfr = rep(eg, 2)
  )
  form_spline <- outcome ~ treated * ns(
    egfr, knots = KNOTS, Boundary.knots = BOUNDARY
  )
  fits <- list(
    OR = glm(form_spline, data = dat, family = quasibinomial()),
    RD = lm(form_spline, data = dat)
  )

  bins <- cut(
    eg, breaks = c(-Inf, 60, 90, Inf), right = FALSE,
    labels = c("G3plus_lt60", "G2_60_89", "G1_ge90")
  )
  cells <- do.call(rbind, lapply(levels(bins), function(bin) {
    idx <- bins == bin
    data.frame(
      db = db, outcome = outcome, egfr_cell = bin,
      n_pairs = sum(idx), events_trt = sum(yt[idx]),
      events_ctl = sum(yc[idx]),
      sparse_lt20 = sum(yt[idx]) < 20 || sum(yc[idx]) < 20
    )
  }))
  cell_rows[[length(cell_rows) + 1L]] <- cells

  for (scale in names(fits)) {
    fit <- fits[[scale]]
    vc <- hc1(fit)
    if (is.null(vc)) stop("HC1 covariance failed")
    z <- contrast_row(fit, vc, GRID, scale)
    z <- cbind(
      data.frame(
        db = db, outcome = outcome, scale = scale,
        egfr = GRID, n_pairs = n,
        events_trt = sum(yt), events_ctl = sum(yc)
      ),
      z
    )
    z$egfr_cell <- ifelse(
      z$egfr < 60, "G3plus_lt60",
      ifelse(z$egfr < 90, "G2_60_89", "G1_ge90")
    )
    sparse_map <- setNames(cells$sparse_lt20, cells$egfr_cell)
    z$sparse_lt20 <- sparse_map[z$egfr_cell]
    spline_rows[[length(spline_rows) + 1L]] <- z
  }

  linear_dat <- transform(dat, egfr30 = egfr / 30)
  linear_fits <- list(
    OR = glm(
      outcome ~ treated * egfr30, data = linear_dat,
      family = quasibinomial()
    ),
    RD = lm(outcome ~ treated * egfr30, data = linear_dat)
  )
  for (scale in names(linear_fits)) {
    z <- interaction_term(linear_fits[[scale]], scale)
    interaction_rows[[length(interaction_rows) + 1L]] <- cbind(
      data.frame(
        db = db, outcome = outcome, modifier = "eGFR_per_30",
        method = "frozen_pairs_hc1", n_pairs = n,
        events_trt = sum(yt), events_ctl = sum(yc)
      ),
      z
    )
  }
}

spline <- do.call(rbind, spline_rows)
interactions <- do.call(rbind, interaction_rows)
cells <- do.call(rbind, cell_rows)

write.csv(
  spline,
  file.path(RESULTS, sprintf("salvage_egfr_spline_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  interactions,
  file.path(RESULTS, sprintf("salvage_egfr_interaction_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  cells,
  file.path(RESULTS, sprintf("salvage_egfr_spline_cells_%s.csv", tag)),
  row.names = FALSE
)
cat(sprintf(
  "04_salvage.R | %s | gradient COMPLETE | pairs=%d\n", db, nrow(pairs)
))
