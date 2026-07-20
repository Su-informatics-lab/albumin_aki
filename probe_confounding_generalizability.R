#!/usr/bin/env Rscript
# Read-only Entry-31 confounding/generalizability battery on frozen v3.3 pairs.
# No propensity score is fit and no matching, exposure, baseline, or censoring
# decision is changed. Usage: Rscript probe_confounding_generalizability.R
# {mimic|eicu|iuh}

suppressPackageStartupMessages({
  library(sandwich)
  library(lmtest)
  library(mice)
  library(metafor)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1 || !(tolower(args[1]) %in% c("mimic", "eicu", "iuh"))) {
  stop("Usage: Rscript probe_confounding_generalizability.R {mimic|eicu|iuh}")
}
tag <- tolower(args[1])
db <- toupper(tag)
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
file_arg <- sub("^--file=", "", file_arg[1])
repo <- dirname(normalizePath(file_arg))
source(file.path(repo, "R", "causal_helpers.R"))
source(file.path(repo, "R", "covariate_registry.R"))

RESULTS <- path.expand(Sys.getenv(
  "ALBUMIN_AKI_RESULTS", unset = "~/albumin_aki/results"
))
EICU_ROOT <- path.expand(Sys.getenv(
  "EICU_ROOT", unset = "~/mg_aki/eicu-crd-2.0"
))
SEED <- 2026
M_IMP <- 20
AKI1 <- c("aki1_48h", "aki1_7d")

safe_read <- function(name) {
  path <- file.path(RESULTS, name)
  if (!file.exists(path)) stop("Missing required frozen input: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

build_main_covariates_probe <- function(all_pts, labs, tag) {
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
  surg <- safe_read(sprintf("surg_%s.csv", tag))
  all_pts$surg_aortic <- as.integer(
    surg$surg_aortic[match(all_pts$pid, surg$pid)]
  )
  all_pts$surg_aortic[is.na(all_pts$surg_aortic)] <- 0L
  if (tag %in% c("mimic", "iuh")) {
    vent <- safe_read(sprintf("strm_vent_%s.csv", tag))
    vaso <- safe_read(sprintf("strm_vaso_%s.csv", tag))
    map_stream <- safe_read(sprintf("strm_map_%s.csv", tag))
    all_pts$vent_at_t0 <- state_at_index(vent, index)[as.character(all_pts$pid)]
    all_pts$vaso_at_t0 <- state_at_index(vaso, index)[as.character(all_pts$pid)]
    map_values <- last_value_before_index(
      transform(map_stream, value = map), index, value_col = "value"
    )
    all_pts$map_before_t0 <- map_values[as.character(all_pts$pid)]
  } else {
    # eICU MAP is descriptive available-case only. Vaso lacks reliable
    # intervals and ventilation is a post-T0-contaminated APACHE day-1 proxy.
    map_stream <- safe_read("strm_map_eicu.csv")
    map_values <- last_value_before_index(
      transform(map_stream, value = map), index, value_col = "value"
    )
    all_pts$map_before_t0_descriptive <- map_values[
      as.character(all_pts$pid)
    ]
  }
  all_pts
}

complete_frozen_covariates <- function(dat, vars) {
  numeric_vars <- vars[
    !vapply(dat[vars], function(x) is.factor(x) || is.character(x), logical(1))
  ]
  impute_vars <- numeric_vars[
    vapply(numeric_vars, function(v) any(is.na(dat[[v]])), logical(1))
  ]
  if (length(impute_vars)) {
    base <- dat[, c("treated", numeric_vars), drop = FALSE]
    methods <- rep("", ncol(base))
    names(methods) <- names(base)
    methods[impute_vars] <- "pmm"
    set.seed(SEED)
    imp <- mice(
      base, m = M_IMP, method = methods, maxit = 10, printFlag = FALSE
    )
    completed <- complete(imp, 1)
    dat[numeric_vars] <- completed[numeric_vars]
  }
  dat
}

evalue_rr <- function(rr) {
  if (is.na(rr)) return(NA_real_)
  if (rr < 1) rr <- 1 / rr
  rr + sqrt(rr * (rr - 1))
}

matched_rr <- function(y_t, y_c) {
  valid <- !is.na(y_t) & !is.na(y_c)
  y_t <- y_t[valid]
  y_c <- y_c[valid]
  n <- length(y_t)
  dat <- data.frame(
    outcome = c(y_t, y_c),
    treated = rep(c(1L, 0L), each = n)
  )
  fit <- glm(outcome ~ treated, data = dat, family = poisson(link = "log"))
  ct <- safe_hc1(fit)
  beta <- ct["treated", 1]
  se <- ct["treated", 2]
  c(
    n = n, rate_trt = mean(y_t), rate_ctl = mean(y_c),
    rr = exp(beta), rr_ci_lo = exp(beta - 1.96 * se),
    rr_ci_hi = exp(beta + 1.96 * se)
  )
}

make_evalues <- function(pairs, tag) {
  canonical <- safe_read(sprintf("did_binary_pooled_%s.csv", tag))
  rows <- list()
  for (outcome in AKI1) {
    y_t <- pairs[[paste0(outcome, "_trt")]]
    y_c <- pairs[[paste0(outcome, "_ctl")]]
    rr <- matched_rr(y_t, y_c)
    dr <- canonical[
      canonical$stratum == "Overall" & canonical$outcome == outcome &
        canonical$method == "dr",
    ]
    if (nrow(dr) != 1L) stop("Missing canonical DR row for ", outcome)
    if (max(abs(c(
      rr["rate_trt"] - dr$rate_trt,
      rr["rate_ctl"] - dr$rate_ctl
    ))) > 1e-12) {
      stop("Matched-rate reconciliation failed for ", tag, " ", outcome)
    }
    rr_near <- if (rr["rr"] >= 1) rr["rr_ci_lo"] else rr["rr_ci_hi"]
    rows[[length(rows) + 1L]] <- data.frame(
      db = db, outcome = outcome, estimate_context = "matched_rate_rr",
      n_pairs = unname(rr["n"]),
      rate_trt = unname(rr["rate_trt"]),
      rate_ctl = unname(rr["rate_ctl"]),
      rr = unname(rr["rr"]), rr_ci_lo = unname(rr["rr_ci_lo"]),
      rr_ci_hi = unname(rr["rr_ci_hi"]),
      evalue_point = evalue_rr(unname(rr["rr"])),
      evalue_ci_near_null = if (
        (rr["rr"] >= 1 && rr["rr_ci_lo"] <= 1) ||
          (rr["rr"] < 1 && rr["rr_ci_hi"] >= 1)
      ) 1 else evalue_rr(unname(rr_near)),
      dr_rd = dr$rd, dr_rd_ci_lo = dr$rd_ci_lo, dr_rd_ci_hi = dr$rd_ci_hi,
      note = paste(
        "RR is treated/control observed matched rate; HC1 log-link CI.",
        "Frozen DR OR is not treated as an RR."
      )
    )
    rr_rd <- (dr$rate_ctl + dr$rd) / dr$rate_ctl
    rr_rd_lo <- (dr$rate_ctl + dr$rd_ci_lo) / dr$rate_ctl
    rr_rd_hi <- (dr$rate_ctl + dr$rd_ci_hi) / dr$rate_ctl
    rr_rd_near <- if (rr_rd >= 1) rr_rd_lo else rr_rd_hi
    rows[[length(rows) + 1L]] <- data.frame(
      db = db, outcome = outcome, estimate_context = "dr_rd_implied_rr",
      n_pairs = dr$n, rate_trt = dr$rate_ctl + dr$rd,
      rate_ctl = dr$rate_ctl, rr = rr_rd, rr_ci_lo = rr_rd_lo,
      rr_ci_hi = rr_rd_hi, evalue_point = evalue_rr(rr_rd),
      evalue_ci_near_null = if (
        (rr_rd >= 1 && rr_rd_lo <= 1) || (rr_rd < 1 && rr_rd_hi >= 1)
      ) 1 else evalue_rr(rr_rd_near),
      dr_rd = dr$rd, dr_rd_ci_lo = dr$rd_ci_lo, dr_rd_ci_hi = dr$rd_ci_hi,
      note = paste(
        "Context only: treated risk is matched control rate plus frozen DR RD;",
        "CI is the DR RD CI mapped onto that control rate."
      )
    )
  }
  do.call(rbind, rows)
}

smd_signed <- function(x1, x0) {
  x1 <- as.numeric(x1)
  x0 <- as.numeric(x0)
  sp <- sqrt((var(x1, na.rm = TRUE) + var(x0, na.rm = TRUE)) / 2)
  if (is.na(sp) || sp < 1e-12) return(NA_real_)
  (mean(x1, na.rm = TRUE) - mean(x0, na.rm = TRUE)) / sp
}

prematch_row <- function(all_pts, variable, label, source, note = "") {
  x1 <- all_pts[[variable]][all_pts$treated == 1]
  x0 <- all_pts[[variable]][all_pts$treated == 0]
  data.frame(
    db = db, comparison = "eligible ever-treated vs never-treated source cohort",
    variable = variable, label = label,
    n_treated = length(x1), n_control = length(x0),
    coverage_treated = mean(!is.na(x1)), coverage_control = mean(!is.na(x0)),
    mean_or_prevalence_treated = mean(as.numeric(x1), na.rm = TRUE),
    mean_or_prevalence_control = mean(as.numeric(x0), na.rm = TRUE),
    signed_smd = smd_signed(x1, x0),
    abs_smd = abs(smd_signed(x1, x0)), source = source, note = note
  )
}

unavailable_prematch_row <- function(variable, label, note) {
  data.frame(
    db = db, comparison = "not available as a clean pre-T0 comparison",
    variable = variable, label = label, n_treated = NA_integer_,
    n_control = NA_integer_, coverage_treated = NA_real_,
    coverage_control = NA_real_, mean_or_prevalence_treated = NA_real_,
    mean_or_prevalence_control = NA_real_, signed_smd = NA_real_,
    abs_smd = NA_real_, source = "unavailable", note = note
  )
}

make_prematch <- function(all_pts, tag) {
  rows <- list(
    prematch_row(
      all_pts, "egfr", "baseline eGFR", "did_all",
      "Same raw source-cohort contrast used in frozen balance tables."
    )
  )
  if (tag %in% c("mimic", "iuh")) {
    rows <- c(rows, list(
      prematch_row(
        all_pts, "vaso_at_t0", "vasopressor status at T0", "interval stream"
      ),
      prematch_row(
        all_pts, "map_before_t0", "most recent MAP strictly before T0",
        "MAP stream"
      ),
      prematch_row(
        all_pts, "vent_at_t0", "ventilation status at T0", "interval stream"
      )
    ))
  } else {
    rows <- c(rows, list(
      unavailable_prematch_row(
        "vaso_at_t0", "vasopressor status at T0",
        "eICU medication records lack a clean continuous-at-T0 interval."
      ),
      prematch_row(
        all_pts, "map_before_t0_descriptive",
        "most recent MAP strictly before T0 (available case)",
        "eICU MAP stream",
        "Informative hospital-level missingness; descriptive only and excluded from PS."
      ),
      unavailable_prematch_row(
        "vent_at_t0", "ventilation status at T0",
        "Available APACHE day-1 proxy is post-T0 contaminated and was excluded."
      )
    ))
  }
  if (tag == "mimic") {
    blood <- safe_read("strm_blood_mimic.csv")
    index <- data.frame(
      pid = all_pts$pid,
      index_h = ifelse(
        !is.na(all_pts$alb_offset_h),
        all_pts$alb_offset_h,
        all_pts$cr_ref_early_offset_h
      )
    )
    all_pts$rbc_before_t0 <- sum_before_index(
      blood, index, "amount",
      filter = function(x) x$product == "RBC", binary = TRUE
    )[as.character(all_pts$pid)]
    rows <- c(rows, list(prematch_row(
      all_pts, "rbc_before_t0", "any RBC administration strictly before T0",
      "MIMIC inputevents",
      paste(
        "MIMIC-only bleeding/transfusion proxy; near-path and index reference",
        "differs for never-treated controls, so descriptive only."
      )
    )))
  } else {
    rows <- c(rows, list(unavailable_prematch_row(
      "rbc_before_t0", "any RBC administration strictly before T0",
      "No harmonized pre-T0 transfusion stream in this analysis frame."
    )))
  }
  do.call(rbind, rows)
}

numeric_case_row <- function(x, domain, measure, unit, provenance, note = "") {
  data.frame(
    db = db, cohort = "frozen matched treated patients",
    domain = domain, measure = measure, level = NA_character_,
    n_total = length(x), n_nonmissing = sum(!is.na(x)), count = NA_integer_,
    percent = NA_real_, mean = mean(x, na.rm = TRUE),
    sd = sd(x, na.rm = TRUE),
    q25 = as.numeric(quantile(x, 0.25, na.rm = TRUE)),
    median = median(x, na.rm = TRUE),
    q75 = as.numeric(quantile(x, 0.75, na.rm = TRUE)),
    unit = unit, provenance = provenance, note = note
  )
}

categorical_case_rows <- function(x, domain, measure, provenance, note = "") {
  x <- as.character(x)
  x[is.na(x) | !nzchar(x)] <- "unknown"
  tab <- table(x)
  data.frame(
    db = db, cohort = "frozen matched treated patients",
    domain = domain, measure = measure, level = names(tab),
    n_total = length(x), n_nonmissing = sum(x != "unknown"),
    count = as.integer(tab), percent = as.numeric(tab) / length(x),
    mean = NA_real_, sd = NA_real_, q25 = NA_real_, median = NA_real_,
    q75 = NA_real_, unit = "proportion", provenance = provenance, note = note
  )
}

unavailable_case_row <- function(domain, measure, note) {
  data.frame(
    db = db, cohort = "frozen matched treated patients",
    domain = domain, measure = measure, level = "not_available",
    n_total = NA_integer_, n_nonmissing = 0L, count = NA_integer_,
    percent = NA_real_, mean = NA_real_, sd = NA_real_, q25 = NA_real_,
    median = NA_real_, q75 = NA_real_, unit = NA_character_,
    provenance = "unavailable", note = note
  )
}

normalize_product <- function(x) {
  z <- tolower(as.character(x))
  ifelse(
    grepl("25", z), "25pct",
    ifelse(grepl("(^|_)5|5pct", z), "5pct", "unknown")
  )
}

make_case_mix <- function(all_pts, pairs, tag) {
  treated <- all_pts[match(pairs$trt_pid, all_pts$pid), , drop = FALSE]
  if (any(is.na(treated$pid))) stop("Treated pair member missing from did_all")
  como_vars <- c(
    "heart_failure", "hypertension", "diabetes", "ckd",
    "copd", "pvd", "stroke", "liver_disease"
  )
  treated$comorbidity_count <- rowSums(treated[como_vars], na.rm = TRUE)
  timing_provenance <- if (tag == "iuh") {
    "Hours from postop_start=max(ICU entry, surgery stop) to first albumin"
  } else {
    "Hours from ICU admission to first albumin; exact surgery-stop offset unavailable"
  }
  product_note <- switch(
    tag,
    mimic = paste(
      "Nominal item label only. Entry 25 showed 5%/25% item labels cannot",
      "reliably establish administered concentration or grams."
    ),
    eicu = "Product concentration is not identifiable in the aligned exposure.",
    iuh = "Source-derived product label; descriptive only, not a dose exposure."
  )
  rows <- list(
    categorical_case_rows(
      normalize_product(treated$alb_product), "albumin_practice",
      "first_albumin_product_label", "did_all alb_product", product_note
    ),
    numeric_case_row(
      treated$alb_offset_h, "albumin_practice",
      "first_albumin_time_from_icu_or_postop_start", "hours",
      timing_provenance
    ),
    numeric_case_row(
      rep(0, nrow(treated)), "albumin_practice",
      "first_albumin_time_from_T0", "hours", "T0 is first albumin by definition"
    ),
    categorical_case_rows(
      treated$surgery_type, "case_mix", "surgery_type",
      "database-aligned surgery classifier"
    ),
    categorical_case_rows(
      ifelse(treated$surg_aortic == 1, "aortic", "not_aortic"),
      "case_mix", "aortic_surgery", "surg file"
    ),
    numeric_case_row(treated$age, "case_mix", "age", "years", "did_all"),
    numeric_case_row(
      treated$egfr, "case_mix", "baseline_egfr", "mL/min/1.73m2", "did_all"
    ),
    numeric_case_row(
      treated$comorbidity_count, "case_mix", "comorbidity_count_8",
      "count", paste("Sum of", paste(como_vars, collapse = ", "))
    ),
    unavailable_case_row(
      "case_mix", "cardiopulmonary_bypass_proxy",
      paste(
        "No validated harmonized CPB field. Surgery type is reported separately",
        "and is not relabeled as CPB."
      )
    ),
    unavailable_case_row(
      "albumin_practice", "exact_time_from_surgery_stop",
      if (tag == "iuh") {
        paste(
          "Aligned offset starts at max(ICU entry, surgery stop), not surgery stop",
          "alone; exact difference is not carried into did_all."
        )
      } else {
        "Exact surgery-stop timestamp is not carried into the aligned frozen frame."
      }
    )
  )
  do.call(rbind, rows)
}

estimate_pair_subset <- function(pairs, idx, all_pts, violations, group_type,
                                 group_level, metadata = list()) {
  y_t <- pairs$aki1_48h_trt[idx]
  y_c <- pairs$aki1_48h_ctl[idx]
  rows <- list()
  for (method in c("psm", "dr")) {
    adj_t <- adj_c <- NULL
    if (method == "dr" && length(violations)) {
      adj_t <- all_pts[pairs$trt_idx[idx], violations, drop = FALSE]
      adj_c <- all_pts[pairs$ctl_idx[idx], violations, drop = FALSE]
    }
    est <- pair_or_rd(y_t, y_c, adj_t, adj_c)
    valid <- !is.na(y_t) & !is.na(y_c)
    e_t <- sum(y_t[valid])
    e_c <- sum(y_c[valid])
    rows[[length(rows) + 1L]] <- cbind(
      data.frame(
        db = "EICU", group_type = group_type,
        group_level = as.character(group_level), method = method,
        events_trt = e_t, events_ctl = e_c,
        sparse_lt20 = e_t < 20 || e_c < 20,
        hospital_eligibility = sum(valid) >= 100 && e_t >= 20 && e_c >= 20
      ),
      as.data.frame(metadata, stringsAsFactors = FALSE),
      est
    )
  }
  do.call(rbind, rows)
}

make_hospital_outputs <- function(pairs, all_pts, violations) {
  patient_path <- file.path(EICU_ROOT, "patient.csv.gz")
  hospital_path <- file.path(EICU_ROOT, "hospital.csv.gz")
  if (!file.exists(patient_path) || !file.exists(hospital_path)) {
    stop("Missing raw eICU patient/hospital tables")
  }
  patient <- read.csv(gzfile(patient_path), stringsAsFactors = FALSE)
  hospital <- read.csv(gzfile(hospital_path), stringsAsFactors = FALSE)
  pid_to_hospital <- setNames(
    patient$hospitalid, as.character(patient$patientunitstayid)
  )
  pairs$trt_hospitalid <- pid_to_hospital[as.character(pairs$trt_pid)]
  pairs$ctl_hospitalid <- pid_to_hospital[as.character(pairs$ctl_pid)]
  if (any(is.na(pairs$trt_hospitalid))) stop("Unmapped treated eICU hospital")
  hospital$numbedscategory[
    is.na(hospital$numbedscategory) | !nzchar(hospital$numbedscategory)
  ] <- "Unknown"
  hospital$region[is.na(hospital$region) | !nzchar(hospital$region)] <- "Unknown"
  hospital$teachingstatus <- ifelse(
    tolower(hospital$teachingstatus) == "t", "Teaching", "Non-teaching"
  )

  effects <- list()
  for (hid in sort(unique(pairs$trt_hospitalid))) {
    idx <- which(pairs$trt_hospitalid == hid)
    meta <- hospital[hospital$hospitalid == hid, , drop = FALSE]
    effects[[length(effects) + 1L]] <- estimate_pair_subset(
      pairs, idx, all_pts, violations, "hospital", hid,
      metadata = list(
        hospitalid = hid,
        teachingstatus = if (nrow(meta)) meta$teachingstatus else "Unknown",
        numbedscategory = if (nrow(meta)) meta$numbedscategory else "Unknown",
        region = if (nrow(meta)) meta$region else "Unknown",
        same_hospital_pair_fraction = mean(
          pairs$trt_hospitalid[idx] == pairs$ctl_hospitalid[idx], na.rm = TRUE
        )
      )
    )
  }
  hospital_effects <- do.call(rbind, effects)

  pairs <- merge(
    pairs, hospital, by.x = "trt_hospitalid", by.y = "hospitalid",
    all.x = TRUE, sort = FALSE
  )
  groups <- list()
  for (variable in c("teachingstatus", "numbedscategory", "region")) {
    pairs[[variable]][is.na(pairs[[variable]]) | !nzchar(pairs[[variable]])] <-
      "Unknown"
    for (level in sort(unique(pairs[[variable]]))) {
      idx <- which(pairs[[variable]] == level)
      groups[[length(groups) + 1L]] <- estimate_pair_subset(
        pairs, idx, all_pts, violations, variable, level
      )
    }
  }
  hospital_groups <- do.call(rbind, groups)

  eligible <- hospital_effects[hospital_effects$hospital_eligibility, ]
  meta_rows <- list()
  for (method in c("psm", "dr")) {
    z <- eligible[eligible$method == method, ]
    for (scale in c("or", "rd")) {
      estimate <- z[[scale]]
      lo <- z[[paste0(scale, "_ci_lo")]]
      hi <- z[[paste0(scale, "_ci_hi")]]
      keep <- is.finite(estimate) & is.finite(lo) & is.finite(hi)
      z2 <- z[keep, ]
      if (scale == "or") {
        yi <- log(z2$or)
        sei <- (log(z2$or_ci_hi) - log(z2$or_ci_lo)) / (2 * 1.96)
      } else {
        yi <- z2$rd
        sei <- (z2$rd_ci_hi - z2$rd_ci_lo) / (2 * 1.96)
      }
      fit <- metafor::rma.uni(yi = yi, sei = sei, method = "REML")
      pred <- predict(fit)
      meta_rows[[length(meta_rows) + 1L]] <- data.frame(
        db = "EICU", method = method, scale = scale,
        n_hospitals = nrow(z2),
        pooled_estimate = if (scale == "or") exp(pred$pred) else pred$pred,
        ci_lo = if (scale == "or") exp(pred$ci.lb) else pred$ci.lb,
        ci_hi = if (scale == "or") exp(pred$ci.ub) else pred$ci.ub,
        p = fit$pval, tau2 = fit$tau2, i2 = fit$I2,
        eligibility = ">=100 pairs and >=20 AKI events in each arm"
      )
    }
  }
  hospital_meta <- do.call(rbind, meta_rows)

  distribution_rows <- list()
  for (method in c("psm", "dr")) {
    z <- eligible[eligible$method == method, ]
    for (scale in c("or", "rd")) {
      x <- z[[scale]]
      distribution_rows[[length(distribution_rows) + 1L]] <- data.frame(
        db = "EICU", method = method, scale = scale,
        n_hospitals = length(x), min = min(x, na.rm = TRUE),
        q25 = as.numeric(quantile(x, 0.25, na.rm = TRUE)),
        median = median(x, na.rm = TRUE),
        q75 = as.numeric(quantile(x, 0.75, na.rm = TRUE)),
        max = max(x, na.rm = TRUE),
        n_or_ge_1_5 = if (scale == "or") sum(x >= 1.5, na.rm = TRUE) else NA,
        same_hospital_pair_fraction = mean(
          z$same_hospital_pair_fraction, na.rm = TRUE
        )
      )
    }
  }
  hospital_distribution <- do.call(rbind, distribution_rows)
  list(
    effects = hospital_effects, groups = hospital_groups,
    meta = hospital_meta, distribution = hospital_distribution
  )
}

all_pts <- safe_read(sprintf("did_all_%s.csv", tag))
pairs <- safe_read(sprintf(
  "did_pairs_primary_yet_untreated_pooled_%s.csv", tag
))
labs <- safe_read(sprintf("did_labs_all_%s.csv", tag))
lab_id <- if ("patientunitstayid" %in% names(labs)) {
  "patientunitstayid"
} else {
  "stay_id"
}
labs$pid <- labs[[lab_id]]
all_pts <- build_main_covariates_probe(all_pts, labs, tag)
case_mix <- make_case_mix(all_pts, pairs, tag)
prematch <- make_prematch(all_pts, tag)

write.csv(
  case_mix,
  file.path(RESULTS, sprintf("generalizability_case_mix_%s.csv", tag)),
  row.names = FALSE
)
write.csv(
  prematch,
  file.path(RESULTS, sprintf("generalizability_prematch_smd_%s.csv", tag)),
  row.names = FALSE
)

if (tag %in% c("mimic", "eicu")) {
  evalues <- make_evalues(pairs, tag)
  write.csv(
    evalues,
    file.path(RESULTS, sprintf("confounding_evalue_%s.csv", tag)),
    row.names = FALSE
  )
}

if (tag == "eicu") {
  ps_vars <- main_ps_vars("eicu", "pooled", "primary")
  all_pts <- complete_frozen_covariates(all_pts, ps_vars)
  balance <- safe_read("psm_balance_pooled_eicu.csv")
  violations <- balance$variable_code[
    balance$stratum == "Overall" & balance$smd > 0.1
  ]
  hospital_outputs <- make_hospital_outputs(pairs, all_pts, violations)
  write.csv(
    hospital_outputs$effects,
    file.path(RESULTS, "eicu_hospital_effects.csv"), row.names = FALSE
  )
  write.csv(
    hospital_outputs$groups,
    file.path(RESULTS, "eicu_hospital_groups.csv"), row.names = FALSE
  )
  write.csv(
    hospital_outputs$meta,
    file.path(RESULTS, "eicu_hospital_meta.csv"), row.names = FALSE
  )
  write.csv(
    hospital_outputs$distribution,
    file.path(RESULTS, "eicu_hospital_distribution.csv"), row.names = FALSE
  )
}

cat(sprintf(
  paste0(
    "probe_confounding_generalizability.R | %s | COMPLETE | pairs=%d | ",
    "no rematch/PS fit | aggregate outputs only\n"
  ),
  db, nrow(pairs)
))
