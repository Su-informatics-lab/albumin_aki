#!/bin/bash
#SBATCH --job-name=alb_iuh_strat
#SBATCH --account=r01834
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --export=NONE
#SBATCH --output=logs/iuh_stratified_%j.out
#SBATCH --error=logs/iuh_stratified_%j.err

set -euo pipefail
cd /N/project/depot/hw56/albumin_aki_run
module load r/4.3.1
export ALBUMIN_AKI_RESULTS=/N/project/depot/hw56/albumin_aki/results
Rscript tests/test_phase3_static.R
Rscript 02_psm.R iuh egfr
Rscript 02_psm.R iuh egfr_reported
Rscript 03_hte.R iuh
Rscript iuh/probe_stratified_results.R "$ALBUMIN_AKI_RESULTS"
