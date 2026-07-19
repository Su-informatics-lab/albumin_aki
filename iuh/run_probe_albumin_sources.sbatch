#!/bin/bash
#SBATCH --job-name=alb_iuh_src
#SBATCH --account=r01834
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=24G
#SBATCH --time=01:00:00
#SBATCH --export=NONE
#SBATCH --output=logs/iuh_source_%j.out
#SBATCH --error=logs/iuh_source_%j.err

set -euo pipefail
cd /N/project/depot/hw56/albumin_aki
mkdir -p logs results
python3 iuh/probe_albumin_sources.py --outdir results
