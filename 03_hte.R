#!/usr/bin/env Rscript
# Formal treatment-by-eGFR interaction and prespecified subgroups.
# Uses the pooled canonical pairs and shared outcome/OR implementation.
# Usage: Rscript 03_hte.R {mimic|eicu} [standard|sweep]

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
})

args <- commandArgs(trailingOnly = TRUE)
if (!(length(args) %in% c(1, 2)) ||
    !(tolower(args[1]) %in% c("mimic", "eicu")) ||
    (length(args) == 2 && !(tolower(args[2]) %in% c("standard", "sweep")))) {
  stop("Usage: Rscript 03_hte.R {mimic|eicu} [standard|sweep]")
}
tag <- tolower(args[1])
mode <- if (length(args) == 2) tolower(args[2]) else "standard"
if (mode == "sweep" && tag != "mimic") {
  stop("The Entry-18c sweep is frozen to MIMIC only")
}
db <- toupper(tag)
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
script_dir <- dirname(normalizePath(file_arg))
source(file.path(script_dir, "R", "causal_helpers.R"))
source(file.path(script_dir, "R", "covariate_registry.R"))
RESULTS <- path.expand("~/albumin_aki/results")

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
canonical <- read.csv(
  file.path(RESULTS, sprintf("did_binary_pooled_%s.csv", tag)),
  stringsAsFactors = FALSE
)

if (mode == "sweep") {
  source(file.path(script_dir, "R", "hte_sweep.R"))
  run_hte_sweep(tag, all_pts, pairs, RESULTS)
  quit(save = "no", status = 0)
}

trt_rows <- match(pairs$trt_pid, all_pts$pid)
if (any(is.na(trt_rows))) stop("Pair treated IDs do not map to did_all")
n_pairs <- nrow(pairs)
cat(sprintf("\n03_hte.R | %s | pooled pairs=%d\n", db, n_pairs))

outcomes <- c(
  "aki1_48h", "aki2_48h", "aki3_48h",
  "aki1_7d", "aki2_7d", "aki3_7d",
  "aki2_rrt_48h", "aki2_rrt_7d",
  "death_48h_all", "death_48h_never", "death_48h_censored",
  "death_7d_all", "death_7d_never", "death_7d_censored",
  "hosp_mort_descriptive"
)
modifier <- data.frame(
  egfr = all_pts$egfr[trt_rows],
  egfr_stratum = egfr_stratum(all_pts$egfr[trt_rows]),
  age = all_pts$age[trt_rows],
  is_female = all_pts$is_female[trt_rows],
  diabetes = all_pts$diabetes[trt_rows],
  ckd = all_pts$ckd[trt_rows],
  surg_cabg = all_pts$surg_cabg[trt_rows]
)

subgroups <- list(
  Overall = rep(TRUE, n_pairs),
  G1 = modifier$egfr_stratum == "G1",
  G2 = modifier$egfr_stratum == "G2",
  G3plus = modifier$egfr_stratum == "G3plus",
  Age_lt65 = !is.na(modifier$age) & modifier$age < 65,
  Age_ge65 = !is.na(modifier$age) & modifier$age >= 65,
  Female = modifier$is_female == 1,
  Male = modifier$is_female == 0,
  Diabetes = modifier$diabetes == 1,
  No_diabetes = modifier$diabetes == 0,
  CKD = modifier$ckd == 1,
  No_CKD = modifier$ckd == 0,
  CABG = modifier$surg_cabg == 1,
  Non_CABG = modifier$surg_cabg == 0
)

hte <- list()
for (subgroup in names(subgroups)) {
  idx <- which(!is.na(subgroups[[subgroup]]) & subgroups[[subgroup]])
  if (length(idx) < 30) next
  for (outcome in outcomes) {
    estimate <- pair_or_rd(
      pairs[[paste0(outcome, "_trt")]][idx],
      pairs[[paste0(outcome, "_ctl")]][idx]
    )
    hte[[length(hte) + 1L]] <- cbind(
      data.frame(db = db, subgroup = subgroup, outcome = outcome),
      estimate
    )
  }
}
hte_df <- do.call(rbind, hte)

# Enforce identical overall ORs between 02_psm.R and 03_hte.R.
overall <- hte_df[hte_df$subgroup == "Overall", ]
canon_psm <- canonical[canonical$stratum == "Overall" &
                         canonical$method == "psm", ]
check <- merge(
  overall[, c("outcome", "or")],
  canon_psm[, c("outcome", "or")],
  by = "outcome", suffixes = c("_hte", "_psm")
)
if (nrow(check) != length(outcomes) ||
    any(abs(check$or_hte - check$or_psm) > 1e-10, na.rm = TRUE) ||
    any(xor(is.na(check$or_hte), is.na(check$or_psm)))) {
  stop("02_psm.R and 03_hte.R overall ORs are not identical")
}
cat("  shared-outcome OR reconciliation: PASS\n")

interactions <- list()
for (outcome in outcomes) {
  y_t <- pairs[[paste0(outcome, "_trt")]]
  y_c <- pairs[[paste0(outcome, "_ctl")]]
  valid <- !is.na(y_t) & !is.na(y_c) & !is.na(modifier$egfr)
  n <- sum(valid)
  row <- data.frame(
    db = db, modifier = "eGFR_per_30", outcome = outcome, n = n,
    interaction_or = NA_real_, ci_lo = NA_real_, ci_hi = NA_real_,
    p_interaction = NA_real_
  )
  if (n >= 50 && sum(y_t[valid]) + sum(y_c[valid]) >= 5) {
    dat <- data.frame(
      outcome = c(y_t[valid], y_c[valid]),
      treated = rep(c(1L, 0L), each = n),
      egfr30 = rep(modifier$egfr[valid] / 30, 2)
    )
    fit <- tryCatch(
      glm(outcome ~ treated * egfr30, data = dat, family = quasibinomial()),
      error = function(e) NULL
    )
    if (!is.null(fit)) {
      ct <- safe_hc1(fit)
      term <- "treated:egfr30"
      if (!is.null(ct) && term %in% rownames(ct)) {
        estimate <- ct[term, 1]
        se <- ct[term, 2]
        row$interaction_or <- exp(estimate)
        row$ci_lo <- exp(estimate - 1.96 * se)
        row$ci_hi <- exp(estimate + 1.96 * se)
        row$p_interaction <- ct[term, ncol(ct)]
      }
    }
  }
  interactions[[length(interactions) + 1L]] <- row
}
interaction_df <- do.call(rbind, interactions)

write.csv(
  hte_df, file.path(RESULTS, sprintf("did_hte_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  interaction_df,
  file.path(RESULTS, sprintf("did_hte_interact_%s.csv", tag)),
  row.names = FALSE
)
cat(sprintf("03_hte.R | %s | COMPLETE\n", db))
