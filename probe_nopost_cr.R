#!/usr/bin/env Rscript
# Aggregate arm-level post-T0 creatinine missingness among canonical pairs.
# Usage: Rscript probe_nopost_cr.R {mimic|eicu} {pooled|egfr}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2 || !(tolower(args[1]) %in% c("mimic", "eicu")) ||
    !(tolower(args[2]) %in% c("pooled", "egfr"))) {
  stop("Usage: Rscript probe_nopost_cr.R {mimic|eicu} {pooled|egfr}")
}
tag <- tolower(args[1])
db <- toupper(tag)
variant <- tolower(args[2])
results <- path.expand("~/albumin_aki/results")
pairs <- read.csv(
  file.path(
    results,
    sprintf("did_pairs_primary_yet_untreated_%s_%s.csv", variant, tag)
  ),
  stringsAsFactors = FALSE
)

rows <- list()
for (stratum in unique(pairs$stratum)) {
  idx <- pairs$stratum == stratum
  for (horizon in c("48h", "7d")) {
    trt <- pairs[[paste0("nopost_", horizon, "_trt")]][idx]
    ctl <- pairs[[paste0("nopost_", horizon, "_ctl")]][idx]
    rows[[length(rows) + 1L]] <- data.frame(
      db = db, variant = variant, stratum = stratum, horizon = horizon,
      n_pairs = sum(!is.na(trt) & !is.na(ctl)),
      no_post_cr_trt = sum(trt == 1, na.rm = TRUE),
      no_post_cr_ctl = sum(ctl == 1, na.rm = TRUE),
      rate_trt = mean(trt, na.rm = TRUE),
      rate_ctl = mean(ctl, na.rm = TRUE),
      rate_difference = mean(trt, na.rm = TRUE) - mean(ctl, na.rm = TRUE)
    )
  }
}
out <- do.call(rbind, rows)
write.csv(
  out,
  file.path(results, sprintf("probe_nopost_cr_%s_%s.csv", variant, tag)),
  row.names = FALSE
)
print(out, row.names = FALSE)
