#!/usr/bin/env Rscript
# Aggregate-only diagnostic of measured and unavailable eICU baseline axes.
# Usage: Rscript probe_eicu_underadjustment.R

results <- path.expand("~/albumin_aki/results")
path <- file.path(results, "psm_balance_pooled_eicu.csv")
if (!file.exists(path)) stop("Missing frozen eICU pooled balance file: ", path)

balance <- read.csv(path, stringsAsFactors = FALSE)
required <- c(
  "variable_code", "variable", "raw_smd", "smd", "analysis_set", "stratum"
)
missing <- setdiff(required, names(balance))
if (length(missing)) {
  stop("Balance file is missing columns: ", paste(missing, collapse = ", "))
}
balance <- balance[
  balance$analysis_set == "primary" & balance$stratum == "Overall",
  , drop = FALSE
]
if (!nrow(balance)) stop("No primary Overall row in eICU balance file")

available <- data.frame(
  db = "EICU",
  database_role = "supplementary",
  axis = "available baseline axis",
  variable_code = balance$variable_code,
  variable = balance$variable,
  measured = 1L,
  raw_smd = balance$raw_smd,
  matched_smd = balance$smd,
  limitation = "",
  stringsAsFactors = FALSE
)
unavailable <- data.frame(
  db = "EICU",
  database_role = "supplementary",
  axis = "unavailable resuscitation-severity axis",
  variable_code = c("vaso_at_t0", "map_before_t0", "vent_at_t0"),
  variable = c(
    "baseline (at ICU T0): vasopressor status",
    "baseline (at ICU T0): MAP",
    "baseline (at ICU T0): ventilation status"
  ),
  measured = 0L,
  raw_smd = NA_real_,
  matched_smd = NA_real_,
  limitation = c(
    "omitted: hospital-level informative missingness",
    "omitted: hospital-level informative missingness",
    "omitted: APACHE day-1 proxy can post-date T0"
  ),
  stringsAsFactors = FALSE
)

out <- rbind(available, unavailable)
write.csv(
  out,
  file.path(results, "probe_eicu_underadjustment.csv"),
  row.names = FALSE
)
print(out, row.names = FALSE)
