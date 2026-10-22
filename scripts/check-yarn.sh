#!/usr/bin/env bash
set -euo pipefail
project=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$project/scripts/common.sh"
mkdir -p "$project/evidence"
bash "$project/scripts/run-sql.sh" "$project/sql/check-yarn.sql" 2>&1 | tee "$project/evidence/yarn-query.log"
application_id=$(python3 - "$project/evidence/yarn-query.log" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
rows=re.findall(r'^(\d{4}-\d{2}-\d{2})\t(\d+)\s*$',s,re.M)
assert sorted(rows)==[('2026-10-20','3'),('2026-10-21','2')], rows
apps=re.findall(r'application_\d+_\d+',s)
assert apps, 'No YARN application found in Beeline output'
assert 'number of mappers: 1; number of reducers: 1' in s, 'Unexpected MapReduce plan'
print(apps[-1])
PY
)
as_hive /opt/hadoop/bin/yarn application -status "$application_id" 2>&1 | tee "$project/evidence/yarn-application.log"
python3 - "$project/evidence/yarn-application.log" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
assert re.search(r'Final-State\s*:\s*SUCCEEDED',s), s
assert re.search(r'Application-Type\s*:\s*MAPREDUCE',s), s
print('PASS: distributed aggregation returned 3 and 2; YARN Final-State=SUCCEEDED')
PY
