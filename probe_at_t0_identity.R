#!/usr/bin/env Rscript

results <- path.expand("~/albumin_aki/results")

read_required <- function(path) {
  if (!file.exists(path)) stop("Missing required file: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

select_value <- function(stream, index, inclusive = FALSE, lab_name = NULL,
                         value_col = "value") {
  if (!is.null(lab_name)) {
    stream <- stream[stream$lab_name == lab_name, , drop = FALSE]
  }
  stream$index_h <- index$index_h[match(stream$pid, index$pid)]
  keep <- !is.na(stream$index_h) & !is.na(stream$offset_h)
  if (inclusive) {
    keep <- keep & stream$offset_h <= stream$index_h
  } else {
    keep <- keep & stream$offset_h < stream$index_h
  }
  stream <- stream[keep, , drop = FALSE]
  out <- setNames(rep(NA_real_, nrow(index)), as.character(index$pid))
  if (!nrow(stream)) return(out)
  stream <- stream[
    order(stream$pid, -stream$offset_h, -stream[[value_col]]),
    , drop = FALSE
  ]
  stream <- stream[!duplicated(stream$pid), , drop = FALSE]
  out[as.character(stream$pid)] <- as.numeric(stream[[value_col]])
  out
}

compare_values <- function(db, variable, old, inclusive) {
  both_na <- is.na(old) & is.na(inclusive)
  same_value <- !is.na(old) & !is.na(inclusive) & old == inclusive
  changed <- !(both_na | same_value)
  finite_delta <- abs(old - inclusive)
  data.frame(
    db = db,
    variable = variable,
    n_patients = length(old),
    n_old_observed = sum(!is.na(old)),
    n_at_or_before_observed = sum(!is.na(inclusive)),
    n_values_changed = sum(changed),
    max_abs_change = if (any(is.finite(finite_delta))) {
      max(finite_delta, na.rm = TRUE)
    } else {
      0
    }
  )
}

rows <- list()
for (tag in c("mimic", "eicu")) {
  all_pts <- read_required(file.path(results, paste0("did_all_", tag, ".csv")))
  id_col <- if (tag == "mimic") "stay_id" else "patientunitstayid"
  if (!("pid" %in% names(all_pts))) all_pts$pid <- all_pts[[id_col]]
  index <- data.frame(
    pid = all_pts$pid,
    index_h = ifelse(
      !is.na(all_pts$alb_offset_h),
      all_pts$alb_offset_h,
      all_pts$cr_ref_early_offset_h
    )
  )
  labs <- read_required(file.path(results, paste0("did_labs_all_", tag, ".csv")))
  if (!("pid" %in% names(labs))) labs$pid <- labs[[id_col]]
  for (lab in c("albumin", "lactate", "heartrate", "hemoglobin")) {
    old <- select_value(labs, index, inclusive = FALSE, lab_name = lab)
    at_or_before <- select_value(labs, index, inclusive = TRUE, lab_name = lab)
    rows[[length(rows) + 1L]] <- compare_values(
      tag, paste0(lab, "@T0"), old, at_or_before
    )
  }
  if (tag == "mimic") {
    map_stream <- read_required(file.path(results, "strm_map_mimic.csv"))
    if (!("pid" %in% names(map_stream))) map_stream$pid <- map_stream$stay_id
    old <- select_value(
      transform(map_stream, value = map),
      index, inclusive = FALSE
    )
    at_or_before <- select_value(
      transform(map_stream, value = map),
      index, inclusive = TRUE
    )
    rows[[length(rows) + 1L]] <- compare_values(
      tag, "MAP@T0", old, at_or_before
    )
  }
}

out <- do.call(rbind, rows)
write.csv(out, file.path(results, "probe_at_t0_identity.csv"), row.names = FALSE)
print(out, row.names = FALSE)
if (any(out$n_values_changed != 0)) {
  stop("VERIFY FAIL: at/before-T0 selection changes one or more covariate values")
}
cat("VERIFY PASS: all relabeled covariate values are unchanged.\n")
