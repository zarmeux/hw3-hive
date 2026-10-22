#!/usr/bin/env bash
set -euo pipefail
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/opt/hadoop HADOOP_CONF_DIR=/etc/hive/hadoop
export HIVE_HOME=/opt/hive HIVE_CONF_DIR=/etc/hive HADOOP_HEAPSIZE=256
systemctl is-active hive-metastore hive-hiveserver2
/opt/hadoop/bin/hdfs dfs -ls /user/hive
/opt/hadoop/bin/yarn node -list
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
client() {
  /opt/hive/bin/beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive \
    -e 'SHOW DATABASES; SELECT 1;'
}
client > "$tmpdir/client1.log" 2>&1 & pid1=$!
client > "$tmpdir/client2.log" 2>&1 & pid2=$!
rc=0
wait "$pid1" || rc=1
wait "$pid2" || rc=1
cat "$tmpdir/client1.log" "$tmpdir/client2.log"
exit "$rc"
