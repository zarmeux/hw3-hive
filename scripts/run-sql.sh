#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ $# -eq 1 && -f $1 ]] || { echo "Usage: sudo bash $0 SQL_FILE" >&2; exit 1; }
tmpdir=$(mktemp -d /var/lib/hive/tmp/hw3-sql.XXXXXXXX)
trap 'rm -rf "$tmpdir"' EXIT
chown hive:hive "$tmpdir"
install -o hive -g hive -m 0400 "$1" "$tmpdir/query.sql"
as_hive /opt/hive/bin/beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive \
  --force=false --outputformat=tsv2 --showHeader=false -f "$tmpdir/query.sql"
