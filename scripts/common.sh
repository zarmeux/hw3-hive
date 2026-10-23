#!/usr/bin/env bash
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo bash.' >&2; exit 1; }
HIVE_ENV=(
  JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
  HADOOP_HOME=/opt/hadoop HADOOP_CONF_DIR=/etc/hive/hadoop
  HIVE_HOME=/opt/hive HIVE_CONF_DIR=/etc/hive HADOOP_HEAPSIZE=256
)
as_hive() { runuser -u hive -- env "${HIVE_ENV[@]}" "$@"; }
