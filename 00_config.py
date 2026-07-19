"""
00_config.py — Shared constants for Albumin → CSA-AKI study
Adapted from mg_aki/00_config.py (v6.0)

Used by: 01_etl.py, 02_psm.R, 03_hte.R
"""

import os

# ═══════════════════════════════════════════════════════════════════
# PATHS  (reads from same raw data as mg_aki)
# ═══════════════════════════════════════════════════════════════════
RESULTS = os.path.expanduser("~/albumin_aki/results")
os.makedirs(RESULTS, exist_ok=True)

_FULL = os.path.expanduser("~/mg_aki/eicu-crd-2.0")
_DEMO = os.path.expanduser("~/mg_aki/eicu-collaborative-research-database-demo-2.0.1")
EICU_ROOT = _FULL if os.path.isdir(_FULL) else _DEMO

MIMIC_ROOT = os.path.expanduser("~/mg_aki/mimic-iv-3.1")
MIMIC_HOSP = os.path.join(MIMIC_ROOT, "hosp")
MIMIC_ICU = os.path.join(MIMIC_ROOT, "icu")

# ═══════════════════════════════════════════════════════════════════
# CLINICAL CONSTANTS
# ═══════════════════════════════════════════════════════════════════
MIN_AGE = 18
CR_MIN, CR_MAX = 0.1, 25.0
CR_POST_PLAUSIBLE_MAX = 15.0
BASELINE_CR_MAX = 4.0
# Phase 3 derives alb_cat strictly before index T0: low < cut, normal >= cut.
ALB_LOW_CUT = 3.5

# ═══════════════════════════════════════════════════════════════════
# MIMIC ITEM IDS — LABS
# ═══════════════════════════════════════════════════════════════════
LAB_CR_MIMIC = [50912, 52546]  # Serum creatinine
LAB_ALB_MIMIC = [50862, 53085]  # Serum albumin (blood chemistry)
LAB_HGB_MIMIC = [51222, 50811]  # Hemoglobin (serum, blood gas)
LAB_CA_MIMIC = [50893]  # Calcium
LAB_LAC_MIMIC = [50813]  # Lactate
LAB_K_MIMIC = [50971]  # Potassium (for Sensitivity A)
LAB_MG_MIMIC = [50960]  # Magnesium (descriptive only)
VITAL_HR_MIMIC = [220045]  # Heart rate

LAB_WBC_MIMIC = [51301, 51300]  # WBC (Table 1 descriptive)
LAB_PLT_MIMIC = [51265]  # Platelet (Table 1 descriptive)

# All lab items for DuckDB bulk load
ALL_LAB_ITEMS_MIMIC = set(
    LAB_CR_MIMIC
    + LAB_ALB_MIMIC
    + LAB_HGB_MIMIC
    + LAB_CA_MIMIC
    + LAB_LAC_MIMIC
    + LAB_K_MIMIC
    + LAB_MG_MIMIC
)
TABLE1_LAB_ITEMS_MIMIC = set(LAB_WBC_MIMIC + LAB_PLT_MIMIC)

# ═══════════════════════════════════════════════════════════════════
# MIMIC ITEM IDS — ALBUMIN INFUSION (EXPOSURE)
# ═══════════════════════════════════════════════════════════════════
# Verified from probe_albumin_mimic.py (d_items):
#   220862 = Albumin 25%  (Blood Products/Colloids, mL)
#   220864 = Albumin 5%   (Blood Products/Colloids, mL)
# Excluded (Not In Use):
#   220861 = Albumin (Human) 20% — zero or near-zero usage
#   220863 = Albumin (Human) 4%  — zero or near-zero usage
ALB_INFUSION_ITEMS_MIMIC = [220862, 220864]
ALB_PRODUCT_MAP = {220862: "albumin_25pct", 220864: "albumin_5pct"}

# ═══════════════════════════════════════════════════════════════════
# MIMIC — RRT DETECTION (copied from mg_aki)
# ═══════════════════════════════════════════════════════════════════
RRT_PROCEDURE_ITEMS_MIMIC = [225441, 225802, 225803, 225805, 225809, 225955]
RRT_INPUT_ITEMS_MIMIC = [227536, 227525, 230044]
RRT_CHART_ITEMS_MIMIC = [226499]

# ═══════════════════════════════════════════════════════════════════
# TEXT PATTERNS
# ═══════════════════════════════════════════════════════════════════
# eICU albumin infusion patterns (medication table)
ALB_INFUSION_PATTERNS = [
    "albumin human",
    "albumin 5%",
    "albumin 25%",
    "albumin 20%",
    "plasbumin",
]
ALB_IV_ROUTE_PATTERNS = r"iv\b|ivpb|intravenou|intravenous"

# eICU albumin in intakeOutput (confirmed administration)
ALB_IO_PATTERNS = ["albumin"]

CARDIAC_DX_PATTERNS = [
    "cabg",
    "valve",
    "cardiac surgery",
    "open heart",
    "coronary artery bypass",
    "aortic valve",
    "mitral valve",
    "cardiothoracic",
    "aortic surgery",
    "tricuspid",
    "pulmonic valve",
]
CARDIAC_UNIT_TYPES = {"CSICU", "CTICU", "CCU-CTICU"}

ESKD_PATTERNS = [
    "dialysis",
    "esrd",
    "end stage renal",
    "end-stage renal",
    "renal transplant",
    "kidney transplant",
]

# ═══════════════════════════════════════════════════════════════════
# ICD CODES (identical to mg_aki)
# ═══════════════════════════════════════════════════════════════════
CABG_ICD9 = ["3610", "3611", "3612", "3613", "3614", "3615", "3616", "3617", "3619"]
VALVE_ICD9 = [
    "3521",
    "3522",
    "3523",
    "3524",
    "3525",
    "3526",
    "3527",
    "3528",
    "3511",
    "3512",
    "3513",
    "3514",
]
CABG_ICD10 = ["0210", "0211", "0212", "0213"]
VALVE_ICD10 = ["02RF", "02RG", "02RH", "02RJ", "02QF", "02QG", "02QH", "02QJ"]
CVICU = "Cardiac Vascular Intensive Care Unit (CVICU)"

ESKD_ICD = {
    9: ["5856", "V4511", "V560", "V561", "V562"],
    10: ["N186", "Z491", "Z492", "Z9911", "Z940"],
}

# ═══════════════════════════════════════════════════════════════════
# COMORBIDITIES (identical to mg_aki)
# ═══════════════════════════════════════════════════════════════════
EICU_COMORB = {
    "heart_failure": ["heart failure", "chf", "cardiomyopathy"],
    "hypertension": ["hypertension"],
    "diabetes": ["diabetes"],
    "ckd": ["chronic kidney", "chronic renal", "ckd"],
    "copd": ["copd", "chronic obstructive", "emphysema"],
    "pvd": ["peripheral vascular", "pvd", "claudication"],
    "stroke": ["stroke", "cva", "cerebrovascular"],
    "liver_disease": ["cirrhosis", "hepatitis", "liver disease", "liver failure"],
}

MIMIC_COMORB_ICD = {
    "heart_failure": {9: ["4280", "4281", "4289", "428"], 10: ["I50"]},
    "hypertension": {
        9: ["401", "402", "403", "404", "405"],
        10: ["I10", "I11", "I12", "I13", "I15"],
    },
    "diabetes": {9: ["250"], 10: ["E08", "E09", "E10", "E11", "E12", "E13"]},
    "ckd": {9: ["585", "586"], 10: ["N18", "N19"]},
    "copd": {
        9: ["490", "491", "492", "493", "494", "496"],
        10: ["J40", "J41", "J42", "J43", "J44", "J45", "J47"],
    },
    "pvd": {9: ["4431", "4439", "4471"], 10: ["I73"]},
    "stroke": {
        9: ["430", "431", "432", "433", "434", "435", "436"],
        10: ["I60", "I61", "I62", "I63", "I64", "I65", "I66", "G45"],
    },
    "liver_disease": {
        9: ["571"],
        10: ["K70", "K71", "K72", "K73", "K74", "K75", "K76"],
    },
}

# ═══════════════════════════════════════════════════════════════════
# CHRONIC DRUG CLASSES (identical to mg_aki)
# ═══════════════════════════════════════════════════════════════════
CHRONIC_DRUG_CLASSES = {
    "ppi_chronic": [
        "omeprazole",
        "pantoprazole",
        "lansoprazole",
        "esomeprazole",
        "rabeprazole",
    ],
    "loop_diuretic_chronic": ["furosemide", "bumetanide", "torsemide", "lasix"],
    "acei_arb_chronic": [
        "lisinopril",
        "enalapril",
        "ramipril",
        "captopril",
        "losartan",
        "valsartan",
        "irbesartan",
        "candesartan",
        "olmesartan",
        "telmisartan",
    ],
    "nsaid_chronic": [
        "ibuprofen",
        "ketorolac",
        "naproxen",
        "diclofenac",
        "celecoxib",
        "indomethacin",
        "meloxicam",
    ],
}
ORAL_ROUTE_RE = r"oral|po\b|tablet|capsule|cap\b|tab\b"

# ═══════════════════════════════════════════════════════════════════
# eICU LAB PATTERNS — PS time-varying + Table 1 descriptive
# ═══════════════════════════════════════════════════════════════════
# PS time-varying labs (computed at match time in R)
EICU_LAB_PATTERNS = {
    "hemoglobin": ["hgb", "hemoglobin"],  # NEW: replaces Mg/K in PS
    "calcium": ["calcium"],
    "lactate": ["lactate"],
    "potassium": ["potassium"],  # Sensitivity A only
    "magnesium": ["magnesium"],  # Descriptive only
    "albumin": ["albumin"],  # Peri-admission stratification
}
# Table 1 descriptive (not in PS)
EICU_TABLE1_LAB_PATTERNS = {
    "wbc": ["wbc"],
    "platelets": ["platelet"],
}

# eICU RRT detection
EICU_RRT_TREATMENT_PATTERNS = [
    "dialysis",
    "crrt",
    "cvvh",
    "cvvhd",
    "cvvhdf",
    "hemodialysis",
    "scuf",
    "ultrafiltration",
]

# ═══════════════════════════════════════════════════════════════════
# PS COVARIATES
# ═══════════════════════════════════════════════════════════════════
# Time-invariant: extracted in ETL, fixed per patient
PS_TIME_INVARIANT = [
    "age",
    "is_female",
    "bmi",
    "surg_cabg",
    "surg_valve",
    "surg_combined",
    "heart_failure",
    "hypertension",
    "diabetes",
    "ckd",
    "copd",
    "pvd",
    "stroke",
    "liver_disease",
    "egfr",
    "ppi_chronic",
    "loop_diuretic_chronic",
    "acei_arb_chronic",
    "nsaid_chronic",
]

# Time-varying: computed at match time in R from did_labs_all
# NOTE: hemoglobin replaces mg_value from mg_aki;
#       albumin and potassium excluded from primary PS (Sensitivity A only)
PS_TIME_VARYING_LABS = [
    "hemoglobin",  # NEW: key confounder (hemodilution pathway)
    "calcium",
    "lactate",
    "lactate_missing",
    "heartrate",
]

# ═══════════════════════════════════════════════════════════════════
# OUTPUT COLUMNS for did_all_{db}.csv
# ═══════════════════════════════════════════════════════════════════
ALL_PATIENTS_COLS = [
    "pid",
    "hadm_id",
    "treated",
    "alb_offset_h",
    "alb_offset_min",  # exposure timing
    "alb_product",  # '5pct', '25pct', or 'mixed' (MIMIC only)
    "alb_total_ml_24h",  # total mL in first 24h
    "peri_admission_alb",  # stratification variable (g/dL)
    "icu_discharge_h",
    "icu_outcome",
    "age",
    "is_female",
    "bmi",
    "surgery_type",
    "surg_cabg",
    "surg_valve",
    "surg_combined",
    *EICU_COMORB.keys(),
    "baseline_cr",
    "baseline_cr_offset_h",
    "baseline_cr_source",
    "cr_ref_early",
    "cr_ref_early_offset_h",
    "cr_ref_early_source",
    "first_cr",  # compatibility alias of baseline_cr until the Phase 3 repair
    "egfr",
    *CHRONIC_DRUG_CLASSES.keys(),
    "hosp_mortality",
    "vent_arrhythmia",
    "rrt_offset_h",
    "has_rrt",
    "death_offset_h",
]
