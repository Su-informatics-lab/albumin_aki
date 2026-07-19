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

MAIN_PS_SET <- "S2_PLUS_AORTIC"

main_ps_vars <- function(db, variant, analysis_set = "primary") {
  db <- tolower(db)
  variant <- tolower(variant)
  analysis_set <- tolower(analysis_set)
  if (!(db %in% c("mimic", "eicu"))) stop("Unknown database: ", db)
  if (!(variant %in% c("pooled", "egfr"))) stop("Unknown variant: ", variant)
  if (!(analysis_set %in% c("primary", "s2_no_aortic"))) {
    stop("Unknown analysis set: ", analysis_set)
  }
  # v3.3: MIMIC primary is S2 + aortic. eICU is supplementary and omits
  # vaso/MAP (informative missingness) and the post-T0-contaminated APACHE
  # day-1 ventilation proxy.
  vars <- if (db == "mimic" && analysis_set == "primary") {
    c(COVARIATE_SETS$S2, "surg_aortic")
  } else if (db == "mimic") {
    COVARIATE_SETS$S2
  } else if (analysis_set == "primary") {
    c(PS_BASE, "surg_aortic")
  } else {
    PS_BASE
  }
  if (variant == "egfr") vars <- setdiff(vars, c("egfr", "ckd"))
  vars
}

covariate_display_label <- function(variable) {
  labels <- c(
    age = "age",
    is_female = "sex",
    bmi = "BMI",
    surg_cabg = "CABG surgery",
    surg_valve = "valve surgery",
    surg_combined = "combined surgery",
    surg_aortic = "aortic surgery",
    heart_failure = "heart failure",
    hypertension = "hypertension",
    diabetes = "diabetes",
    copd = "COPD",
    pvd = "peripheral vascular disease",
    stroke = "stroke",
    liver_disease = "liver disease",
    egfr = "baseline (at ICU T0): eGFR",
    last_lactate = "baseline (at ICU T0): lactate",
    last_lactate_missing = "baseline (at ICU T0): lactate missing",
    last_heartrate = "baseline (at ICU T0): heart rate",
    last_hemoglobin = "baseline (at ICU T0): hemoglobin",
    alb_cat = "baseline (at ICU T0): serum albumin category",
    vaso_at_t0 = "baseline (at ICU T0): vasopressor status",
    map_before_t0 = "baseline (at ICU T0): MAP",
    vent_at_t0 = "baseline (at ICU T0): ventilation status"
  )
  out <- unname(labels[variable])
  out[is.na(out)] <- variable[is.na(out)]
  out
}

result_suffix <- function(variant, tag, analysis_set = "primary") {
  if (analysis_set == "primary") {
    sprintf("%s_%s", variant, tag)
  } else {
    sprintf("%s_%s_%s", variant, analysis_set, tag)
  }
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
