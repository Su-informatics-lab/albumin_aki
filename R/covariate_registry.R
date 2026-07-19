# Entry 10 cumulative MIMIC pooled covariate registry.

PS_BASE <- c(
  "age", "is_female", "bmi",
  "surg_cabg", "surg_valve", "surg_combined",
  "heart_failure", "hypertension", "diabetes",
  "copd", "pvd", "stroke", "liver_disease", "egfr",
  "last_lactate", "last_lactate_missing", "last_heartrate",
  "last_hemoglobin", "alb_cat"
)

COVARIATE_SETS <- list(
  S0 = PS_BASE,
  S1 = c(PS_BASE, "vaso_at_t0"),
  S2 = c(PS_BASE, "vaso_at_t0", "map_before_t0", "vent_at_t0"),
  S3 = c(
    PS_BASE, "vaso_at_t0", "map_before_t0", "vent_at_t0",
    "last_platelet", "last_inr", "last_hct", "last_bicarbonate",
    "last_bun", "last_sodium"
  ),
  S4 = c(
    PS_BASE, "vaso_at_t0", "map_before_t0", "vent_at_t0",
    "last_platelet", "last_inr", "last_hct", "last_bicarbonate",
    "last_bun", "last_sodium",
    "rbc_before_t0", "crystalloid_before_t0", "urine_before_t0"
  ),
  S5 = c(
    PS_BASE, "vaso_at_t0", "map_before_t0", "vent_at_t0",
    "last_platelet", "last_inr", "last_hct", "last_bicarbonate",
    "last_bun", "last_sodium",
    "rbc_before_t0", "crystalloid_before_t0", "urine_before_t0",
    "surg_aortic", "prior_cardiac_surgery"
  ),
  S6 = c(
    PS_BASE, "vaso_at_t0", "map_before_t0", "vent_at_t0",
    "last_platelet", "last_inr", "last_hct", "last_bicarbonate",
    "last_bun", "last_sodium",
    "rbc_before_t0", "crystalloid_before_t0", "urine_before_t0",
    "surg_aortic", "prior_cardiac_surgery", "last_wbc",
    "loop_diuretic", "acei_arb", "nsaid", "ppi"
  )
)

MAIN_PS_SET <- "S2"

main_ps_vars <- function(db, variant) {
  db <- tolower(db)
  variant <- tolower(variant)
  if (!(db %in% c("mimic", "eicu"))) stop("Unknown database: ", db)
  if (!(variant %in% c("pooled", "egfr"))) stop("Unknown variant: ", variant)
  # Entry 12: eICU retains ventilation but excludes vaso/MAP because their
  # hospital-level missingness is informative.
  vars <- if (db == "mimic") {
    COVARIATE_SETS[[MAIN_PS_SET]]
  } else {
    c(PS_BASE, "vent_at_t0")
  }
  if (variant == "egfr") vars <- setdiff(vars, c("egfr", "ckd"))
  vars
}

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

sum_before_index <- function(stream, index, value_col, filter = NULL,
                             binary = FALSE) {
  out <- setNames(rep(0, nrow(index)), as.character(index$pid))
  if (is.null(stream) || nrow(stream) == 0) return(out)
  sub <- if (is.null(filter)) stream else stream[filter(stream), , drop = FALSE]
  sub$index_h <- index$index_h[match(sub$pid, index$pid)]
  sub <- sub[
    !is.na(sub$index_h) & !is.na(sub$offset_h) &
      sub$offset_h < sub$index_h,
    , drop = FALSE
  ]
  if (nrow(sub) == 0) return(out)
  if (binary) {
    out[as.character(unique(sub$pid))] <- 1
  } else {
    totals <- tapply(as.numeric(sub[[value_col]]), sub$pid, sum, na.rm = TRUE)
    out[names(totals)] <- totals
  }
  out
}

build_sweep_covariates <- function(all_pts, labs, labs_ext, surg, vent, vaso,
                                   map_stream, blood, fluid, output) {
  index_h <- ifelse(
    !is.na(all_pts$alb_offset_h),
    all_pts$alb_offset_h,
    all_pts$cr_ref_early_offset_h
  )
  index <- data.frame(pid = all_pts$pid, index_h = index_h)
  for (lab in c("albumin", "lactate", "heartrate", "hemoglobin")) {
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
  for (name in c("surg_aortic", "prior_cardiac_surgery")) {
    all_pts[[name]] <- as.integer(surg[[name]][match(all_pts$pid, surg$pid)])
    all_pts[[name]][is.na(all_pts[[name]])] <- 0L
  }
  all_pts$vent_at_t0 <- state_at_index(vent, index)[as.character(all_pts$pid)]
  all_pts$vaso_at_t0 <- state_at_index(vaso, index)[as.character(all_pts$pid)]
  map_values <- last_value_before_index(
    transform(map_stream, value = map), index, value_col = "value"
  )
  all_pts$map_before_t0 <- map_values[as.character(all_pts$pid)]
  for (lab in c(
    "platelet", "inr", "hct", "bicarbonate", "bun", "sodium", "wbc"
  )) {
    values <- last_value_before_index(labs_ext, index, lab_name = lab)
    all_pts[[paste0("last_", lab)]] <- values[as.character(all_pts$pid)]
  }
  all_pts$rbc_before_t0 <- sum_before_index(
    blood, index, "amount",
    filter = function(x) x$product == "RBC", binary = TRUE
  )[as.character(all_pts$pid)]
  all_pts$crystalloid_before_t0 <- sum_before_index(
    fluid, index, "amount_ml",
    filter = function(x) x$class == "crystalloid"
  )[as.character(all_pts$pid)]
  all_pts$urine_before_t0 <- sum_before_index(
    output, index, "amount_ml",
    filter = function(x) x$kind == "urine"
  )[as.character(all_pts$pid)]
  all_pts$loop_diuretic <- all_pts$loop_diuretic_chronic
  all_pts$acei_arb <- all_pts$acei_arb_chronic
  all_pts$nsaid <- all_pts$nsaid_chronic
  all_pts$ppi <- all_pts$ppi_chronic
  all_pts
}
