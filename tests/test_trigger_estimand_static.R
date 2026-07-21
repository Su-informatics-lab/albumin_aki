#!/usr/bin/env Rscript

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(dirname(normalizePath(file_arg)))
script <- readLines(file.path(repo, "probe_albumin_trigger_estimand.R"), warn = FALSE)
text <- paste(script, collapse = "\n")

stopifnot(
  grepl("CUTS <- c\\(3\\.5, 3\\.0, 2\\.5\\)", text),
  grepl("M_IMP <- 20L", text),
  grepl("main_ps_vars\\(tag, \"pooled\", \"primary\"\\)", text),
  grepl("albumin_stratified", text),
  grepl("setdiff\\(main_ps_vars.*\"alb_cat\"", text),
  grepl("p_treated / iptw_dat\\$ps", text),
  grepl("\\(1 - p_treated\\) / \\(1 - iptw_dat\\$ps\\)", text),
  grepl("pair_or_rd", text),
  grepl("weighted_or_rd", text),
  !grepl("write\\.csv\\([^\n]*(pairs|patient)", text),
  !grepl("super.?learner|xgboost|random.?forest", text, ignore.case = TRUE)
)

fixture <- data.frame(albumin = c(NA, 2.4, 2.7, 3.2, 3.6))
classify <- function(x, cut) {
  factor(ifelse(is.na(x), "missing", ifelse(x < cut, "low", "normal")),
         levels = c("normal", "low", "missing"))
}
stopifnot(
  identical(as.character(classify(fixture$albumin, 3.5)),
            c("missing", "low", "low", "low", "normal")),
  identical(as.character(classify(fixture$albumin, 3.0)),
            c("missing", "low", "low", "normal", "normal")),
  identical(as.character(classify(fixture$albumin, 2.5)),
            c("missing", "low", "normal", "normal", "normal"))
)

cat("PASS: threshold registry, frozen covariates, stratified matching, stabilized IPTW, aggregate-only outputs\n")
