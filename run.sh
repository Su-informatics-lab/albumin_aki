#!/bin/bash
# run.sh — Albumin -> CSA-AKI pipeline
# Usage: bash run.sh          # full run
#        bash run.sh 1 2      # steps 1 and 2 only
set -euo pipefail
cd "$(dirname "$0")"
RESULTS="results"
SEP="======================================================================"
log() { echo -e "\n$SEP\n  STEP $1: $2\n$SEP"; }
STEPS=("$@")
if [ ${#STEPS[@]} -eq 0 ]; then STEPS=(1 2 3); fi

for step in "${STEPS[@]}"; do
case $step in
1)
    log "1" "ETL (01_etl.py)"
    mkdir -p $RESULTS logs
    python 01_etl.py 2>&1 | tee logs/01_etl.log
    ;;
2)
    log "2" "Canonical risk-set PSM (02_psm.R) [set.seed(2026)]"
    Rscript 02_psm.R mimic pooled 2>&1 | tee logs/02_psm_mimic_pooled.log
    Rscript 02_psm.R mimic egfr   2>&1 | tee logs/02_psm_mimic_egfr.log
    Rscript 02_psm.R eicu pooled  2>&1 | tee logs/02_psm_eicu_pooled.log
    Rscript 02_psm.R eicu egfr    2>&1 | tee logs/02_psm_eicu_egfr.log
    ;;
3)
    log "3" "HTE (03_hte.R)"
    Rscript 03_hte.R mimic 2>&1 | tee logs/03_hte_mimic.log
    Rscript 03_hte.R eicu  2>&1 | tee logs/03_hte_eicu.log
    ;;
*)  echo "Unknown step: $step (valid: 1-3)" ;;
esac
done
echo -e "\n$SEP\n  DONE\n$SEP"
