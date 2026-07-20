#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
results <- if (length(args)) path.expand(args[1]) else
  "/N/project/depot/hw56/albumin_aki/results"

read_result <- function(name) {
  path <- file.path(results, name)
  if (!file.exists(path)) stop("Missing required IUH result: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

smd <- function(x, y) {
  pooled_sd <- sqrt((stats::var(x) + stats::var(y)) / 2)
  if (!is.finite(pooled_sd) || pooled_sd == 0) return(0)
  abs(mean(x) - mean(y)) / pooled_sd
}

all_pts <- read_result("did_all_iuh.csv")
outcomes <- c(
  "aki1_48h", "aki2_48h", "aki3_48h",
  "aki1_7d", "aki2_7d", "aki3_7d",
  "aki2_rrt_48h", "aki2_rrt_7d",
  "death_48h_all", "death_48h_never", "death_48h_censored",
  "death_7d_all", "death_7d_never", "death_7d_censored"
)

balance_rows <- list()
sparse_rows <- list()
for (variant in c("egfr", "egfr_reported")) {
  modifier <- if (variant == "egfr") "egfr" else "egfr_reported"
  pairs <- read_result(sprintf(
    "did_pairs_primary_yet_untreated_%s_iuh.csv", variant
  ))
  trt_row <- match(pairs$trt_pid, all_pts$pid)
  ctl_row <- match(pairs$ctl_pid, all_pts$pid)
  if (anyNA(trt_row) || anyNA(ctl_row)) {
    stop("Matched patient IDs do not map to did_all_iuh.csv")
  }
  for (stratum in unique(pairs$stratum)) {
    keep <- pairs$stratum == stratum
    trt_value <- all_pts[[modifier]][trt_row[keep]]
    ctl_value <- all_pts[[modifier]][ctl_row[keep]]
    complete <- !is.na(trt_value) & !is.na(ctl_value)
    balance_rows[[length(balance_rows) + 1L]] <- data.frame(
      variant = variant,
      stratum = stratum,
      n_pairs = sum(complete),
      mean_trt = mean(trt_value[complete]),
      mean_ctl = mean(ctl_value[complete]),
      smd = smd(trt_value[complete], ctl_value[complete])
    )
    for (outcome in outcomes) {
      for (arm in c("trt", "ctl")) {
        value <- pairs[[paste0(outcome, "_", arm)]][keep]
        sparse_rows[[length(sparse_rows) + 1L]] <- data.frame(
          variant = variant,
          stratum = stratum,
          outcome = outcome,
          arm = arm,
          n = sum(!is.na(value)),
          events = sum(value, na.rm = TRUE),
          sparse_lt20 = sum(value, na.rm = TRUE) < 20
        )
      }
    }
  }
}

balance <- do.call(rbind, balance_rows)
sparse <- do.call(rbind, sparse_rows)
write.csv(
  balance,
  file.path(results, "iuh_stratified_egfr_balance.csv"),
  row.names = FALSE
)
write.csv(
  sparse,
  file.path(results, "iuh_stratified_sparse_cells.csv"),
  row.names = FALSE
)

if (any(!is.finite(balance$smd)) || any(balance$smd > 0.10)) {
  stop("GUARD: continuous eGFR is not balanced within at least one stratum")
}
cat("PASS: continuous eGFR SMD <= 0.10 in every IUH stratum\n")
