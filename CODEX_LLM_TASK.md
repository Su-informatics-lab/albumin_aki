# Codex Task: LLM Endpoint Extraction for albumin_aki

## Your role

You are extracting clinical endpoints from MIMIC-IV-Note discharge summaries
for a cardiac surgery albumin study. You will adapt the existing ATLAS LLM
extraction pipeline to this task, using CatChat on IU Tempest HPC.

## What exists (adapt, don't rebuild)

```
/Users/haining/Desktop/github/atlas/llm_extract/
    __init__.py
    schema.py       <- Pydantic schemas for structured extraction
```

The ATLAS pipeline extracted 7,622 notes with 100% completion for endpoints
like POAF, delirium, reintubation, transfusion. It uses CatChat
(OpenAI-compatible API) with structured JSON output and checkpoint/resume.

You also know `medace_aud` and `medace_aki` -- use the same rigor: Pydantic
schema as prompt, structured JSON output, confidence fields, negation handling.

## Target location

Create extraction code at:
```
~/albumin_aki/llm_extract/
    __init__.py
    schema.py           <- Pydantic endpoint schemas
    extract.py          <- Main extraction script (CatChat + checkpoint)
    cardiac_cohort.py   <- Identifies cardiac surgery hadm_ids (no dependency on albumin cohort)
    validate.py         <- ICD vs LLM concordance + inter-rater QC
```

Results go to: `~/albumin_aki/results/llm_endpoints_mimic.csv`

## CatChat API

```
URL:   https://catchat-api.msu.montana.edu/v1/chat/completions
Model: gpt-oss:120b    (or whatever is currently available; check with: curl -s $URL/../models)
Auth:  Bearer $CATCHAT_API_KEY   (env var, already set on Tempest)
```

OpenAI-compatible. Same calling convention as ATLAS.

## Tempest environment

```bash
module purge
module load Python/3.10.8-GCCcore-12.2.0
source ~/alcrx/.venv/bin/activate
```

## Notes location on Tempest

```
~/mg_aki/physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz
```

Columns: `note_id, subject_id, hadm_id, note_type, note_seq, charttime, storetime, text`

## Step 1: Identify cardiac surgery hadm_ids (cardiac_cohort.py)

You do NOT need to wait for the albumin study cohort. Extract ALL cardiac
surgery patients from MIMIC-IV directly:

```python
# Cardiac surgery ICD-9 procedure codes (prefixes):
ICD9_CARDIAC = [
    "3510","3511","3512","3513","3514",  # valve ops
    "3521","3522","3523","3524","3525","3526","3527","3528",  # valve replacement
    "3541","3542",  # enlargement/repair
    "3611","3612","3613","3614",  # CABG
    "3615","3616","3617","3619",
    "3631","3632",  # internal mammary
    "3834","3844","3845",  # thoracic vessel
    "3761",  # cardiac device
]

# ICD-10-PCS: heart operations start with 02 (Medical and Surgical, Heart)
# plus 021 (Bypass, which includes CABG from aorta)
ICD10_CARDIAC_PREFIX = ["02", "021"]

# Load from:
# ~/mg_aki/mimic-iv-3.1/hosp/procedures_icd.csv.gz
# Filter for cardiac ICD codes -> get set of hadm_ids
# Then inner-join with discharge notes to get the note text
```

Expected: ~15,000-20,000 cardiac surgery hadm_ids with discharge notes.
The albumin study cohort (~12,667) is a subset of these.

## Step 2: Endpoints to extract (schema.py)

Extract these 12 endpoints from each discharge note. Use a Pydantic schema
that becomes the LLM prompt (medace pattern):

```python
class CardiacSurgeryEndpoints(BaseModel):
    """Postoperative complications after cardiac surgery."""

    # --- Bleeding / surgical ---
    return_to_or: int          # 0/1: reoperation/resternotomy for bleeding/tamponade
    resternotomy_reason: str   # "bleeding"/"tamponade"/"other"/"none" (for QC)

    # --- Respiratory ---
    reintubation: int          # 0/1: reintubated after initial extubation
    pneumonia_vap: int         # 0/1: new pneumonia or VAP

    # --- Infection ---
    sepsis: int                # 0/1: new sepsis or septic shock (not initial SIRS)
    sternal_wound_inf: int     # 0/1: sternal wound infection or mediastinitis
    bloodstream_inf: int       # 0/1: positive blood culture + clinical infection

    # --- Cardiac ---
    cardiac_arrest: int        # 0/1: cardiac arrest / CPR / code blue
    poaf: int                  # 0/1: new-onset atrial fibrillation postop
    acute_heart_failure: int   # 0/1: new or worsened HF requiring inotropes/MCS

    # --- Neurological ---
    stroke: int                # 0/1: new stroke or TIA
    delirium: int              # 0/1: new delirium or encephalopathy

    # --- Myocardial (from note text, not CK-MB) ---
    myocardial_injury: int     # 0/1: perioperative MI or significant troponin elevation mentioned

    # --- Meta ---
    confidence: str            # "high"/"medium"/"low"
    extraction_note: str       # free text: anything ambiguous
```

## Step 3: Extraction prompt (extract.py)

System prompt pattern (adapt from ATLAS):

```
You are a clinical data abstractor reviewing cardiac surgery ICU discharge
summaries from MIMIC-IV. For each note, determine whether the following
postoperative complications occurred during THIS hospitalization.

CRITICAL RULES:
1. Only code events that ACTUALLY HAPPENED, not differential diagnoses or
   "ruled out" conditions
2. Pre-existing conditions (e.g., chronic AF) are NOT postoperative events
3. Expected postoperative course (e.g., initial intubation) is NOT a complication
4. When uncertain, code 0 and set confidence="low"

Respond with ONLY a JSON object matching this schema:
{schema_json}
```

## Step 4: Section extraction (reduce tokens)

Before sending to LLM, extract the "Brief Hospital Course" section:

```python
import re
SECTION_RE = re.compile(
    r"(brief hospital course|hospital course|course of hospitalization)",
    re.IGNORECASE
)
# Find the section, take up to 6000 chars (~1500 tokens)
# If not found, take last 60% of note
```

This reduces each API call from ~3000 tokens to ~1500, halving cost and latency.

## Step 5: Checkpoint / resume

Same pattern as ATLAS:
- Save to `_llm_checkpoint.csv` every 50 notes
- On restart, load checkpoint and skip already-processed hadm_ids
- Track `hadm_id`, all endpoint columns, `confidence`, `extraction_note`
- Final output: `~/albumin_aki/results/llm_endpoints_mimic.csv`

## Step 6: Quality control (validate.py)

After extraction completes:

### 6a. ICD vs LLM concordance
For endpoints with both ICD and LLM definitions:

| Endpoint | ICD source (dx_infection_mimic.csv) | LLM column |
|---|---|---|
| pneumonia | dx_name="pneumonia" | pneumonia_vap |
| sepsis | dx_name="sepsis" | sepsis |
| SSI | dx_name="ssi_mediastinitis" | sternal_wound_inf |

Compute 2x2 table, sensitivity, specificity, Cohen's kappa for each.
Print the concordance matrix.

### 6b. Confidence distribution
```python
# Print: how many high/medium/low confidence per endpoint
# Flag any endpoint where >20% is low confidence
```

### 6c. Spot-check sample
```python
# For each endpoint, sample 5 positive + 5 negative cases
# Print hadm_id + the BHC section excerpt + the LLM judgment
# Human (Haining) reviews these
```

## Run sequence

```bash
# 1. Build cardiac surgery cohort (fast, no LLM)
python -m llm_extract.cardiac_cohort

# 2. Dry run (5 notes, verify JSON parsing)
python -m llm_extract.extract --dry-run

# 3. Full run (expect ~4-8 hours for 15k notes at 0.5s/note)
python -m llm_extract.extract

# 4. Validate
python -m llm_extract.validate
```

## Important: what the main pipeline expects

After extraction, the downstream R scripts (02_psm_v2.R) will read:
```
~/albumin_aki/results/llm_endpoints_mimic.csv
```

Columns expected:
```
hadm_id, pid,
return_to_or, reintubation, pneumonia_vap, sepsis,
sternal_wound_inf, bloodstream_inf, cardiac_arrest, poaf,
acute_heart_failure, stroke, delirium, myocardial_injury,
confidence
```

- `pid` = MIMIC stay_id (join via icustays hadm_id -> stay_id)
- Values: 0 = absent, 1 = present, -1 = extraction failed
- Only rows in the final albumin cohort will be used, but extract ALL cardiac
  surgery patients so nothing needs re-running if cohort changes

## File I/O summary

```
READS:
  ~/mg_aki/mimic-iv-3.1/hosp/procedures_icd.csv.gz    (cardiac surgery codes)
  ~/mg_aki/mimic-iv-3.1/icu/icustays.csv.gz            (hadm_id -> stay_id)
  ~/mg_aki/physionet.org/files/mimic-iv-note/2.2/note/discharge.csv.gz
  ~/albumin_aki/results/dx_infection_mimic.csv           (for ICD vs LLM validation)

WRITES:
  ~/albumin_aki/results/_llm_checkpoint.csv              (intermediate, safe to delete after)
  ~/albumin_aki/results/llm_endpoints_mimic.csv          (final output)
  ~/albumin_aki/results/llm_qc_concordance.txt           (validation report)
  ~/albumin_aki/results/llm_qc_spotcheck.txt             (spot-check samples)
```

## Quality bar

- 100% completion (no hadm_id left unprocessed; -1 for failures is OK if <1%)
- ICD vs LLM kappa > 0.4 for pneumonia and sepsis (if lower, review prompt)
- <5% low-confidence extractions
- Human spot-check: <10% error rate on the 60 sampled cases (5+5 per endpoint x 6 key endpoints)
