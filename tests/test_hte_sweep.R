#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
})
root <- normalizePath(file.path(dirname(sub("^--file=", "",
  grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), ".."))
source(file.path(root, "R", "causal_helpers.R"))
source(file.path(root, "R", "hte_sweep.R"))

set.seed(1)
n <- 400
x <- rep(c(0, 1), each = n / 2)
yc <- rbinom(n, 1, .20)
yt <- rbinom(n, 1, plogis(qlogis(.20) + .2 + .9 * x))
fit <- hte_fit_interaction(yt, yc, factor(x), "factor")
stopifnot(is.finite(hte_wald(fit$or_fit, "(^treated:modifier)")["p"]))

q <- hte_qfactor(seq_len(100))
stopifnot(length(levels(q)) == 4, all(table(q) == 25))

cells <- hte_cell_counts(c(rep(1, 40), rep(0, 60)),
                         c(rep(1, 25), rep(0, 75)), factor(rep(c(0, 1), each = 50)))
stopifnot(!is.na(cells$min_events), is.logical(cells$sparse))

p <- data.frame(aki1_48h_trt = yt, aki1_48h_ctl = yc,
                aki1_7d_trt = yt, aki1_7d_ctl = yc,
                aki2_48h_trt = yt, aki2_48h_ctl = yc,
                aki2_7d_trt = yt, aki2_7d_ctl = yc)
m <- data.frame(
  egfr = runif(n), baseline_cr = runif(n), age = runif(n),
  hemoglobin = runif(n), lactate = runif(n), map = runif(n),
  alb_cat = factor(x), heart_failure = factor(x), diabetes = factor(x),
  hypertension = factor(x), ckd = factor(x), surg_cabg = factor(x),
  surg_valve = factor(x), surg_combined = factor(x), surg_aortic = factor(x),
  vaso_at_t0 = factor(x), vent_at_t0 = factor(x), sex = factor(x)
)
s <- hte_step1(p, m)
stopifnot(nrow(s$tests) == 24 * 4, all(c("or_q", "rd_q") %in% names(s$tests)))

component_pairs <- data.frame(
  trt_pid = paste0("t", 1:10),
  ctl_pid = rep(paste0("c", 1:5), each = 2)
)
component_folds <- hte_patient_folds(component_pairs)
stopifnot(
  component_folds$status == "patient_disjoint_5fold",
  all(component_folds$fold %in% 1:5),
  all(component_folds$fold_pair_counts == 2)
)
giant_pairs <- data.frame(
  trt_pid = paste0("g", 1:10),
  ctl_pid = rep("shared_control", 10)
)
stopifnot(
  hte_patient_folds(giant_pairs)$status ==
    "demoted_giant_or_too_few_components"
)

censor_pairs <- data.frame(
  aki1_48h_trt = c(rep(0, 8), NA, NA),
  aki1_48h_ctl = c(rep(0, 8), NA, NA),
  aki1_7d_trt = c(rep(0, 6), rep(NA, 4)),
  aki1_7d_ctl = c(rep(0, 6), rep(NA, 4))
)
stopifnot(
  sum(hte_horizon_keep(censor_pairs, 48)) == 8,
  sum(hte_horizon_keep(censor_pairs, 168)) == 6
)
cat("test_hte_sweep.R: PASS\n")
