#!/usr/bin/env Rscript
# ============================================================================
# 02_psm_v2.R — 24h Landmark PSM for Albumin -> CSA-AKI (v2)
#
# Design:  T0 = ICU0 for all patients
#          Exposure: any IV albumin within ICU0 to ICU0+24h
#          Landmark: exclude death/RRT/stage>=2 AKI within 24h
#          Primary:  KDIGO stage 2-3 or new RRT, 24h to 7d
#          DiD:      continuous deltaCr at 6-48h horizons
#          F-MPAO:   death + AKI23 + major bleeding + prolonged MV + prolonged vaso
#          Secondary: individual components, infection, recovery
#
# Covariates: shared model (~30 var) from did_all + strm_* + labs_ext + surg
# Matching:   1:1 nearest-neighbor caliper=0.2*SD, MICE m=20
#
# Usage: Rscript 02_psm_v2.R mimic
#        Rscript 02_psm_v2.R eicu
# ============================================================================
suppressPackageStartupMessages({
  library(sandwich); library(lmtest); library(mice)
})

RESULTS    <- path.expand("~/albumin_aki/results")
CALIPER_SD <- 0.2
M_IMP      <- 20
TARGETS    <- c(6, 12, 18, 24, 30, 36, 42, 48)
CR_WINDOW  <- 12

args <- commandArgs(trailingOnly = TRUE)
tag  <- tolower(args[1])
if (!tag %in% c("mimic","eicu")) stop("Usage: Rscript 02_psm_v2.R {mimic|eicu}")
db   <- toupper(tag)
cat(sprintf("\n  02_psm_v2 [%s]\n", db))

safe_read <- function(name) {
  p <- file.path(RESULTS, name)
  if (file.exists(p)) read.csv(p, stringsAsFactors=FALSE) else NULL
}

# ═══════════════════════════════════════════════════════════════════
# 1. LOAD DATA
# ═══════════════════════════════════════════════════════════════════
cat("  loading data ...\n")
all_pts  <- read.csv(file.path(RESULTS, sprintf("did_all_%s.csv", tag)), stringsAsFactors=FALSE)
cr_all   <- read.csv(file.path(RESULTS, sprintf("did_cr_all_%s.csv", tag)), stringsAsFactors=FALSE)
labs_raw <- read.csv(file.path(RESULTS, sprintf("did_labs_all_%s.csv", tag)), stringsAsFactors=FALSE)
labs_ext <- safe_read(sprintf("labs_ext_%s.csv", tag))
surg     <- safe_read(sprintf("surg_%s.csv", tag))
vaso     <- safe_read(sprintf("strm_vaso_%s.csv", tag))
vent_seg <- safe_read(sprintf("strm_vent_%s.csv", tag))
ventset  <- safe_read(sprintf("strm_ventset_%s.csv", tag))
vent_bin <- safe_read(sprintf("vent_%s.csv", tag))  # eICU binary
map_data <- safe_read(sprintf("strm_map_%s.csv", tag))
vitals   <- safe_read(sprintf("strm_vitals_%s.csv", tag))
blood    <- safe_read(sprintf("strm_blood_%s.csv", tag))
output   <- safe_read(sprintf("strm_output_%s.csv", tag))
albdose  <- safe_read(sprintf("alb_dose_24h_%s.csv", tag))
llm      <- safe_read(sprintf("llm_endpoints_%s.csv", tag))

n_all <- nrow(all_pts)
cat(sprintf("  loaded: %d patients\n", n_all))

# normalize ID columns: MIMIC uses stay_id, eICU uses patientunitstayid, we want pid
norm_pid <- function(df) {
  if (is.null(df) || "pid" %in% names(df)) return(df)
  if ("stay_id" %in% names(df)) { names(df)[names(df)=="stay_id"] <- "pid"; return(df) }
  if ("patientunitstayid" %in% names(df)) { names(df)[names(df)=="patientunitstayid"] <- "pid"; return(df) }
  df
}
cr_all   <- norm_pid(cr_all)
labs_raw <- norm_pid(labs_raw)

# ═══════════════════════════════════════════════════════════════════
# 2. 24h LANDMARK
# ═══════════════════════════════════════════════════════════════════
cat("  applying 24h landmark ...\n")
# Exposure: treated = first albumin within 0-24h
has_alb <- !is.na(all_pts$alb_offset_h)
early   <- has_alb & all_pts$alb_offset_h <= 24
all_pts$treated_24h <- as.integer(early)

# Exclusions
death_24h <- !is.na(all_pts$death_offset_h) & all_pts$death_offset_h <= 24
rrt_24h   <- !is.na(all_pts$rrt_offset_h) & all_pts$rrt_offset_h <= 24

# Stage>=2 AKI within 24h (from cr_all)
cr_all$offset_h <- as.numeric(cr_all$offset_h)
cr_all$labresult <- as.numeric(ifelse("labresult" %in% names(cr_all), cr_all$labresult, cr_all$value))
# merge baseline Cr
bl <- setNames(all_pts$first_cr, all_pts$pid)
cr_all$bl <- bl[as.character(cr_all$pid)]
cr_24 <- cr_all[!is.na(cr_all$offset_h) & cr_all$offset_h > 0 & cr_all$offset_h <= 24 &
                !is.na(cr_all$bl) & cr_all$bl > 0 & !is.na(cr_all$labresult), ]
cr_24$ratio <- cr_24$labresult / cr_24$bl
cr_24$delta <- cr_24$labresult - cr_24$bl
aki2_pids <- unique(cr_24$pid[cr_24$ratio >= 2.0 | (cr_24$delta >= 0.3 & cr_24$ratio >= 1.5)])
aki2_24h <- all_pts$pid %in% aki2_pids

exclude <- death_24h | rrt_24h | aki2_24h
cat(sprintf("  landmark exclusions: death=%d  rrt=%d  aki2=%d  total=%d (%.1f%%)\n",
            sum(death_24h), sum(rrt_24h), sum(aki2_24h), sum(exclude), 100*mean(exclude)))

lm_pts <- all_pts[!exclude, ]
n_lm <- nrow(lm_pts)
n_trt <- sum(lm_pts$treated_24h)
n_ctl <- n_lm - n_trt
cat(sprintf("  landmark cohort: %d (treated=%d, control=%d)\n", n_lm, n_trt, n_ctl))

# ═══════════════════════════════════════════════════════════════════
# 3. COVARIATE WINDOWING (0-6h from ICU0)
# ═══════════════════════════════════════════════════════════════════
cat("  windowing covariates ...\n")
pids <- lm_pts$pid

# Helper: first value in window for a stream
first_in_window <- function(stream, pid_col="pid", val_col="value",
                            name_col=NULL, name_val=NULL, lo=0, hi=6) {
  if (is.null(stream)) return(setNames(rep(NA_real_, length(pids)), pids))
  s <- stream[stream[[pid_col]] %in% pids & stream$offset_h >= lo & stream$offset_h <= hi, ]
  if (!is.null(name_col) && !is.null(name_val))
    s <- s[s[[name_col]] == name_val, ]
  if (nrow(s) == 0) return(setNames(rep(NA_real_, length(pids)), pids))
  s <- s[order(s$offset_h), ]
  v <- s[!duplicated(s[[pid_col]]), ]
  out <- setNames(rep(NA_real_, length(pids)), pids)
  out[as.character(v[[pid_col]])] <- as.numeric(v[[val_col]])
  out
}

any_in_window <- function(stream, pid_col="pid", lo=0, hi=6) {
  if (is.null(stream)) return(setNames(rep(0L, length(pids)), pids))
  s <- stream[stream[[pid_col]] %in% pids & stream$offset_h >= lo & stream$offset_h <= hi, ]
  out <- setNames(rep(0L, length(pids)), pids)
  out[as.character(unique(s[[pid_col]]))] <- 1L
  out
}

# Extended labs (0-6h first value)
ext_labs <- list()
ext_lab_names <- c("platelet","inr","ptt","sodium","potassium","chloride",
                   "magnesium","bun","bicarbonate","ph","base_excess","wbc","hct")
for (lab in ext_lab_names) {
  ext_labs[[lab]] <- first_in_window(labs_ext, val_col="value", name_col="lab_name", name_val=lab)
}

# Vitals (0-6h first, MIMIC only)
vital_vars <- list()
if (!is.null(vitals)) {
  for (v in c("temperature","spo2","fio2","peep")) {
    vital_vars[[v]] <- first_in_window(vitals, val_col="value", name_col="vital", name_val=v)
  }
}

# MAP (0-6h mean)
map_mean <- setNames(rep(NA_real_, length(pids)), pids)
if (!is.null(map_data)) {
  m6 <- map_data[map_data$pid %in% pids & map_data$offset_h >= 0 & map_data$offset_h <= 6, ]
  mm <- tapply(as.numeric(m6$map), m6$pid, mean, na.rm=TRUE)
  map_mean[names(mm)] <- mm
}

# Vasopressor (any in 0-6h)
vaso_any <- any_in_window(vaso)

# Ventilation at T0 (any vent segment covering 0-3h OR ventset in 0-6h)
vent_at_t0 <- setNames(rep(0L, length(pids)), pids)
if (!is.null(vent_seg)) {
  vs <- vent_seg[vent_seg$pid %in% pids, ]
  covers <- vs$t_start_h <= 3 & vs$t_end_h >= 0  # segment overlaps 0-3h
  if (any(covers)) vent_at_t0[as.character(unique(vs$pid[covers]))] <- 1L
}
if (!is.null(ventset)) {
  vv <- ventset[ventset$pid %in% pids & ventset$offset_h >= 0 & ventset$offset_h <= 6, ]
  if (nrow(vv) > 0) vent_at_t0[as.character(unique(vv$pid))] <- 1L
}
if (!is.null(vent_bin)) {  # eICU: day-1 flag
  vb <- vent_bin[vent_bin$pid %in% pids, ]
  on <- vb$pid[!is.na(vb$vent_day1) & vb$vent_day1 > 0]
  vent_at_t0[as.character(on)] <- 1L
}

# Surgery flags
surg_aortic <- setNames(rep(0L, length(pids)), pids)
adm_emergency <- setNames(rep(0L, length(pids)), pids)
if (!is.null(surg)) {
  sp <- surg[surg$pid %in% pids, ]
  if ("surg_aortic" %in% names(sp))
    surg_aortic[as.character(sp$pid)] <- sp$surg_aortic
  if ("adm_emergency" %in% names(sp))
    adm_emergency[as.character(sp$pid)] <- sp$adm_emergency
}

# ═══════════════════════════════════════════════════════════════════
# 4. ASSEMBLE ANALYSIS DATA
# ═══════════════════════════════════════════════════════════════════
cat("  assembling analysis data ...\n")
ad <- data.frame(
  pid        = lm_pts$pid,
  treated    = lm_pts$treated_24h,
  # from did_all (existing)
  age        = lm_pts$age,
  is_female  = lm_pts$is_female,
  bmi        = lm_pts$bmi,
  surg_cabg  = lm_pts$surg_cabg,
  surg_valve = lm_pts$surg_valve,
  surg_combined = lm_pts$surg_combined,
  heart_failure = lm_pts$heart_failure,
  hypertension  = lm_pts$hypertension,
  diabetes      = lm_pts$diabetes,
  ckd           = lm_pts$ckd,
  copd          = lm_pts$copd,
  pvd           = lm_pts$pvd,
  stroke        = lm_pts$stroke,
  liver_disease = lm_pts$liver_disease,
  egfr          = lm_pts$egfr,
  hemoglobin    = lm_pts$last_hemoglobin,
  calcium       = lm_pts$last_calcium,
  lactate       = lm_pts$last_lactate,
  lactate_missing = lm_pts$last_lactate_missing,
  heartrate     = lm_pts$last_heartrate,
  first_cr      = lm_pts$first_cr,
  stringsAsFactors = FALSE
)
# add new covariates
ad$surg_aortic    <- surg_aortic[as.character(ad$pid)]
ad$vent_at_t0     <- vent_at_t0[as.character(ad$pid)]
ad$vaso_any_6h    <- vaso_any[as.character(ad$pid)]
for (lab in ext_lab_names) ad[[lab]] <- ext_labs[[lab]][as.character(ad$pid)]
for (v in names(vital_vars)) ad[[v]] <- vital_vars[[v]][as.character(ad$pid)]
ad$map_mean_6h <- map_mean[as.character(ad$pid)]

# ═══════════════════════════════════════════════════════════════════
# 5. PS MODEL + MATCHING
# ═══════════════════════════════════════════════════════════════════
# Shared model (both DBs): original v1.0 vars + vent + surg_aortic + platelet + INR + BUN + bicarb + Na + WBC + Hct
PS_SHARED <- c("age","is_female","bmi",
               "surg_cabg","surg_valve","surg_combined","surg_aortic",
               "heart_failure","hypertension","diabetes","ckd","copd","pvd","stroke","liver_disease",
               "egfr","hemoglobin","calcium","lactate","lactate_missing","heartrate",
               "vent_at_t0",
               "platelet","inr","bun","bicarbonate","sodium","wbc","hct")

# Verify all vars exist
avail <- PS_SHARED[PS_SHARED %in% names(ad)]
missing_ps <- setdiff(PS_SHARED, names(ad))
if (length(missing_ps) > 0) cat(sprintf("  WARNING: PS vars missing: %s\n", paste(missing_ps, collapse=", ")))

cat(sprintf("  PS shared model: %d vars\n", length(avail)))

# MICE
ad_mice <- ad[, c("treated", avail)]
cat(sprintf("  running MICE (m=%d) ...\n", M_IMP))
imp <- tryCatch(mice(ad_mice, m=M_IMP, method="pmm", printFlag=FALSE, seed=2026),
                error=function(e) { cat(sprintf("  MICE error: %s\n", e$message)); NULL })
if (is.null(imp)) stop("MICE failed")

# PS + matching across imputations
match_one <- function(dat) {
  ps_fml <- as.formula(paste("treated ~", paste(avail, collapse="+")))
  fit <- glm(ps_fml, data=dat, family=binomial)
  dat$ps <- predict(fit, type="response")
  ps_sd <- sd(dat$ps, na.rm=TRUE)
  cal <- CALIPER_SD * ps_sd

  trt_idx <- which(dat$treated == 1)
  ctl_idx <- which(dat$treated == 0)
  matched <- data.frame(trt_pid=integer(0), ctl_pid=integer(0))

  for (ti in trt_idx) {
    diffs <- abs(dat$ps[ctl_idx] - dat$ps[ti])
    best <- which.min(diffs)
    if (diffs[best] <= cal) {
      matched <- rbind(matched, data.frame(trt_pid=ad$pid[ti], ctl_pid=ad$pid[ctl_idx[best]]))
      ctl_idx <- ctl_idx[-best]
    }
    if (length(ctl_idx) == 0) break
  }
  matched
}

cat("  matching across imputations ...\n")
all_matches <- list()
for (m in 1:M_IMP) {
  d_m <- complete(imp, m)
  all_matches[[m]] <- match_one(d_m)
}

# Pool: keep pairs that appear in >= 50% of imputations
pair_key <- function(df) paste(df$trt_pid, df$ctl_pid, sep="_")
all_keys <- unlist(lapply(all_matches, pair_key))
freq <- table(all_keys)
stable <- names(freq[freq >= M_IMP / 2])
ref <- all_matches[[1]]
ref$key <- pair_key(ref)
pairs <- ref[ref$key %in% stable, c("trt_pid","ctl_pid")]
cat(sprintf("  matched pairs: %d (from %d treated)\n", nrow(pairs), n_trt))

# SMD check
smd_check <- function(var) {
  t_vals <- ad[[var]][ad$pid %in% pairs$trt_pid]
  c_vals <- ad[[var]][ad$pid %in% pairs$ctl_pid]
  mn_t <- mean(t_vals, na.rm=TRUE); mn_c <- mean(c_vals, na.rm=TRUE)
  sd_p <- sqrt((var(t_vals, na.rm=TRUE) + var(c_vals, na.rm=TRUE)) / 2)
  if (sd_p == 0) return(0)
  abs(mn_t - mn_c) / sd_p
}
cat("\n  Balance (SMD > 0.05 flagged):\n")
for (v in avail) {
  s <- smd_check(v)
  flag <- ifelse(s > 0.10, " ***", ifelse(s > 0.05, " *", ""))
  cat(sprintf("    %-18s %.3f%s\n", v, s, flag))
}

# ═══════════════════════════════════════════════════════════════════
# 6. PRIMARY: KDIGO 2-3 / RRT (24h -> 7d)
# ═══════════════════════════════════════════════════════════════════
cat("\n  PRIMARY: KDIGO 2-3 or RRT (24h -> 7d)\n")
compute_aki23_7d <- function(pid_val) {
  # RRT after 24h
  row <- all_pts[all_pts$pid == pid_val, ]
  if (!is.na(row$rrt_offset_h) && row$rrt_offset_h > 24 && row$rrt_offset_h <= 168) return(1L)
  # Cr-based KDIGO 2-3: ratio >= 2.0 (stage 2) or >= 3.0 (stage 3)
  bl_cr <- row$first_cr
  if (is.na(bl_cr) || bl_cr <= 0) return(NA)
  pt_cr <- cr_all[cr_all$pid == pid_val & cr_all$offset_h > 24 & cr_all$offset_h <= 168, ]
  if (nrow(pt_cr) == 0) return(0L)
  ratios <- pt_cr$labresult / bl_cr
  if (any(ratios >= 2.0, na.rm=TRUE)) return(1L)
  0L
}

pairs$aki23_trt <- sapply(pairs$trt_pid, compute_aki23_7d)
pairs$aki23_ctl <- sapply(pairs$ctl_pid, compute_aki23_7d)

valid <- !is.na(pairs$aki23_trt) & !is.na(pairs$aki23_ctl)
cat(sprintf("    valid pairs: %d\n", sum(valid)))
if (sum(valid) > 10) {
  fit <- glm(y ~ trt, data=data.frame(y=c(pairs$aki23_trt[valid], pairs$aki23_ctl[valid]),
                                       trt=c(rep(1, sum(valid)), rep(0, sum(valid)))),
             family=binomial)
  ci <- exp(confint.default(fit)["trt", ])
  or <- exp(coef(fit)["trt"])
  p  <- summary(fit)$coefficients["trt","Pr(>|z|)"]
  cat(sprintf("    rate trt=%.1f%%  ctl=%.1f%%  OR=%.2f [%.2f, %.2f]  P=%.4f\n",
              100*mean(pairs$aki23_trt[valid]), 100*mean(pairs$aki23_ctl[valid]),
              or, ci[1], ci[2], p))
} else cat("    insufficient valid pairs\n")

# ═══════════════════════════════════════════════════════════════════
# 7. DiD: Continuous deltaCr
# ═══════════════════════════════════════════════════════════════════
cat("\n  DiD: continuous deltaCr\n")
find_cr <- function(pid_val, target_h, window=CR_WINDOW) {
  pt <- cr_all[cr_all$pid == pid_val, ]
  cand <- pt[pt$offset_h >= (target_h - window) & pt$offset_h <= (target_h + window), ]
  if (nrow(cand) == 0) return(NA)
  cand$labresult[which.min(abs(cand$offset_h - target_h))]
}

did_rows <- list()
for (h in TARGETS) {
  dcr_t <- sapply(pairs$trt_pid, function(p) {
    bl <- all_pts$first_cr[all_pts$pid == p]
    cr_h <- find_cr(p, h)
    if (is.na(bl) || is.na(cr_h)) return(NA)
    cr_h - bl
  })
  dcr_c <- sapply(pairs$ctl_pid, function(p) {
    bl <- all_pts$first_cr[all_pts$pid == p]
    cr_h <- find_cr(p, h)
    if (is.na(bl) || is.na(cr_h)) return(NA)
    cr_h - bl
  })
  v <- !is.na(dcr_t) & !is.na(dcr_c)
  did <- mean(dcr_t[v]) - mean(dcr_c[v])
  se  <- sqrt(var(dcr_t[v])/sum(v) + var(dcr_c[v])/sum(v))
  cat(sprintf("    %2dh: DiD = %+.4f  SE=%.4f  n=%d  trt_mean=%+.4f  ctl_mean=%+.4f\n",
              h, did, se, sum(v), mean(dcr_t[v]), mean(dcr_c[v])))
  did_rows[[length(did_rows)+1]] <- data.frame(db=db, horizon_h=h, did=did, se=se, n=sum(v),
                                                mean_trt=mean(dcr_t[v]), mean_ctl=mean(dcr_c[v]))
}
did_df <- do.call(rbind, did_rows)
write.csv(did_df, file.path(RESULTS, sprintf("did_results_%s.csv", tag)), row.names=FALSE)

# ═══════════════════════════════════════════════════════════════════
# 8. BINARY SECONDARY ENDPOINTS
# ═══════════════════════════════════════════════════════════════════
cat("\n  Binary secondary endpoints\n")

compute_binary <- function(outcome_fn, label) {
  y_t <- sapply(pairs$trt_pid, outcome_fn)
  y_c <- sapply(pairs$ctl_pid, outcome_fn)
  v <- !is.na(y_t) & !is.na(y_c)
  nv <- sum(v)
  if (nv < 10) return(data.frame(db=db, outcome=label, n=nv, rate_trt=NA, rate_ctl=NA,
                                  or=NA, ci_lo=NA, ci_hi=NA, p=NA))
  rt <- mean(y_t[v]); rc <- mean(y_c[v])
  if (rt == 0 && rc == 0) return(data.frame(db=db, outcome=label, n=nv, rate_trt=0, rate_ctl=0,
                                             or=NA, ci_lo=NA, ci_hi=NA, p=NA))
  fit <- tryCatch(glm(y ~ trt, data=data.frame(y=c(y_t[v], y_c[v]), trt=c(rep(1,nv), rep(0,nv))),
                       family=binomial), error=function(e) NULL)
  if (is.null(fit)) return(data.frame(db=db, outcome=label, n=nv, rate_trt=rt, rate_ctl=rc,
                                       or=NA, ci_lo=NA, ci_hi=NA, p=NA))
  ci <- exp(confint.default(fit)["trt", ]); or <- exp(coef(fit)["trt"])
  p <- summary(fit)$coefficients["trt","Pr(>|z|)"]
  data.frame(db=db, outcome=label, n=nv, rate_trt=rt, rate_ctl=rc, or=or, ci_lo=ci[1], ci_hi=ci[2], p=p)
}

# AKI outcomes (any KDIGO, stage 1+, from 24h)
aki_any_fn <- function(pid_val) {
  bl <- all_pts$first_cr[all_pts$pid == pid_val]; if (is.na(bl) || bl <= 0) return(NA)
  pt <- cr_all[cr_all$pid == pid_val & cr_all$offset_h > 24 & cr_all$offset_h <= 168, ]
  if (nrow(pt) == 0) return(0L)
  any((pt$labresult - bl) >= 0.3 | pt$labresult / bl >= 1.5, na.rm=TRUE) * 1L
}

# Mortality
mort_fn <- function(pid_val) {
  row <- all_pts[all_pts$pid == pid_val, ]
  if ("hosp_mortality" %in% names(row)) return(as.integer(row$hosp_mortality))
  if ("mortality" %in% names(row)) return(as.integer(row$mortality))
  NA
}

# F-MPAO components from streams (precompute for speed)
rbc_48h_ml <- setNames(rep(0, nrow(all_pts)), all_pts$pid)
if (!is.null(blood)) {
  rbc <- blood[blood$product == "RBC" & blood$offset_h >= 0 & blood$offset_h <= 48, ]
  if (nrow(rbc) > 0) { s <- tapply(rbc$amount, rbc$pid, sum, na.rm=TRUE); rbc_48h_ml[names(s)] <- s }
}

drain_48h <- setNames(rep(0, nrow(all_pts)), all_pts$pid)
if (!is.null(output)) {
  ct <- output[output$kind == "chesttube" & output$offset_h >= 0 & output$offset_h <= 48, ]
  if (nrow(ct) > 0) { s <- tapply(ct$amount_ml, ct$pid, sum, na.rm=TRUE); drain_48h[names(s)] <- s }
}

mv_end <- setNames(rep(0, nrow(all_pts)), all_pts$pid)
if (!is.null(vent_seg)) {
  mx <- tapply(vent_seg$t_end_h, vent_seg$pid, max, na.rm=TRUE)
  mv_end[names(mx)] <- mx
}

vaso_end <- setNames(rep(0, nrow(all_pts)), all_pts$pid)
if (!is.null(vaso) && "t_end_h" %in% names(vaso)) {
  mx <- tapply(vaso$t_end_h, vaso$pid, max, na.rm=TRUE)
  vaso_end[names(mx)] <- mx
}

# LLM endpoints
llm_lookup <- list()
if (!is.null(llm)) {
  for (col in c("return_to_or","reintubation","pneumonia_vap","sepsis",
                "sternal_wound_inf","cardiac_arrest","poaf","stroke",
                "acute_heart_failure","delirium","myocardial_injury")) {
    if (col %in% names(llm)) {
      v <- setNames(as.integer(llm[[col]]), llm$pid)
      v[v == -1] <- NA  # extraction failures
      llm_lookup[[col]] <- v
    }
  }
}

llm_fn <- function(col) {
  if (!col %in% names(llm_lookup)) return(function(pid_val) NA)
  lk <- llm_lookup[[col]]
  function(pid_val) { r <- lk[as.character(pid_val)]; if (is.null(r) || length(r)==0) NA else r }
}

# Compute all binary outcomes
results <- list()
results[[1]] <- compute_binary(function(p) compute_aki23_7d(p), "primary_aki23_rrt_7d")
results[[2]] <- compute_binary(aki_any_fn, "any_aki_24h_7d")
results[[3]] <- compute_binary(mort_fn, "hosp_mortality")

# Bleeding
results[[4]] <- compute_binary(function(p) as.integer(rbc_48h_ml[as.character(p)] >= 1200), "rbc_ge4u_48h")
results[[5]] <- compute_binary(function(p) as.integer(drain_48h[as.character(p)] > 1500), "drain_gt1500_48h")

# Prolonged support
results[[6]] <- compute_binary(function(p) as.integer(mv_end[as.character(p)] > 48), "mv_gt48h")
results[[7]] <- compute_binary(function(p) as.integer(vaso_end[as.character(p)] > 48), "vaso_gt48h")

# LLM endpoints
for (ep in c("return_to_or","reintubation","pneumonia_vap","sepsis",
             "sternal_wound_inf","cardiac_arrest","poaf","stroke",
             "acute_heart_failure","delirium","myocardial_injury")) {
  results[[length(results)+1]] <- compute_binary(llm_fn(ep), paste0("llm_", ep))
}

# F-MPAO composite
fmpao_fn <- function(pid_val) {
  p <- as.character(pid_val)
  d <- mort_fn(pid_val)
  a <- compute_aki23_7d(pid_val)
  bl <- as.integer(rbc_48h_ml[p] >= 1200 | drain_48h[p] > 1500)
  mv <- as.integer(mv_end[p] > 48)
  vs <- as.integer(vaso_end[p] > 48)
  # reoperation from LLM if available
  reop <- if ("return_to_or" %in% names(llm_lookup)) llm_lookup[["return_to_or"]][p] else 0L
  if (is.na(reop)) reop <- 0L
  vals <- c(d, a, bl, mv, vs, reop)
  if (all(is.na(vals))) return(NA)
  as.integer(any(vals == 1, na.rm=TRUE))
}
results[[length(results)+1]] <- compute_binary(fmpao_fn, "F_MPAO")

br <- do.call(rbind, results)
cat("\n  outcome              rate_trt  rate_ctl  OR (95% CI)            P\n")
for (i in 1:nrow(br)) {
  r <- br[i, ]
  if (is.na(r$or)) { cat(sprintf("  %-22s  --\n", r$outcome)); next }
  sig <- ifelse(r$p < 0.001, "***", ifelse(r$p < 0.01, "**", ifelse(r$p < 0.05, "*", "")))
  cat(sprintf("  %-22s %5.1f%%    %5.1f%%    %.2f [%.2f, %.2f]  P=%.4f %s  n=%d\n",
              r$outcome, 100*r$rate_trt, 100*r$rate_ctl, r$or, r$ci_lo, r$ci_hi, r$p, sig, r$n))
}
write.csv(br, file.path(RESULTS, sprintf("binary_results_%s.csv", tag)), row.names=FALSE)
write.csv(pairs, file.path(RESULTS, sprintf("matched_pairs_%s.csv", tag)), row.names=FALSE)

cat(sprintf("\n  DONE [%s]\n", db))
