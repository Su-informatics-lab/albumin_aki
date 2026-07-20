# Frozen-v3.3 MIMIC HTE sweep helpers.
# Patient-level inputs are read only on Tempest. Every file written here is aggregate.

hte_read <- function(results, name) {
  path <- file.path(results, name)
  if (!file.exists(path)) stop("HTE input missing: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}

hte_rbind_fill <- function(rows) {
  if (!length(rows)) return(data.frame())
  cols <- unique(unlist(lapply(rows, names)))
  rows <- lapply(rows, function(x) {
    for (nm in setdiff(cols, names(x))) x[[nm]] <- NA
    x[, cols, drop = FALSE]
  })
  do.call(rbind, rows)
}

hte_wald <- function(fit, pattern) {
  if (is.null(fit)) return(c(stat = NA, df = NA, p = NA))
  b <- coef(fit)
  keep <- grep(pattern, names(b))
  keep <- keep[is.finite(b[keep])]
  if (!length(keep)) return(c(stat = NA, df = NA, p = NA))
  v <- tryCatch(sandwich::vcovHC(fit, type = "HC1"), error = function(e) NULL)
  if (is.null(v)) return(c(stat = NA, df = NA, p = NA))
  vv <- v[keep, keep, drop = FALSE]
  bb <- b[keep]
  inv <- tryCatch(solve(vv), error = function(e) tryCatch(qr.solve(vv), error = function(e2) NULL))
  if (is.null(inv)) return(c(stat = NA, df = length(keep), p = NA))
  stat <- as.numeric(t(bb) %*% inv %*% bb)
  c(stat = stat, df = length(keep), p = pchisq(stat, length(keep), lower.tail = FALSE))
}

hte_terms <- function(fit, pattern, scale) {
  if (is.null(fit)) return(data.frame())
  ct <- safe_hc1(fit)
  if (is.null(ct)) return(data.frame())
  keep <- grep(pattern, rownames(ct))
  if (!length(keep)) return(data.frame())
  est <- ct[keep, 1]
  se <- ct[keep, 2]
  if (scale == "OR") {
    out_est <- exp(est)
    lo <- exp(est - 1.96 * se)
    hi <- exp(est + 1.96 * se)
  } else {
    out_est <- est
    lo <- est - 1.96 * se
    hi <- est + 1.96 * se
  }
  data.frame(
    term = rownames(ct)[keep], estimate = out_est, ci_lo = lo, ci_hi = hi,
    p_term = ct[keep, ncol(ct)], stringsAsFactors = FALSE
  )
}

hte_qfactor <- function(x) {
  ok <- is.finite(x)
  out <- rep(NA_character_, length(x))
  if (sum(ok) < 8 || length(unique(x[ok])) < 2) return(factor(out))
  br <- unique(as.numeric(quantile(x[ok], seq(0, 1, .25), na.rm = TRUE, type = 2)))
  if (length(br) < 3) return(factor(out))
  out[ok] <- as.character(cut(x[ok], breaks = br, include.lowest = TRUE,
                             labels = paste0("Q", seq_len(length(br) - 1))))
  factor(out, levels = paste0("Q", seq_len(length(br) - 1)))
}

hte_cell_counts <- function(y_t, y_c, x, continuous = FALSE) {
  cell <- if (continuous) hte_qfactor(as.numeric(x)) else addNA(factor(x), ifany = TRUE)
  rows <- list()
  for (lev in levels(cell)) {
    idx <- !is.na(cell) & cell == lev & !is.na(y_t) & !is.na(y_c)
    if (!any(idx)) next
    rows[[length(rows) + 1L]] <- data.frame(
      level = lev, n_pairs = sum(idx), events_trt = sum(y_t[idx]),
      events_ctl = sum(y_c[idx]), stringsAsFactors = FALSE
    )
  }
  tab <- if (length(rows)) do.call(rbind, rows) else data.frame()
  min_ev <- if (nrow(tab)) min(c(tab$events_trt, tab$events_ctl)) else NA_real_
  list(table = tab, min_events = min_ev,
       sparse = is.na(min_ev) || min_ev < 20)
}

hte_fit_interaction <- function(y_t, y_c, x, representation) {
  valid <- !is.na(y_t) & !is.na(y_c) & !is.na(x)
  if (representation == "quartile") {
    x_model <- hte_qfactor(as.numeric(x))
    valid <- valid & !is.na(x_model)
  } else if (representation == "factor") {
    x_model <- factor(x)
  } else {
    x_model <- as.numeric(x)
  }
  n <- sum(valid)
  empty <- list(or_fit = NULL, rd_fit = NULL, n = n)
  if (n < 50 || length(unique(x_model[valid])) < 2 ||
      sum(y_t[valid]) + sum(y_c[valid]) < 5) return(empty)
  dat <- data.frame(
    outcome = c(y_t[valid], y_c[valid]),
    treated = rep(c(1L, 0L), each = n),
    modifier = rep(x_model[valid], 2)
  )
  form <- outcome ~ treated * modifier
  list(
    or_fit = tryCatch(glm(form, data = dat, family = quasibinomial()), error = function(e) NULL),
    rd_fit = tryCatch(lm(form, data = dat), error = function(e) NULL), n = n
  )
}

hte_build_modifiers <- function(all_pts, pairs, results) {
  tr <- match(pairs$trt_pid, all_pts$pid)
  if (anyNA(tr)) stop("Treated pair IDs do not map to did_all")
  labs <- hte_read(results, "did_labs_all_mimic.csv")
  lab_id <- if ("patientunitstayid" %in% names(labs)) "patientunitstayid" else "stay_id"
  labs$pid <- labs[[lab_id]]
  index <- data.frame(pid = pairs$trt_pid, index_h = pairs$t0)
  latest <- function(lab) {
    z <- last_value_before_index(labs, index, lab_name = lab)
    as.numeric(z[as.character(pairs$trt_pid)])
  }
  albumin <- latest("albumin")
  lactate <- latest("lactate")
  hemoglobin <- latest("hemoglobin")
  heartrate <- latest("heartrate")
  surg <- hte_read(results, "surg_mimic.csv")
  aortic <- as.integer(surg$surg_aortic[match(pairs$trt_pid, surg$pid)])
  aortic[is.na(aortic)] <- 0L
  vaso <- hte_read(results, "strm_vaso_mimic.csv")
  vent <- hte_read(results, "strm_vent_mimic.csv")
  map_stream <- hte_read(results, "strm_map_mimic.csv")
  map_named <- last_value_before_index(
    transform(map_stream, value = map), index, value_col = "value"
  )
  data.frame(
    egfr = all_pts$egfr[tr] / 30,
    baseline_cr = pairs$baseline_trt,
    age = all_pts$age[tr] / 10,
    hemoglobin = hemoglobin,
    lactate = lactate,
    map = as.numeric(map_named[as.character(pairs$trt_pid)]) / 10,
    alb_cat = factor(ifelse(is.na(albumin), "missing",
                            ifelse(albumin < 3.5, "low", "normal")),
                     levels = c("normal", "low", "missing")),
    heart_failure = factor(all_pts$heart_failure[tr]),
    diabetes = factor(all_pts$diabetes[tr]),
    hypertension = factor(all_pts$hypertension[tr]),
    ckd = factor(all_pts$ckd[tr]),
    surg_cabg = factor(all_pts$surg_cabg[tr]),
    surg_valve = factor(all_pts$surg_valve[tr]),
    surg_combined = factor(all_pts$surg_combined[tr]),
    surg_aortic = factor(aortic),
    vaso_at_t0 = factor(state_at_index(vaso, index)[as.character(pairs$trt_pid)]),
    vent_at_t0 = factor(state_at_index(vent, index)[as.character(pairs$trt_pid)]),
    sex = factor(all_pts$is_female[tr]),
    heartrate = heartrate,
    stringsAsFactors = FALSE
  )
}

hte_scan_registry <- function() {
  continuous <- c("egfr", "baseline_cr", "age", "hemoglobin", "lactate", "map")
  categorical <- c(
    "alb_cat", "heart_failure", "diabetes", "hypertension", "ckd",
    "surg_cabg", "surg_valve", "surg_combined", "surg_aortic",
    "vaso_at_t0", "vent_at_t0", "sex"
  )
  rbind(
    data.frame(modifier = continuous, representation = "linear"),
    data.frame(modifier = continuous, representation = "quartile"),
    data.frame(modifier = categorical, representation = "factor")
  )
}

hte_step1 <- function(pairs, modifiers) {
  outcomes <- c("aki1_48h", "aki1_7d", "aki2_48h", "aki2_7d")
  reg <- hte_scan_registry()
  tests <- list()
  terms <- list()
  cells <- list()
  for (outcome in outcomes) {
    yt <- pairs[[paste0(outcome, "_trt")]]
    yc <- pairs[[paste0(outcome, "_ctl")]]
    for (j in seq_len(nrow(reg))) {
      m <- reg$modifier[j]
      repn <- reg$representation[j]
      x <- modifiers[[m]]
      sparse <- hte_cell_counts(yt, yc, x, continuous = repn != "factor")
      if (nrow(sparse$table)) {
        cells[[length(cells) + 1L]] <- cbind(
          data.frame(outcome = outcome, modifier = m, representation = repn),
          sparse$table
        )
      }
      fit <- hte_fit_interaction(yt, yc, x, repn)
      wo <- hte_wald(fit$or_fit, "(^treated:modifier|^modifier.*:treated)")
      wr <- hte_wald(fit$rd_fit, "(^treated:modifier|^modifier.*:treated)")
      test_id <- paste(outcome, m, repn, sep = "__")
      tests[[length(tests) + 1L]] <- data.frame(
        test_id = test_id, outcome = outcome, modifier = m,
        representation = repn, n_pairs = fit$n,
        min_events_cell = sparse$min_events, sparse_lt20 = sparse$sparse,
        or_global_p = wo["p"], rd_global_p = wr["p"],
        stringsAsFactors = FALSE
      )
      for (scale in c("OR", "RD")) {
        f <- if (scale == "OR") fit$or_fit else fit$rd_fit
        d <- hte_terms(f, "(^treated:modifier|^modifier.*:treated)", scale)
        if (!nrow(d)) d <- data.frame(term = NA, estimate = NA, ci_lo = NA,
                                      ci_hi = NA, p_term = NA)
        d$test_id <- test_id
        d$scale <- scale
        terms[[length(terms) + 1L]] <- d
      }
    }
  }
  tests <- do.call(rbind, tests)
  for (outcome in outcomes) {
    idx <- tests$outcome == outcome
    tests$or_q[idx] <- p.adjust(tests$or_global_p[idx], method = "BH")
    tests$rd_q[idx] <- p.adjust(tests$rd_global_p[idx], method = "BH")
  }
  terms <- do.call(rbind, terms)
  terms <- merge(terms, tests, by = "test_id", all.x = TRUE)
  terms$global_p <- ifelse(terms$scale == "OR", terms$or_global_p, terms$rd_global_p)
  terms$q <- ifelse(terms$scale == "OR", terms$or_q, terms$rd_q)
  list(tests = tests, terms = terms,
       cells = if (length(cells)) do.call(rbind, cells) else data.frame())
}

hte_model_variable <- function(x, modifier) {
  if (modifier %in% c("egfr", "baseline_cr", "age", "hemoglobin", "lactate", "map")) {
    as.numeric(x)
  } else factor(x)
}

hte_step2 <- function(pairs, modifiers, step1) {
  primary <- step1$tests$outcome %in% c("aki1_48h", "aki1_7d")
  pass <- primary & !step1$tests$sparse_lt20 &
    ((is.finite(step1$tests$or_q) & step1$tests$or_q < .05) |
       (is.finite(step1$tests$rd_q) & step1$tests$rd_q < .05))
  survivor <- setdiff(unique(step1$tests$modifier[pass]), "egfr")
  candidates <- unique(c("alb_cat", "baseline_cr", survivor))
  outcomes <- c("aki1_48h", "aki1_7d", "aki2_48h", "aki2_7d")
  models <- list()
  grids <- list()
  for (outcome in outcomes) {
    yt <- pairs[[paste0(outcome, "_trt")]]
    yc <- pairs[[paste0(outcome, "_ctl")]]
    for (m in candidates) {
      eg <- modifiers$egfr
      mv <- hte_model_variable(modifiers[[m]], m)
      valid <- !is.na(yt) & !is.na(yc) & !is.na(eg) & !is.na(mv)
      n <- sum(valid)
      if (n >= 50 && length(unique(mv[valid])) > 1) {
        dat <- data.frame(
          outcome = c(yt[valid], yc[valid]),
          treated = rep(c(1L, 0L), each = n),
          egfr30 = rep(eg[valid], 2), modifier = rep(mv[valid], 2)
        )
        fits <- list(
          threeway_or = tryCatch(glm(outcome ~ treated * egfr30 * modifier,
                                     data = dat, family = quasibinomial()), error = function(e) NULL),
          threeway_rd = tryCatch(lm(outcome ~ treated * egfr30 * modifier, data = dat),
                                 error = function(e) NULL),
          competing_or = tryCatch(glm(outcome ~ treated * egfr30 + treated * modifier,
                                      data = dat, family = quasibinomial()), error = function(e) NULL),
          competing_rd = tryCatch(lm(outcome ~ treated * egfr30 + treated * modifier, data = dat),
                                  error = function(e) NULL)
        )
        for (scale in c("OR", "RD")) {
          f3 <- fits[[paste0("threeway_", tolower(scale))]]
          fc <- fits[[paste0("competing_", tolower(scale))]]
          for (target in c("three_way", "egfr_competing", "modifier_competing")) {
            f <- if (target == "three_way") f3 else fc
            pat <- switch(target,
              three_way = "(treated:egfr30:modifier|treated:modifier.*:egfr30|egfr30:modifier.*:treated)",
              egfr_competing = "(^treated:egfr30$|^egfr30:treated$)",
              modifier_competing = "(^treated:modifier|^modifier.*:treated)"
            )
            w <- hte_wald(f, pat)
            d <- hte_terms(f, pat, scale)
            if (!nrow(d)) d <- data.frame(term = NA, estimate = NA, ci_lo = NA,
                                          ci_hi = NA, p_term = NA)
            models[[length(models) + 1L]] <- cbind(
              data.frame(outcome = outcome, modifier = m, target = target,
                         scale = scale, n_pairs = n, global_p = w["p"]),
              d
            )
          }
        }
      }
      grid_m <- if (is.numeric(mv)) hte_qfactor(mv) else factor(mv)
      gs <- egfr_stratum(eg * 30)
      for (g in levels(gs)) for (lev in levels(grid_m)) {
        idx <- !is.na(gs) & gs == g & !is.na(grid_m) & grid_m == lev &
          !is.na(yt) & !is.na(yc)
        if (!any(idx)) next
        est <- pair_or_rd(yt[idx], yc[idx])
        grids[[length(grids) + 1L]] <- cbind(
          data.frame(outcome = outcome, modifier = m, egfr_stratum = g,
                     modifier_level = lev, events_trt = sum(yt[idx]),
                     events_ctl = sum(yc[idx]),
                     sparse_lt20 = min(sum(yt[idx]), sum(yc[idx])) < 20),
          est
        )
      }
    }
  }
  models <- if (length(models)) do.call(rbind, models) else data.frame()
  if (nrow(models)) {
    for (outcome in outcomes) for (scale in c("OR", "RD")) for (target in unique(models$target)) {
      idx <- models$outcome == outcome & models$scale == scale & models$target == target
      key <- !duplicated(models$modifier[idx])
      q <- p.adjust(models$global_p[idx][key], "BH")
      qmap <- setNames(q, models$modifier[idx][key])
      models$q <- models$q %||% NA_real_
      models$q[idx] <- qmap[models$modifier[idx]]
    }
  }
  list(models = models,
       grid = if (length(grids)) do.call(rbind, grids) else data.frame(),
       candidates = data.frame(modifier = candidates,
                               source = ifelse(candidates %in% c("alb_cat", "baseline_cr"),
                                               "pre_registered", "step1_statistical_survivor")))
}

`%||%` <- function(x, y) if (is.null(x)) y else x

hte_prepare_forest <- function(all_pts, pairs, modifiers, results) {
  tr <- match(pairs$trt_pid, all_pts$pid)
  x <- data.frame(
    age = all_pts$age[tr], is_female = factor(all_pts$is_female[tr]),
    bmi = all_pts$bmi[tr], surg_cabg = factor(all_pts$surg_cabg[tr]),
    surg_valve = factor(all_pts$surg_valve[tr]),
    surg_combined = factor(all_pts$surg_combined[tr]),
    surg_aortic = modifiers$surg_aortic,
    heart_failure = factor(all_pts$heart_failure[tr]),
    hypertension = factor(all_pts$hypertension[tr]),
    diabetes = factor(all_pts$diabetes[tr]), copd = factor(all_pts$copd[tr]),
    pvd = factor(all_pts$pvd[tr]), stroke = factor(all_pts$stroke[tr]),
    liver_disease = factor(all_pts$liver_disease[tr]),
    egfr = modifiers$egfr * 30, baseline_cr = modifiers$baseline_cr,
    lactate = modifiers$lactate, hemoglobin = modifiers$hemoglobin,
    heartrate = modifiers$heartrate, alb_cat = modifiers$alb_cat,
    vaso_at_t0 = modifiers$vaso_at_t0, map = modifiers$map * 10,
    vent_at_t0 = modifiers$vent_at_t0
  )
  for (nm in names(x)) {
    if (is.numeric(x[[nm]])) {
      miss <- !is.finite(x[[nm]])
      x[[paste0(nm, "_missing")]] <- as.integer(miss)
      x[[nm]][miss] <- median(x[[nm]][!miss], na.rm = TRUE)
    } else {
      z <- as.character(x[[nm]])
      z[is.na(z) | z == ""] <- "Missing"
      x[[nm]] <- factor(z)
    }
  }
  x
}

hte_patient_folds <- function(pairs, nfold = 5L) {
  trt <- as.character(pairs$trt_pid)
  ctl <- as.character(pairs$ctl_pid)
  ids <- unique(c(trt, ctl))
  parent <- seq_along(ids)
  names(parent) <- ids
  find_root <- function(i) {
    while (parent[i] != i) {
      parent[i] <<- parent[parent[i]]
      i <- parent[i]
    }
    i
  }
  union_ids <- function(a, b) {
    ra <- find_root(unname(parent[a]))
    rb <- find_root(unname(parent[b]))
    if (ra != rb) parent[rb] <<- ra
  }
  for (i in seq_along(trt)) union_ids(trt[i], ctl[i])
  roots <- vapply(seq_along(ids), find_root, integer(1))
  names(roots) <- ids
  edge_root <- roots[trt]
  component_sizes <- sort(table(edge_root), decreasing = TRUE)
  n_components <- length(component_sizes)
  largest <- if (n_components) max(component_sizes) else 0
  largest_fraction <- if (nrow(pairs)) largest / nrow(pairs) else NA_real_
  feasible <- n_components >= nfold && largest_fraction <= .50
  status <- if (feasible) "patient_disjoint_5fold" else
    "demoted_giant_or_too_few_components"
  edge_fold <- rep(NA_integer_, nrow(pairs))
  if (feasible) {
    loads <- integer(nfold)
    component_fold <- setNames(integer(n_components), names(component_sizes))
    for (component in names(component_sizes)) {
      chosen <- which.min(loads)
      component_fold[component] <- chosen
      loads[chosen] <- loads[chosen] + component_sizes[component]
    }
    edge_fold <- unname(component_fold[as.character(edge_root)])
    ctl_root <- roots[ctl]
    if (any(edge_root != ctl_root)) {
      stop("Patient-disjoint fold construction split a matched edge")
    }
  }
  list(
    fold = edge_fold,
    status = status,
    n_components = n_components,
    largest_component_pairs = largest,
    largest_component_fraction = largest_fraction,
    fold_pair_counts = if (feasible) tabulate(edge_fold, nbins = nfold) else
      integer(nfold)
  )
}

hte_forest <- function(all_pts, pairs, modifiers, results) {
  if (!requireNamespace("ranger", quietly = TRUE)) {
    return(list(omnibus = data.frame(status = "ranger_unavailable"),
                importance = data.frame(), pdp = data.frame(),
                fold_audit = data.frame(status = "ranger_unavailable")))
  }
  x <- hte_prepare_forest(all_pts, pairs, modifiers, results)
  fold_info <- hte_patient_folds(pairs)
  outcomes <- c("aki1_48h", "aki1_7d")
  omnibus <- importance <- pdp <- fold_audit <- list()
  for (oi in seq_along(outcomes)) {
    outcome <- outcomes[oi]
    d <- pairs[[paste0(outcome, "_trt")]] - pairs[[paste0(outcome, "_ctl")]]
    valid <- !is.na(d)
    xv <- x[valid, , drop = FALSE]
    dv <- d[valid]
    n <- length(dv)
    fold <- fold_info$fold[valid]
    fold_counts <- if (all(is.finite(fold))) tabulate(fold, nbins = 5) else
      integer(5)
    crossfit_ok <- fold_info$status == "patient_disjoint_5fold" &&
      all(fold_counts > 0)
    fold_audit[[length(fold_audit) + 1L]] <- data.frame(
      outcome = outcome, n_pairs = n, status = if (crossfit_ok)
        "patient_disjoint_5fold" else "descriptive_only",
      n_components = fold_info$n_components,
      largest_component_pairs = fold_info$largest_component_pairs,
      largest_component_fraction = fold_info$largest_component_fraction,
      fold1_pairs = fold_counts[1], fold2_pairs = fold_counts[2],
      fold3_pairs = fold_counts[3], fold4_pairs = fold_counts[4],
      fold5_pairs = fold_counts[5], patient_overlap_across_folds = 0L
    )
    if (crossfit_ok) {
      pred <- rep(NA_real_, n)
      for (k in 1:5) {
        train <- fold != k
        dat <- cbind(data.frame(effect = dv[train]), xv[train, , drop = FALSE])
        fit <- ranger::ranger(
          effect ~ ., data = dat, num.trees = 1000,
          min.node.size = 20, seed = 2026 + oi * 10 + k
        )
        pred[!train] <- predict(
          fit, data = xv[!train, , drop = FALSE
        ])$predictions
      }
      cal <- lm(dv ~ I(pred - mean(pred)))
      ct <- safe_hc1(cal)
      omnibus[[length(omnibus) + 1L]] <- data.frame(
        outcome = outcome,
        method = "5-fold patient-disjoint pair-difference R-forest",
        status = "patient_disjoint_5fold", n_pairs = n,
        calibration_slope = ct[2, 1],
        ci_lo = ct[2, 1] - 1.96 * ct[2, 2],
        ci_hi = ct[2, 1] + 1.96 * ct[2, 2],
        p_heterogeneity = ct[2, ncol(ct)]
      )
    } else {
      omnibus[[length(omnibus) + 1L]] <- data.frame(
        outcome = outcome,
        method = "descriptive pair-difference forest; no honest cross-fit",
        status = "demoted_descriptive_only", n_pairs = n,
        calibration_slope = NA_real_, ci_lo = NA_real_, ci_hi = NA_real_,
        p_heterogeneity = NA_real_
      )
    }
    final_dat <- cbind(data.frame(effect = dv), xv)
    final <- ranger::ranger(effect ~ ., data = final_dat, num.trees = 2000,
                            min.node.size = 20, importance = "permutation",
                            seed = 2026 + oi)
    vi <- sort(final$variable.importance, decreasing = TRUE)
    importance[[length(importance) + 1L]] <- data.frame(
      outcome = outcome, variable = names(vi), importance = as.numeric(vi),
      rank = seq_along(vi)
    )
    base_names <- names(xv)[!grepl("_missing$", names(xv))]
    vi_base <- vi[names(vi) %in% base_names]
    selected <- unique(c("egfr", head(setdiff(names(vi_base), "egfr"), 2)))
    for (v in selected) {
      if (is.numeric(xv[[v]])) {
        grid <- unique(as.numeric(quantile(xv[[v]], seq(.1, .9, .2), type = 2)))
      } else grid <- levels(xv[[v]])
      for (value in grid) {
        newx <- xv
        if (is.numeric(newx[[v]])) newx[[v]] <- as.numeric(value) else
          newx[[v]] <- factor(as.character(value), levels = levels(newx[[v]]))
        pr <- predict(final, data = newx)$predictions
        pdp[[length(pdp) + 1L]] <- data.frame(
          outcome = outcome, variable = v, value = as.character(value),
          mean_cate_rd = mean(pr), empirical_se = sd(pr) / sqrt(length(pr)),
          n_pairs = n
        )
      }
    }
  }
  list(omnibus = do.call(rbind, omnibus), importance = do.call(rbind, importance),
       pdp = do.call(rbind, pdp), fold_audit = do.call(rbind, fold_audit))
}

hte_treated_mechanism <- function(all_pts, pairs, modifiers) {
  tr <- match(pairs$trt_pid, all_pts$pid)
  product <- factor(all_pts$alb_product[tr],
                    levels = c("albumin_5pct", "albumin_25pct"))
  concentration <- ifelse(product == "albumin_5pct", .05,
                          ifelse(product == "albumin_25pct", .25, NA))
  dose_g <- all_pts$alb_total_ml_24h[tr] * concentration
  outcomes <- c("aki1_48h", "aki1_7d", "aki2_48h", "aki2_7d")
  rows <- list()
  for (outcome in outcomes) {
    y <- pairs[[paste0(outcome, "_trt")]]
    for (spec in c("product_25_vs_5", "dose_per_25g", "product_x_egfr", "dose_x_egfr")) {
      x <- if (grepl("product", spec)) product else dose_g / 25
      valid <- !is.na(y) & !is.na(x) & !is.na(modifiers$egfr)
      dat <- data.frame(y = y[valid], x = x[valid], egfr30 = modifiers$egfr[valid])
      form <- if (grepl("_x_", spec)) y ~ x * egfr30 else y ~ x
      for (scale in c("OR", "RD")) {
        fit <- if (scale == "OR") tryCatch(glm(form, data = dat, family = quasibinomial()),
                                           error = function(e) NULL) else
          tryCatch(lm(form, data = dat), error = function(e) NULL)
        pat <- if (grepl("_x_", spec)) "(x.*:egfr30|egfr30:x)" else "^x"
        w <- hte_wald(fit, pat)
        d <- hte_terms(fit, pat, scale)
        if (!nrow(d)) d <- data.frame(term = NA, estimate = NA, ci_lo = NA,
                                      ci_hi = NA, p_term = NA)
        rows[[length(rows) + 1L]] <- cbind(
          data.frame(outcome = outcome, spec = spec, scale = scale,
                     n_treated = nrow(dat), events = sum(dat$y), global_p = w["p"],
                     dose_note = "grams approximated from first product concentration x total 24h mL; mixed-product courses may be misclassified"),
          d
        )
      }
    }
  }
  do.call(rbind, rows)
}

hte_egfr_interaction <- function(yt, yc, egfr) {
  valid <- !is.na(yt) & !is.na(yc) & !is.na(egfr)
  n <- sum(valid)
  dat <- data.frame(y = c(yt[valid], yc[valid]),
                    treated = rep(c(1L, 0L), each = n),
                    egfr30 = rep(egfr[valid], 2))
  rows <- list()
  for (scale in c("OR", "RD")) {
    fit <- if (scale == "OR") glm(y ~ treated * egfr30, data = dat, family = quasibinomial()) else
      lm(y ~ treated * egfr30, data = dat)
    d <- hte_terms(fit, "(treated:egfr30|egfr30:treated)", scale)
    rows[[length(rows) + 1L]] <- cbind(data.frame(scale = scale, n_pairs = n), d)
  }
  do.call(rbind, rows)
}

hte_probe_never <- function(all_pts, pairs, modifiers) {
  ctl <- match(pairs$ctl_pid, all_pts$pid)
  never <- is.na(all_pts$alb_offset_h[ctl])
  outcomes <- c("aki1_48h", "aki1_7d", "aki2_48h", "aki2_7d",
                "death_48h_all", "death_7d_all")
  rows <- list()
  for (outcome in outcomes) {
    yt <- pairs[[paste0(outcome, "_trt")]]
    yc <- pairs[[paste0(outcome, "_ctl")]]
    est <- pair_or_rd(yt[never], yc[never])
    int <- hte_egfr_interaction(yt[never], yc[never], modifiers$egfr[never])
    rows[[length(rows) + 1L]] <- cbind(
      data.frame(outcome = outcome, analysis = "never_treated_controls", component = "effect"),
      est
    )
    rows[[length(rows) + 1L]] <- cbind(
      data.frame(outcome = outcome, analysis = "never_treated_controls", component = "egfr_interaction"),
      int
    )
  }
  hte_rbind_fill(rows)
}

hte_first_aki_h <- function(cr, baseline, t0, horizon) {
  if (is.null(cr) || !nrow(cr) || !is.finite(baseline) || baseline <= 0) return(NA_real_)
  z <- cr[cr$offset_h > t0 & cr$offset_h <= t0 + horizon, , drop = FALSE]
  if (!nrow(z)) return(NA_real_)
  rel <- z$offset_h - t0
  hit <- (z$labresult - baseline >= .3 & rel <= 48) | z$labresult / baseline >= 1.5
  if (!any(hit)) NA_real_ else min(z$offset_h[hit] - t0)
}

hte_probe_competing <- function(all_pts, pairs, modifiers, results) {
  cr <- hte_read(results, "did_cr_all_mimic.csv")
  id <- if ("patientunitstayid" %in% names(cr)) "patientunitstayid" else "stay_id"
  cr$pid <- cr[[id]]
  cr <- cr[order(cr$pid, cr$offset_h, -cr$labresult), ]
  crl <- split(cr[, c("labresult", "offset_h")], cr$pid)
  death <- setNames(all_pts$death_offset_h, all_pts$pid)
  rows <- list()
  for (h in c(48, 168)) {
    suffix <- if (h == 48) "48h" else "7d"
    aki_t <- aki_c <- rep(NA_real_, nrow(pairs))
    for (i in seq_len(nrow(pairs))) {
      aki_t[i] <- hte_first_aki_h(crl[[as.character(pairs$trt_pid[i])]],
                                  pairs$baseline_trt[i], pairs$t0[i], h)
      aki_c[i] <- hte_first_aki_h(crl[[as.character(pairs$ctl_pid[i])]],
                                  pairs$baseline_ctl[i], pairs$t0[i], h)
    }
    dt <- as.numeric(death[as.character(pairs$trt_pid)]) - pairs$t0
    dc <- as.numeric(death[as.character(pairs$ctl_pid)]) - pairs$t0
    dbt <- is.finite(dt) & dt > 0 & dt <= h & (is.na(aki_t) | dt < aki_t)
    dbc <- is.finite(dc) & dc > 0 & dc <= h & (is.na(aki_c) | dc < aki_c)
    yt <- pairs[[paste0("aki1_", suffix, "_trt")]]
    yc <- pairs[[paste0("aki1_", suffix, "_ctl")]]
    for (analysis in c("aki_original", "aki_or_death", "death_censored_pairs")) {
      if (analysis == "aki_original") {
        a <- yt; b <- yc; keep <- rep(TRUE, length(yt))
      } else if (analysis == "aki_or_death") {
        a <- as.integer(yt == 1 | dbt); b <- as.integer(yc == 1 | dbc)
        keep <- !is.na(yt) & !is.na(yc)
      } else {
        a <- yt; b <- yc; keep <- !dbt & !dbc
      }
      est <- pair_or_rd(a[keep], b[keep])
      int <- hte_egfr_interaction(a[keep], b[keep], modifiers$egfr[keep])
      rows[[length(rows) + 1L]] <- cbind(
        data.frame(horizon = suffix, analysis = analysis, component = "effect",
                   death_before_aki_trt = sum(dbt), death_before_aki_ctl = sum(dbc)),
        est
      )
      rows[[length(rows) + 1L]] <- cbind(
        data.frame(horizon = suffix, analysis = analysis,
                   component = "egfr_interaction",
                   death_before_aki_trt = sum(dbt), death_before_aki_ctl = sum(dbc)),
        int
      )
    }
  }
  hte_rbind_fill(rows)
}

hte_probe_crossover <- function(all_pts, pairs) {
  ctl <- match(pairs$ctl_pid, all_pts$pid)
  offset <- all_pts$alb_offset_h[ctl] - pairs$t0
  group <- ifelse(is.na(offset), "never",
                  ifelse(offset <= 48, "cross_0_48h",
                         ifelse(offset <= 168, "cross_48h_7d", "cross_after_7d")))
  rows <- list()
  for (g in unique(group)) for (outcome in c("death_48h_all", "death_7d_all",
                                             "aki1_48h", "aki1_7d")) {
    idx <- group == g
    yt <- pairs[[paste0(outcome, "_trt")]]
    yc <- pairs[[paste0(outcome, "_ctl")]]
    rows[[length(rows) + 1L]] <- data.frame(
      crossover_group = g, outcome = outcome, n_pairs = sum(idx),
      events_trt = sum(yt[idx], na.rm = TRUE), events_ctl = sum(yc[idx], na.rm = TRUE),
      rate_trt = mean(yt[idx], na.rm = TRUE), rate_ctl = mean(yc[idx], na.rm = TRUE)
    )
  }
  hte_rbind_fill(rows)
}

hte_horizon_keep <- function(pairs, horizon_h) {
  suffix <- if (horizon_h == 48) "48h" else if (horizon_h == 168) "7d" else
    stop("Unsupported frozen horizon: ", horizon_h)
  !is.na(pairs[[paste0("aki1_", suffix, "_trt")]]) &
    !is.na(pairs[[paste0("aki1_", suffix, "_ctl")]])
}

hte_probe_kdigo <- function(all_pts, pairs, modifiers, results) {
  cr <- hte_read(results, "did_cr_all_mimic.csv")
  id <- if ("patientunitstayid" %in% names(cr)) "patientunitstayid" else "stay_id"
  cr$pid <- cr[[id]]
  crl <- split(cr[, c("labresult", "offset_h")], cr$pid)
  rows <- list()
  for (h in c(48, 168)) for (threshold in c(.3, 1.0)) {
    keep <- hte_horizon_keep(pairs, h)
    yt <- yc <- integer(nrow(pairs))
    for (i in seq_len(nrow(pairs))) {
      zt <- crl[[as.character(pairs$trt_pid[i])]]
      zc <- crl[[as.character(pairs$ctl_pid[i])]]
      zt <- zt[zt$offset_h > pairs$t0[i] & zt$offset_h <= pairs$t0[i] + h, , drop = FALSE]
      zc <- zc[zc$offset_h > pairs$t0[i] & zc$offset_h <= pairs$t0[i] + h, , drop = FALSE]
      yt[i] <- as.integer(nrow(zt) && any(zt$labresult - pairs$baseline_trt[i] >= threshold))
      yc[i] <- as.integer(nrow(zc) && any(zc$labresult - pairs$baseline_ctl[i] >= threshold))
    }
    definition <- if (threshold == .3) "absolute_delta_ge_0.3" else "fixed_stage2_delta_ge_1.0"
    est <- pair_or_rd(yt[keep], yc[keep])
    int <- hte_egfr_interaction(
      yt[keep], yc[keep], modifiers$egfr[keep]
    )
    rows[[length(rows) + 1L]] <- cbind(
      data.frame(
        horizon_h = h, definition = definition, component = "effect",
        crossover_censor = "frozen_horizon_specific", eligible_pairs = sum(keep)
      ), est)
    rows[[length(rows) + 1L]] <- cbind(
      data.frame(
        horizon_h = h, definition = definition,
        component = "egfr_interaction",
        crossover_censor = "frozen_horizon_specific", eligible_pairs = sum(keep)
      ), int)
  }
  hte_rbind_fill(rows)
}

hte_stage_distribution <- function(pairs, modifiers) {
  rows <- list()
  strata <- egfr_stratum(modifiers$egfr * 30)
  for (h in c("48h", "7d")) for (g in c("Overall", levels(strata))) {
    idx <- if (g == "Overall") rep(TRUE, nrow(pairs)) else strata == g
    for (arm in c("trt", "ctl")) {
      a1 <- pairs[[paste0("aki1_", h, "_", arm)]]
      a2 <- pairs[[paste0("aki2_", h, "_", arm)]]
      a3 <- pairs[[paste0("aki3_", h, "_", arm)]]
      stage <- ifelse(a3 == 1, "stage3", ifelse(a2 == 1, "stage2",
                                                ifelse(a1 == 1, "stage1", "none")))
      for (s in c("none", "stage1", "stage2", "stage3")) {
        rows[[length(rows) + 1L]] <- data.frame(
          horizon = h, egfr_stratum = g, arm = arm, stage = s,
          n = sum(idx & !is.na(stage)), events = sum(idx & stage == s, na.rm = TRUE),
          proportion = mean(stage[idx] == s, na.rm = TRUE)
        )
      }
    }
  }
  do.call(rbind, rows)
}

run_hte_sweep <- function(tag, all_pts, pairs, results) {
  if (tag != "mimic") stop("The Entry-18c sweep is frozen to MIMIC only")
  set.seed(2026)
  modifiers <- hte_build_modifiers(all_pts, pairs, results)
  step1 <- hte_step1(pairs, modifiers)
  step2 <- hte_step2(pairs, modifiers, step1)
  forest <- hte_forest(all_pts, pairs, modifiers, results)
  outputs <- list(
    hte_sweep_step1_tests_mimic = step1$tests,
    hte_sweep_step1_terms_mimic = step1$terms,
    hte_sweep_step1_cells_mimic = step1$cells,
    hte_sweep_step2_candidates_mimic = step2$candidates,
    hte_sweep_step2_models_mimic = step2$models,
    hte_sweep_step2_grid_mimic = step2$grid,
    hte_sweep_forest_omnibus_mimic = forest$omnibus,
    hte_sweep_forest_importance_mimic = forest$importance,
    hte_sweep_forest_pdp_mimic = forest$pdp,
    hte_sweep_forest_fold_audit_mimic = forest$fold_audit,
    hte_sweep_treated_mechanism_mimic =
      hte_treated_mechanism(all_pts, pairs, modifiers),
    hte_probe_never_mimic = hte_probe_never(all_pts, pairs, modifiers),
    hte_probe_competing_mimic =
      hte_probe_competing(all_pts, pairs, modifiers, results),
    hte_probe_crossover_mimic = hte_probe_crossover(all_pts, pairs),
    hte_probe_kdigo_mimic = hte_probe_kdigo(all_pts, pairs, modifiers, results),
    hte_probe_stage_distribution_mimic = hte_stage_distribution(pairs, modifiers)
  )
  for (nm in names(outputs)) {
    write.csv(outputs[[nm]], file.path(results, paste0(nm, ".csv")), row.names = FALSE)
  }
  cat("03_hte.R | MIMIC | ENTRY-18C SWEEP COMPLETE\n")
}

run_hte_integrity_repairs <- function(tag, all_pts, pairs, results) {
  if (tag != "mimic") stop("Integrity repairs are frozen to MIMIC only")
  set.seed(2026)
  modifiers <- hte_build_modifiers(all_pts, pairs, results)
  forest <- hte_forest(all_pts, pairs, modifiers, results)
  outputs <- list(
    hte_sweep_forest_omnibus_mimic = forest$omnibus,
    hte_sweep_forest_importance_mimic = forest$importance,
    hte_sweep_forest_pdp_mimic = forest$pdp,
    hte_sweep_forest_fold_audit_mimic = forest$fold_audit,
    hte_probe_kdigo_mimic =
      hte_probe_kdigo(all_pts, pairs, modifiers, results)
  )
  for (nm in names(outputs)) {
    write.csv(
      outputs[[nm]], file.path(results, paste0(nm, ".csv")),
      row.names = FALSE
    )
  }
  cat("03_hte.R | MIMIC | ENTRY-19 INTEGRITY REPAIRS COMPLETE\n")
}
