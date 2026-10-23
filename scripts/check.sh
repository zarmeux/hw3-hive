#!/usr/bin/env bash
set -euo pipefail
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/opt/hadoop HADOOP_CONF_DIR=/etc/hive/hadoop
export HIVE_HOME=/opt/hive HIVE_CONF_DIR=/etc/hive HADOOP_HEAPSIZE=256
systemctl is-active hive-metastore hive-hiveserver2
/opt/hadoop/bin/hdfs dfs -ls /user/hive
/opt/hadoop/bin/yarn node -list
tmpdir=$(mktemp -d)
pid1=
pid2=
cleanup() {
  for pid in "$pid1" "$pid2"; do
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$tmpdir"
}
trap cleanup EXIT
mkfifo "$tmpdir/client1.in" "$tmpdir/client2.in"
exec 3<>"$tmpdir/client1.in"
exec 4<>"$tmpdir/client2.in"
timeout 90 /opt/hive/bin/beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive --force=false --outputformat=tsv2 --showHeader=false \
  < "$tmpdir/client1.in" > "$tmpdir/client1.log" 2>&1 3>&- 4>&- & pid1=$!
timeout 90 /opt/hive/bin/beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive --force=false --outputformat=tsv2 --showHeader=false \
  < "$tmpdir/client2.in" > "$tmpdir/client2.log" 2>&1 3>&- 4>&- & pid2=$!
connected=0
for ((attempt=0; attempt<60; attempt++)); do
  if grep -q 'Connected to: Apache Hive' "$tmpdir/client1.log" && \
     grep -q 'Connected to: Apache Hive' "$tmpdir/client2.log"; then
    connected=1
    break
  fi
  if ! kill -0 "$pid1" 2>/dev/null || ! kill -0 "$pid2" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [[ $connected -ne 1 ]]; then
  cat "$tmpdir/client1.log" "$tmpdir/client2.log"
  echo 'FAIL: could not open both Beeline sessions' >&2
  exit 1
fi
echo 'PASS: both clients connected before queries were released'
printf 'SHOW DATABASES;\nSELECT 1;\n!quit\n' >&3
printf 'SHOW DATABASES;\nSELECT 1;\n!quit\n' >&4
exec 3>&-
exec 4>&-
rc=0
wait "$pid1" || rc=1
wait "$pid2" || rc=1
for logfile in "$tmpdir/client1.log" "$tmpdir/client2.log"; do
  grep -qx 'default' "$logfile" || rc=1
  grep -qx '1' "$logfile" || rc=1
done
cat "$tmpdir/client1.log" "$tmpdir/client2.log"
exit "$rc"
