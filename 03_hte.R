#!/usr/bin/env Rscript
# ============================================================================
# 03_hte.R — Heterogeneous Treatment Effects for Albumin -> CSA-AKI
# Adapted from mg_aki/03_hte.R (pair-preserving)
#
# Primary HTE: peri-admission albumin strata (Zhang bins)
# Secondary HTE: eGFR strata, standard subgroups
#
# Usage: Rscript 03_hte.R mimic
#        Rscript 03_hte.R eicu
# ============================================================================

suppressPackageStartupMessages({ library(sandwich); library(lmtest) })

RESULTS <- path.expand("~/albumin_aki/results")
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) { cat("Usage: Rscript 03_hte.R <db>\n"); quit(status = 1) }
tag <- tolower(args[1]); db <- toupper(tag)

SEP <- paste(rep("=", 70), collapse = "")
cat(sprintf("\n%s\n03_hte.R -- %s (Albumin -> CSA-AKI, pair-preserving)\n%s\n", SEP, db, SEP))

# ══════════════════════════════════════════════════════════════════
# LOAD DATA
# ══════════════════════════════════════════════════════════════════
all_pts <- read.csv(file.path(RESULTS, sprintf("did_all_%s.csv", tag)), stringsAsFactors = FALSE)
pairs   <- read.csv(file.path(RESULTS, sprintf("did_pairs_primary_yet_untreated_%s.csv", tag)), stringsAsFactors = FALSE)
cr_all  <- read.csv(file.path(RESULTS, sprintf("did_cr_all_%s.csv", tag)), stringsAsFactors = FALSE)

cr_id <- if ("patientunitstayid" %in% names(cr_all)) "patientunitstayid" else "stay_id"
cr_all$pid <- cr_all[[cr_id]]
if (!"offset_h" %in% names(cr_all)) cr_all$offset_h <- cr_all$labresultoffset / 60
cr_all <- cr_all[order(cr_all$pid, cr_all$offset_h), ]
cr_list <- split(cr_all[, c("labresult", "offset_h")], cr_all$pid)

trt_rows <- match(pairs$trt_pid, all_pts$pid)
ctl_rows <- match(pairs$ctl_pid, all_pts$pid)
n_pairs  <- nrow(pairs)
cat(sprintf("  Pairs: %d | Patients: %d\n", n_pairs, nrow(all_pts)))

# ══════════════════════════════════════════════════════════════════
# COMPUTE AKI OUTCOMES
# ══════════════════════════════════════════════════════════════════
compute_aki <- function(pid, t_alb) {
  cr <- cr_list[[as.character(pid)]]
  if (is.null(cr) || nrow(cr) < 1) return(c(NA, NA, NA, NA))
  pre <- cr[cr$offset_h >= 0 & cr$offset_h < t_alb, ]
  if (nrow(pre) == 0) return(c(NA, NA, NA, NA))
  bl <- pre$labresult[which.max(pre$offset_h)]
  if (is.na(bl) || bl <= 0) return(c(NA, NA, NA, NA))
  aki_48h <- 0; aki_7d <- 0; stage2 <- 0; stage3 <- 0
  post <- cr[cr$offset_h >= t_alb & cr$offset_h <= (t_alb + 168), ]
  if (nrow(post) == 0) return(c(0, 0, 0, 0))
  for (i in seq_len(nrow(post))) {
    h <- post$offset_h[i] - t_alb; val <- post$labresult[i]
    delta <- val - bl; ratio <- val / bl
    if (h <= 48 && (delta >= 0.3 || ratio >= 1.5)) { aki_7d <- 1; aki_48h <- 1 }
    if (h > 48 && ratio >= 1.5) aki_7d <- 1
    if (ratio >= 2.0) stage2 <- 1
    if (ratio >= 3.0 || val >= 4.0) stage3 <- 1
  }
  c(aki_48h, aki_7d, stage2, stage3)
}

cat("  Computing AKI outcomes...\n")
aki_trt <- aki_ctl <- matrix(NA, n_pairs, 4)
colnames(aki_trt) <- colnames(aki_ctl) <- c("aki_48h", "aki_7d", "aki_stage2", "aki_stage3")
for (i in seq_len(n_pairs)) {
  aki_trt[i, ] <- compute_aki(pairs$trt_pid[i], pairs$t_alb[i])
  aki_ctl[i, ] <- compute_aki(pairs$ctl_pid[i], pairs$t_alb[i])
}

out_trt <- list(); out_ctl <- list()
for (j in 1:4) { out_trt[[colnames(aki_trt)[j]]] <- aki_trt[,j]; out_ctl[[colnames(aki_ctl)[j]]] <- aki_ctl[,j] }
for (oc in c("hosp_mortality", "vent_arrhythmia")) {
  if (oc %in% names(all_pts)) { out_trt[[oc]] <- all_pts[[oc]][trt_rows]; out_ctl[[oc]] <- all_pts[[oc]][ctl_rows] }
}

# ══════════════════════════════════════════════════════════════════
# TREATED PATIENT COVARIATES
# ══════════════════════════════════════════════════════════════════
egfr_trt <- all_pts$egfr[trt_rows]
age_trt  <- all_pts$age[trt_rows]
female_trt <- all_pts$is_female[trt_rows]
dm_trt   <- all_pts$diabetes[trt_rows]
ckd_trt  <- all_pts$ckd[trt_rows]
hf_trt   <- all_pts$heart_failure[trt_rows]
cabg_trt <- if ("surg_cabg" %in% names(all_pts)) all_pts$surg_cabg[trt_rows] else rep(0, n_pairs)
bmi_trt  <- all_pts$bmi[trt_rows]

# Peri-admission albumin (stratification variable)
palb_trt <- all_pts$peri_admission_alb[trt_rows]
# Convert g/dL to g/L for Zhang-compatible bins
palb_gL  <- palb_trt * 10

# Albumin product (MIMIC only)
alb_prod_trt <- if ("alb_product" %in% names(all_pts)) all_pts$alb_product[trt_rows] else rep(NA, n_pairs)

# ══════════════════════════════════════════════════════════════════
# SUBGROUP DEFINITIONS
# ══════════════════════════════════════════════════════════════════
subgroups <- list(
  list(name = "Overall", idx = seq_len(n_pairs)),
  # PRIMARY HTE: Peri-admission albumin strata (Zhang bins, in g/L)
  list(name = "Alb <= 35 g/L",      idx = which(!is.na(palb_gL) & palb_gL <= 35)),
  list(name = "Alb 35.1-37.5 g/L",  idx = which(!is.na(palb_gL) & palb_gL > 35 & palb_gL <= 37.5)),
  list(name = "Alb 37.6-40 g/L",    idx = which(!is.na(palb_gL) & palb_gL > 37.5 & palb_gL <= 40)),
  list(name = "Alb > 40 g/L",       idx = which(!is.na(palb_gL) & palb_gL > 40)),
  # Binary albumin split
  list(name = "Alb <= 3.5 g/dL",    idx = which(!is.na(palb_trt) & palb_trt <= 3.5)),
  list(name = "Alb > 3.5 g/dL",     idx = which(!is.na(palb_trt) & palb_trt > 3.5)),
  # SECONDARY HTE: eGFR strata
  list(name = "eGFR >= 90",          idx = which(!is.na(egfr_trt) & egfr_trt >= 90)),
  list(name = "eGFR 60-89",          idx = which(!is.na(egfr_trt) & egfr_trt >= 60 & egfr_trt < 90)),
  list(name = "eGFR 45-59",          idx = which(!is.na(egfr_trt) & egfr_trt >= 45 & egfr_trt < 60)),
  list(name = "eGFR 30-44",          idx = which(!is.na(egfr_trt) & egfr_trt >= 30 & egfr_trt < 45)),
  list(name = "eGFR < 60",           idx = which(!is.na(egfr_trt) & egfr_trt < 60)),
  list(name = "eGFR >= 60",          idx = which(!is.na(egfr_trt) & egfr_trt >= 60)),
  # Age
  list(name = "Age < 65",            idx = which(!is.na(age_trt) & age_trt < 65)),
  list(name = "Age >= 65",           idx = which(!is.na(age_trt) & age_trt >= 65)),
  # Surgery
  list(name = "CABG",                idx = which(cabg_trt == 1)),
  list(name = "Non-CABG",            idx = which(cabg_trt == 0)),
  # Comorbidities
  list(name = "Diabetes",            idx = which(dm_trt == 1)),
  list(name = "No diabetes",         idx = which(dm_trt == 0)),
  list(name = "CKD",                 idx = which(ckd_trt == 1)),
  list(name = "No CKD",              idx = which(ckd_trt == 0)),
  list(name = "Heart failure",       idx = which(hf_trt == 1)),
  list(name = "No HF",               idx = which(hf_trt == 0)),
  list(name = "BMI >= 30",           idx = which(!is.na(bmi_trt) & bmi_trt >= 30)),
  list(name = "BMI < 30",            idx = which(!is.na(bmi_trt) & bmi_trt < 30)),
  # Albumin product (MIMIC only)
  list(name = "Albumin 5%",          idx = which(alb_prod_trt == "albumin_5pct")),
  list(name = "Albumin 25%",         idx = which(alb_prod_trt == "albumin_25pct")),
  # Crossed phenotypes
  list(name = "Low Alb + CKD",       idx = which(!is.na(palb_trt) & palb_trt <= 3.5 & ckd_trt == 1)),
  list(name = "Low Alb + HF",        idx = which(!is.na(palb_trt) & palb_trt <= 3.5 & hf_trt == 1)),
  list(name = "Normal Alb + eGFR>=90",idx = which(!is.na(palb_trt) & palb_trt > 4.0 & !is.na(egfr_trt) & egfr_trt >= 90))
)

# ══════════════════════════════════════════════════════════════════
# OR HELPER (pair-preserving, identical to mg_aki)
# ══════════════════════════════════════════════════════════════════
run_or <- function(ot, oc) {
  valid <- !is.na(ot) & !is.na(oc); ot <- ot[valid]; oc <- oc[valid]
  n <- sum(valid); et <- sum(ot); ec <- sum(oc)
  if (n < 30 || (et+ec) == 0) return(data.frame(or=NA,or_lo=NA,or_hi=NA,p=NA,rate_trt=NA,rate_ctl=NA,n=n,events_trt=et,events_ctl=ec))
  r1 <- mean(ot); r0 <- mean(oc)
  df <- data.frame(outcome=c(ot,oc), treated=rep(c(1,0),each=sum(valid)))
  fit <- tryCatch(glm(outcome~treated, data=df, family=quasibinomial()), error=function(e) NULL)
  if (is.null(fit)) return(data.frame(or=NA,or_lo=NA,or_hi=NA,p=NA,rate_trt=r1,rate_ctl=r0,n=n,events_trt=et,events_ctl=ec))
  ct <- tryCatch(coeftest(fit, vcov.=vcovHC(fit,type="HC1")), error=function(e) tryCatch(coeftest(fit), error=function(e2) NULL))
  if (is.null(ct)) return(data.frame(or=NA,or_lo=NA,or_hi=NA,p=NA,rate_trt=r1,rate_ctl=r0,n=n,events_trt=et,events_ctl=ec))
  or <- exp(ct["treated","Estimate"]); lo <- exp(ct["treated","Estimate"]-1.96*ct["treated","Std. Error"])
  hi <- exp(ct["treated","Estimate"]+1.96*ct["treated","Std. Error"]); p <- ct["treated",ncol(ct)]
  data.frame(or=round(or,4),or_lo=round(lo,4),or_hi=round(hi,4),p=round(p,6),rate_trt=round(r1,4),rate_ctl=round(r0,4),n=n,events_trt=et,events_ctl=ec)
}

# ══════════════════════════════════════════════════════════════════
# SECTION 1: SINGLE SUBGROUP ANALYSIS
# ══════════════════════════════════════════════════════════════════
cat("\n-- Section 1: Single subgroup ORs --\n")
hte_results <- list(); ridx <- 0
for (sg in subgroups) {
  idx <- sg$idx; if (length(idx) < 30) next
  for (oc in names(out_trt)) {
    res <- run_or(out_trt[[oc]][idx], out_ctl[[oc]][idx])
    res$subgroup <- sg$name; res$outcome <- oc; res$db <- db
    ridx <- ridx + 1; hte_results[[ridx]] <- res
  }
}
hte_df <- do.call(rbind, hte_results)
hte_df$sig <- !is.na(hte_df$p) & hte_df$p < 0.05

for (oc in c("aki_7d", "aki_48h", "hosp_mortality")) {
  cat(sprintf("\n  [%s]\n", oc))
  sub <- hte_df[hte_df$outcome == oc, ]
  for (i in seq_len(nrow(sub))) { r <- sub[i,]
    if (is.na(r$or)) { cat(sprintf("    %-25s  n=%d (skip)\n", r$subgroup, r$n)); next }
    sig <- if (r$sig) " *" else "  "
    cat(sprintf("    %-25s  OR=%.3f [%.3f,%.3f]  P=%.4f%s  %.1f%% vs %.1f%%  n=%d\n",
                r$subgroup, r$or, r$or_lo, r$or_hi, r$p, sig, 100*r$rate_trt, 100*r$rate_ctl, r$n))
  }
}
write.csv(hte_df, file.path(RESULTS, sprintf("did_hte_%s.csv", tag)), row.names=FALSE)

# ══════════════════════════════════════════════════════════════════
# SECTION 2: INTERACTION TESTS
# ══════════════════════════════════════════════════════════════════
cat("\n-- Section 2: Interaction tests --\n")

# Albumin as continuous interaction (primary)
alb_continuous <- palb_trt  # g/dL
# Albumin binary (>40 g/L = >4.0 g/dL)
alb_high <- as.integer(!is.na(palb_trt) & palb_trt > 4.0)

interact_vars <- list(
  "Alb > 4.0 g/dL" = alb_high,
  "Alb (continuous)" = palb_trt,
  "eGFR < 60"       = as.integer(!is.na(egfr_trt) & egfr_trt < 60),
  "Age >= 65"        = as.integer(!is.na(age_trt) & age_trt >= 65),
  "CABG"             = as.integer(cabg_trt == 1),
  "Diabetes"         = as.integer(dm_trt == 1),
  "CKD"              = as.integer(ckd_trt == 1),
  "Heart failure"    = as.integer(hf_trt == 1),
  "BMI >= 30"        = as.integer(!is.na(bmi_trt) & bmi_trt >= 30)
)

interact_results <- list(); iidx <- 0
for (iv_name in names(interact_vars)) {
  sg_val <- interact_vars[[iv_name]]
  for (oc in c("aki_7d", "aki_48h", "hosp_mortality")) {
    if (!(oc %in% names(out_trt))) next
    ot <- out_trt[[oc]]; oc_val <- out_ctl[[oc]]
    valid <- !is.na(ot) & !is.na(oc_val) & !is.na(sg_val); n_valid <- sum(valid)
    if (n_valid < 50) next
    idf <- data.frame(outcome=c(ot[valid],oc_val[valid]), treated=rep(c(1,0),each=n_valid), sg=rep(sg_val[valid],2))
    fit <- tryCatch(glm(outcome~treated*sg, data=idf, family=quasibinomial()), error=function(e) NULL)
    if (is.null(fit)) next
    ct <- tryCatch(coeftest(fit, vcov.=vcovHC(fit,type="HC1")), error=function(e) tryCatch(coeftest(fit), error=function(e2) NULL))
    if (is.null(ct) || !("treated:sg" %in% rownames(ct))) next
    p_interact <- ct["treated:sg", ncol(ct)]
    iidx <- iidx + 1
    interact_results[[iidx]] <- data.frame(variable=iv_name, outcome=oc, p_interaction=round(p_interact,4), sig=p_interact<0.05, db=db)
  }
}
if (iidx > 0) {
  interact_df <- do.call(rbind, interact_results)
  cat(sprintf("\n  %-20s  %-12s  %10s\n", "Variable", "Outcome", "P_interact"))
  for (i in seq_len(nrow(interact_df))) { r <- interact_df[i,]
    sig <- if (r$sig) " *" else "  "
    cat(sprintf("  %-20s  %-12s  %10.4f%s\n", r$variable, r$outcome, r$p_interaction, sig))
  }
  write.csv(interact_df, file.path(RESULTS, sprintf("did_hte_interact_%s.csv", tag)), row.names=FALSE)
}

cat(sprintf("\n%s\n03_hte.R -- %s DONE\n%s\n", SEP, db, SEP))
