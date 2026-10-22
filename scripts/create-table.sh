#!/usr/bin/env bash
set -euo pipefail
project=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$project/scripts/run-sql.sh" "$project/sql/create-events.sql"
