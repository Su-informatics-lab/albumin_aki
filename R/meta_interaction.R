#!/usr/bin/env Rscript
# Three-database random-effects meta-analysis on aggregate interaction estimates.
# Uses REML with a normal 95% CI. No patient-level data are read.

args <- commandArgs(trailingOnly = TRUE)
RESULTS <- if (length(args)) {
  path.expand(args[1])
} else {
  path.expand("~/albumin_aki/results")
}

files <- file.path(
  RESULTS,
  sprintf(
    "salvage_egfr_interaction_%s.csv",
    c("mimic", "eicu", "iuh")
  )
)
if (!all(file.exists(files))) {
  stop("Missing one or more database interaction aggregates")
}
x <- do.call(rbind, lapply(files, read.csv, stringsAsFactors = FALSE))
x <- x[x$outcome %in% c("aki1_48h", "aki1_7d"), ]

reml_meta <- function(y, se) {
  v <- se^2
  k <- length(y)
  objective <- function(tau2) {
    w <- 1 / (v + tau2)
    mu <- sum(w * y) / sum(w)
    0.5 * (
      sum(log(v + tau2)) + log(sum(w)) +
        sum(w * (y - mu)^2)
    )
  }
  upper <- max(c(var(y) * 100, max(v) * 100, 1))
  opt <- optimize(objective, interval = c(0, upper))
  tau2 <- if (objective(0) <= opt$objective) 0 else opt$minimum
  w <- 1 / (v + tau2)
  mu <- sum(w * y) / sum(w)
  pooled_se <- sqrt(1 / sum(w))
  wf <- 1 / v
  fixed <- sum(wf * y) / sum(wf)
  q <- sum(wf * (y - fixed)^2)
  i2 <- if (q > 0) max(0, (q - (k - 1)) / q) * 100 else 0
  list(
    estimate = mu, se = pooled_se, tau2 = tau2,
    q = q, q_df = k - 1, i2 = i2
  )
}

rows <- list()
for (outcome in unique(x$outcome)) {
  for (scale in c("OR", "RD")) {
    z <- x[x$outcome == outcome & x$scale == scale, ]
    if (nrow(z) != 3) stop("Each meta-analysis requires exactly 3 databases")
    y <- if (scale == "OR") z$log_estimate else z$estimate
    fit <- reml_meta(y, z$se)
    lo <- fit$estimate - 1.96 * fit$se
    hi <- fit$estimate + 1.96 * fit$se
    rows[[length(rows) + 1L]] <- data.frame(
      outcome = outcome,
      modifier = "eGFR_per_30",
      scale = scale,
      method = "REML_random_effects_normal_CI",
      k = 3,
      estimate = if (scale == "OR") exp(fit$estimate) else fit$estimate,
      ci_lo = if (scale == "OR") exp(lo) else lo,
      ci_hi = if (scale == "OR") exp(hi) else hi,
      p = 2 * pnorm(-abs(fit$estimate / fit$se)),
      tau2 = fit$tau2,
      q = fit$q,
      q_df = fit$q_df,
      i2_percent = fit$i2,
      databases = paste(z$db, collapse = "+")
    )
  }
}
out <- do.call(rbind, rows)
write.csv(
  out, file.path(RESULTS, "salvage_interaction_meta.csv"),
  row.names = FALSE
)
print(out)
