#!/bin/bash
#SBATCH --job-name=alb_entry42
#SBATCH --account=group-jasonclark
#SBATCH --partition=nextgen
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --output=logs/entry42_%j.out
#SBATCH --error=logs/entry42_%j.err
#SBATCH --export=NONE

set -euo pipefail
cd /home/g91p721/albumin_aki_integrity
mkdir -p logs

module purge
module load Python/3.10.8-GCCcore-12.2.0
source /home/g91p721/alcrx/.venv/bin/activate
python extract_albumin_volume.py \
  --data-root /home/g91p721/mg_aki/mimic-iv-3.1 \
  --results /home/g91p721/albumin_aki/results
deactivate

module purge
module load R/4.5.1-gfbf-2025a
export ALBUMIN_AKI_RESULTS=/home/g91p721/albumin_aki/results
Rscript 05_descriptive_followups.R mimic volume
Rscript 05_descriptive_followups.R mimic make
Rscript 05_descriptive_followups.R eicu make

echo "Entry 42 batch COMPLETE"
