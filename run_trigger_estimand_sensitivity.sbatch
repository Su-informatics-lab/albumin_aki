#!/bin/bash
#SBATCH --job-name=alb_trigger_ate
#SBATCH --account=group-jasonclark
#SBATCH --partition=nextgen
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --export=NONE
#SBATCH --output=logs/trigger_estimand_%x_%j.out
#SBATCH --error=logs/trigger_estimand_%x_%j.err

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: sbatch run_trigger_estimand_sensitivity.sbatch {mimic|eicu|iuh}" >&2
  exit 2
fi
db="$1"
if [[ ! "$db" =~ ^(mimic|eicu|iuh)$ ]]; then
  echo "Invalid database: $db" >&2
  exit 2
fi

module purge
module load R/4.5.1-gfbf-2025a
Rscript probe_albumin_trigger_estimand.R "$db"
