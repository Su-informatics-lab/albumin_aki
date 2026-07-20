#!/bin/bash
#SBATCH --job-name=alb_iuh_etl
#SBATCH --account=r01834
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --export=NONE
#SBATCH --output=logs/iuh_etl_%j.out
#SBATCH --error=logs/iuh_etl_%j.err

set -euo pipefail
cd /N/project/depot/hw56/albumin_aki
mkdir -p logs results
export ALBUMIN_AKI_RESULTS=/N/project/depot/hw56/albumin_aki/results
python3 iuh/01_etl.py
