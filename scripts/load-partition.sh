#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ $# -eq 2 && -f $1 ]] || { echo "Usage: sudo bash $0 CSV_FILE YYYY-MM-DD" >&2; exit 1; }
input=$1
partition_date=$2
python3 - "$partition_date" <<'PY'
import datetime, re, sys
s=sys.argv[1]
if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', s): raise SystemExit('Date must be YYYY-MM-DD')
datetime.date.fromisoformat(s)
PY
exec 9>"/var/lock/hw3-hive-${partition_date}.lock"
flock -x 9
tmpdir=$(mktemp -d /var/lib/hive/tmp/hw3-load.XXXXXXXX)
chown hive:hive "$tmpdir"
staging="/user/hive/staging/hw3-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
staged=0
cleanup() {
  if [[ $staged -eq 1 ]]; then
    as_hive /opt/hadoop/bin/hdfs dfs -rm -r -f "$staging" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
install -o hive -g hive -m 0400 "$input" "$tmpdir/events.csv"
python3 - "$tmpdir/events.csv" <<'PY'
import pathlib, re, sys
lines=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
if not lines: raise SystemExit('CSV must contain at least one event')
for n,line in enumerate(lines,1):
    if not re.fullmatch(r'[0-9]+,[0-9]+,[a-zA-Z][a-zA-Z0-9_]*',line):
        raise SystemExit(f'Invalid CSV row {n}: expected event_id,user_id,event_type without header')
    if any(int(x)>2**63-1 for x in line.split(',')[:2]):
        raise SystemExit(f'BIGINT overflow at row {n}')
print(f'Validated {len(lines)} events')
PY
as_hive /opt/hadoop/bin/hdfs dfs -mkdir -p "$staging"
staged=1
as_hive /opt/hadoop/bin/hdfs dfs -put "$tmpdir/events.csv" "$staging/events.csv"
cat > "$tmpdir/load.sql" <<EOF
LOAD DATA INPATH '${staging}/events.csv'
OVERWRITE INTO TABLE hw3.events
PARTITION (event_date='${partition_date}');
SHOW PARTITIONS hw3.events;
SELECT event_id, user_id, event_type, event_date FROM hw3.events
WHERE event_date='${partition_date}';
EOF
chown hive:hive "$tmpdir/load.sql"
chmod 0400 "$tmpdir/load.sql"
as_hive /opt/hive/bin/beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive \
  --force=false --outputformat=tsv2 --showHeader=false -f "$tmpdir/load.sql"
echo "Loaded partition event_date=${partition_date} (overwrite)"
