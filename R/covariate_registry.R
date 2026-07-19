# Ordered, cumulative MIMIC pooled covariate registry for Entry 8b.

PS_BASE <- c(
  "age", "is_female", "bmi",
  "surg_cabg", "surg_valve", "surg_combined",
  "heart_failure", "hypertension", "diabetes", "ckd",
  "copd", "pvd", "stroke", "liver_disease", "egfr"
)

COVARIATE_SETS <- list(
  S0 = c(
    PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
    "last_heartrate", "last_hemoglobin", "alb_cat"
  ),
  S1 = c(
    PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
    "last_heartrate", "last_hemoglobin", "alb_cat", "surg_aortic"
  ),
  S2 = c(
    PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
    "last_heartrate", "last_hemoglobin", "alb_cat", "surg_aortic",
    "vent_at_t0"
  ),
  S3 = c(
    PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
    "last_heartrate", "last_hemoglobin", "alb_cat", "surg_aortic",
    "vent_at_t0", "vaso_at_t0"
  ),
  S4 = c(
    PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
    "last_heartrate", "last_hemoglobin", "alb_cat", "surg_aortic",
    "vent_at_t0", "vaso_at_t0", "map_before_t0"
  ),
  S5 = c(
    PS_BASE, "last_calcium", "last_lactate", "last_lactate_missing",
    "last_heartrate", "last_hemoglobin", "alb_cat", "surg_aortic",
    "vent_at_t0", "vaso_at_t0", "map_before_t0",
    "last_platelet", "last_inr", "last_bun", "last_bicarbonate",
    "last_sodium", "last_hct"
  )
)

last_value_before_index <- function(stream, index, value_col = "value",
                                    lab_name = NULL) {
  if (is.null(stream) || nrow(stream) == 0) {
    return(setNames(rep(NA_real_, nrow(index)), as.character(index$pid)))
  }
  sub <- stream
  if (!is.null(lab_name)) sub <- sub[sub$lab_name == lab_name, , drop = FALSE]
  sub$index_h <- index$index_h[match(sub$pid, index$pid)]
  sub <- sub[
    !is.na(sub$index_h) & !is.na(sub$offset_h) &
      sub$offset_h < sub$index_h,
    , drop = FALSE
  ]
  if (nrow(sub) == 0) {
    return(setNames(rep(NA_real_, nrow(index)), as.character(index$pid)))
  }
  sub <- sub[order(sub$pid, -sub$offset_h, -sub[[value_col]]), , drop = FALSE]
  sub <- sub[!duplicated(sub$pid), , drop = FALSE]
  out <- setNames(rep(NA_real_, nrow(index)), as.character(index$pid))
  out[as.character(sub$pid)] <- as.numeric(sub[[value_col]])
  out
}

state_at_index <- function(stream, index) {
  out <- setNames(rep(0L, nrow(index)), as.character(index$pid))
  if (is.null(stream) || nrow(stream) == 0) return(out)
  sub <- stream
  sub$index_h <- index$index_h[match(sub$pid, index$pid)]
  active <- !is.na(sub$index_h) & !is.na(sub$t_start_h) &
    !is.na(sub$t_end_h) & sub$t_start_h <= sub$index_h &
    sub$t_end_h >= sub$index_h
  out[as.character(unique(sub$pid[active]))] <- 1L
  out
}

build_sweep_covariates <- function(all_pts, labs, labs_ext, surg, vent, vaso,
                                   map_stream) {
  # Treated/future-treated patients use own first-albumin T0. Never-treated
  # patients use their early Cr anchor, which is no later than any eligible
  # matched T0. This preserves the existing mg static-covariate architecture
  # while preventing unbounded post-index extraction.
  index_h <- ifelse(
    !is.na(all_pts$alb_offset_h),
    all_pts$alb_offset_h,
    all_pts$cr_ref_early_offset_h
  )
  index <- data.frame(pid = all_pts$pid, index_h = index_h)
  for (lab in c("albumin", "calcium", "lactate", "heartrate", "hemoglobin")) {
    values <- last_value_before_index(labs, index, lab_name = lab)
    all_pts[[paste0("last_", lab)]] <- values[as.character(all_pts$pid)]
  }
  all_pts$last_lactate_missing <- as.integer(is.na(all_pts$last_lactate))
  all_pts$alb_cat <- factor(
    ifelse(
      is.na(all_pts$last_albumin), "missing",
      ifelse(all_pts$last_albumin < 3.5, "low", "normal")
    ),
    levels = c("normal", "low", "missing")
  )
  all_pts$surg_aortic <- 0L
  if (!is.null(surg) && nrow(surg) > 0) {
    all_pts$surg_aortic <- as.integer(
      surg$surg_aortic[match(all_pts$pid, surg$pid)]
    )
    all_pts$surg_aortic[is.na(all_pts$surg_aortic)] <- 0L
  }
  all_pts$vent_at_t0 <- state_at_index(vent, index)[as.character(all_pts$pid)]
  all_pts$vaso_at_t0 <- state_at_index(vaso, index)[as.character(all_pts$pid)]
  map_values <- last_value_before_index(
    transform(map_stream, value = map), index, value_col = "value"
  )
  all_pts$map_before_t0 <- map_values[as.character(all_pts$pid)]
  for (lab in c("platelet", "inr", "bun", "bicarbonate", "sodium", "hct")) {
    values <- last_value_before_index(labs_ext, index, lab_name = lab)
    all_pts[[paste0("last_", lab)]] <- values[as.character(all_pts$pid)]
  }
  all_pts
}
