#!/usr/bin/env bash
set -euo pipefail
project=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$project/scripts/common.sh"
cd "$project"
mkdir -p evidence
bash scripts/create-table.sh 2>&1 | tee evidence/create-table.log
bash scripts/load-partition.sh data/events-2026-10-20.csv 2026-10-20 2>&1 | tee evidence/load-2026-10-20.log
bash scripts/load-partition.sh data/events-2026-10-21.csv 2026-10-21 2>&1 | tee evidence/load-2026-10-21.log
bash scripts/load-partition.sh data/events-2026-10-20.csv 2026-10-20 2>&1 | tee evidence/reload-2026-10-20.log
as_hive bash scripts/check.sh 2>&1 | tee evidence/check.log
bash scripts/check-yarn.sh
echo 'PASS: demo completed, including repeat load, parallel clients and MapReduce/YARN'
