#!/usr/bin/env Rscript
# Aggregate-only probe for the pooled mortality falsification guard rail.
# Usage: Rscript probe_mortality_falsification.R {mimic|eicu}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1 || !(tolower(args[1]) %in% c("mimic", "eicu"))) {
  stop("Usage: Rscript probe_mortality_falsification.R {mimic|eicu}")
}
tag <- tolower(args[1])
db <- toupper(tag)
results <- path.expand("~/albumin_aki/results")
all_pts <- read.csv(
  file.path(results, sprintf("did_all_%s.csv", tag)),
  stringsAsFactors = FALSE
)
pairs <- read.csv(
  file.path(
    results,
    sprintf("did_pairs_primary_yet_untreated_pooled_%s.csv", tag)
  ),
  stringsAsFactors = FALSE
)

trt <- all_pts[match(pairs$trt_pid, all_pts$pid), ]
ctl <- all_pts[match(pairs$ctl_pid, all_pts$pid), ]
stopifnot(!any(is.na(trt$pid)), !any(is.na(ctl$pid)))
reuse <- table(pairs$ctl_pid)
effective_n <- sum(reuse)^2 / sum(reuse^2)
later_treated <- !is.na(ctl$alb_offset_h)
death_before_t0_trt <- !is.na(trt$death_offset_h) & trt$death_offset_h <= pairs$t0
death_before_t0_ctl <- !is.na(ctl$death_offset_h) & ctl$death_offset_h <= pairs$t0

overall <- data.frame(
  db = db,
  n_pairs = nrow(pairs),
  unique_treated = length(unique(pairs$trt_pid)),
  unique_controls = length(unique(pairs$ctl_pid)),
  control_effective_n = effective_n,
  control_reuse_median = unname(quantile(reuse, 0.5)),
  control_reuse_p90 = unname(quantile(reuse, 0.9)),
  control_reuse_p99 = unname(quantile(reuse, 0.99)),
  control_reuse_max = max(reuse),
  pair_weighted_mort_trt = mean(trt$hosp_mortality),
  pair_weighted_mort_ctl = mean(ctl$hosp_mortality),
  unique_control_mort = mean(
    all_pts$hosp_mortality[match(unique(pairs$ctl_pid), all_pts$pid)]
  ),
  raw_final_treated_mort = mean(
    all_pts$hosp_mortality[all_pts$treated == 1]
  ),
  raw_final_control_mort = mean(
    all_pts$hosp_mortality[all_pts$treated == 0]
  ),
  control_later_treated_fraction = mean(later_treated),
  death_at_or_before_t0_trt = sum(death_before_t0_trt),
  death_at_or_before_t0_ctl = sum(death_before_t0_ctl)
)

by_control_type <- do.call(rbind, lapply(
  c("never_treated", "later_treated"),
  function(group) {
    idx <- if (group == "later_treated") later_treated else !later_treated
    data.frame(
      db = db, group = group, n_pair_rows = sum(idx),
      unique_controls = length(unique(pairs$ctl_pid[idx])),
      mortality = mean(ctl$hosp_mortality[idx]),
      mean_age = mean(ctl$age[idx]), mean_egfr = mean(ctl$egfr[idx])
    )
  }
))

t0_group <- cut(
  pairs$t0,
  breaks = unique(quantile(pairs$t0, seq(0, 1, 0.25), na.rm = TRUE)),
  include.lowest = TRUE
)
by_t0 <- do.call(rbind, lapply(levels(t0_group), function(group) {
  idx <- t0_group == group
  data.frame(
    db = db, t0_group = group, n_pairs = sum(idx),
    mort_trt = mean(trt$hosp_mortality[idx]),
    mort_ctl = mean(ctl$hosp_mortality[idx]),
    mean_age_trt = mean(trt$age[idx]), mean_age_ctl = mean(ctl$age[idx]),
    mean_egfr_trt = mean(trt$egfr[idx]), mean_egfr_ctl = mean(ctl$egfr[idx])
  )
}))

out <- rbind(
  cbind(section = "overall", metric = names(overall), value = as.character(overall[1, ])),
  cbind(
    section = "control_type",
    metric = apply(by_control_type, 1, function(x) paste(x, collapse = "|")),
    value = NA_character_
  ),
  cbind(
    section = "t0_quartile",
    metric = apply(by_t0, 1, function(x) paste(x, collapse = "|")),
    value = NA_character_
  )
)
write.csv(
  out,
  file.path(results, sprintf("probe_mortality_%s.csv", tag)),
  row.names = FALSE
)
print(overall, row.names = FALSE)
print(by_control_type, row.names = FALSE)
print(by_t0, row.names = FALSE)
