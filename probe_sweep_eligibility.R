#!/usr/bin/env Rscript
# Aggregate-only diagnosis of the pre-sweep treated eligibility surprise.

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(normalizePath(file_arg))
source(file.path(repo, "R", "causal_helpers.R"))
results <- path.expand("~/albumin_aki/results")
all_pts <- read.csv(
  file.path(results, "did_all_mimic.csv"), stringsAsFactors = FALSE
)
cr_all <- read.csv(
  file.path(results, "did_cr_all_mimic.csv"), stringsAsFactors = FALSE
)
cr_all$pid <- cr_all$stay_id

ordered <- cr_all[order(cr_all$pid, cr_all$offset_h, -cr_all$labresult), ]
correct_list <- split(ordered[, c("labresult", "offset_h")], ordered$pid)
# Reproduce the corrected sweep driver's construction exactly.
driver_list <- split(ordered[, c("labresult", "offset_h")], ordered$pid)

early_value <- setNames(all_pts$cr_ref_early, as.character(all_pts$pid))
early_offset <- setNames(all_pts$cr_ref_early_offset_h, as.character(all_pts$pid))
first_aki <- function(cr_list) {
  vapply(as.character(all_pts$pid), function(pid) {
    first_prevalent_aki_time(cr_list[[pid]], early_value[pid], early_offset[pid])
  }, numeric(1))
}
aki_correct <- first_aki(correct_list)
aki_driver <- first_aki(driver_list)
treated <- which(all_pts$treated == 1 & !is.na(all_pts$alb_offset_h))
t0 <- all_pts$alb_offset_h[treated]
base_timing <- all_pts$cr_ref_early_offset_h[treated] <= t0
in_icu <- all_pts$icu_discharge_h[treated] > t0
alive <- is.na(all_pts$death_offset_h[treated]) |
  all_pts$death_offset_h[treated] > t0
incident_correct <- is.na(aki_correct[treated]) | aki_correct[treated] > t0
incident_driver <- is.na(aki_driver[treated]) | aki_driver[treated] > t0

out <- data.frame(
  metric = c(
    "treated_total",
    "early_reference_on_or_before_t0",
    "in_icu_at_t0",
    "alive_at_t0",
    "eligible_correct_cr_alignment",
    "eligible_driver_cr_alignment",
    "prevalent_excluded_correct_alignment",
    "prevalent_excluded_driver_alignment",
    "first_aki_classification_discordant",
    "deaths_at_or_before_t0"
  ),
  n = c(
    length(treated),
    sum(base_timing),
    sum(in_icu),
    sum(alive),
    sum(base_timing & in_icu & alive & incident_correct),
    sum(base_timing & in_icu & alive & incident_driver),
    sum(!incident_correct),
    sum(!incident_driver),
    sum(xor(incident_correct, incident_driver)),
    sum(!alive)
  )
)
stopifnot(
  out$n[out$metric == "eligible_driver_cr_alignment"] == 5428,
  out$n[out$metric == "prevalent_excluded_driver_alignment"] == 343,
  out$n[out$metric == "first_aki_classification_discordant"] == 0
)
write.csv(
  out, file.path(results, "probe_sweep_eligibility_mimic.csv"),
  row.names = FALSE
)
print(out, row.names = FALSE)
