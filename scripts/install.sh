#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash scripts/install.sh'; exit 1; }
export DEBIAN_FRONTEND=noninteractive
VERSION=4.0.0-alpha-2
ARCHIVE=apache-hive-${VERSION}-bin.tar.gz
BASE=https://archive.apache.org/dist/hive/hive-${VERSION}
JAVA=/usr/lib/jvm/java-11-openjdk-amd64
test -x "$JAVA/bin/java"
test -f /etc/hadoop-yarn/core-site.xml
apt-get update
apt-get install -y postgresql libpostgresql-jdbc-java curl python3
systemctl enable --now postgresql
id hive >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/hive --shell /usr/sbin/nologin hive
install -d -m 0755 /var/cache/hw3-hive
cd /var/cache/hw3-hive
curl -fL --retry 3 -C - -o "$ARCHIVE" "$BASE/$ARCHIVE"
curl -fL --retry 3 -o "$ARCHIVE.sha256" "$BASE/$ARCHIVE.sha256"
python3 - "$ARCHIVE" <<'PY'
import hashlib, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
expected = re.search(r'\b[0-9a-fA-F]{64}\b', pathlib.Path(str(p)+'.sha256').read_text()).group().lower()
h = hashlib.sha256()
with p.open('rb') as f:
    for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
assert h.hexdigest() == expected, 'Hive checksum mismatch'
print('Hive SHA256 OK:', expected)
PY
if [[ ! -d /opt/apache-hive-${VERSION}-bin ]]; then
  tar -xzf "$ARCHIVE" -C /opt
fi
if [[ -e /opt/hive && ! -L /opt/hive ]]; then echo '/opt/hive already exists and is not a symlink'; exit 1; fi
ln -sfn /opt/apache-hive-${VERSION}-bin /opt/hive
install -m 0644 /usr/share/java/postgresql.jar /opt/hive/lib/postgresql.jar
install -d -o root -g hive -m 0750 /etc/hive
install -d -o root -g hive -m 0750 /etc/hive/hadoop
cp /etc/hadoop-yarn/*.xml /etc/hive/hadoop/
cp /etc/hadoop-yarn/log4j.properties /etc/hive/hadoop/
install -d -o hive -g hive -m 0750 /var/log/hive /var/lib/hive/tmp
if [[ ! -f /etc/hive/metastore.password ]]; then
  python3 -c 'import secrets; print(secrets.token_hex(24))' > /etc/hive/metastore.password
fi
chown root:root /etc/hive/metastore.password
chmod 0600 /etc/hive/metastore.password
DB_PASSWORD=$(cat /etc/hive/metastore.password)
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='hive'" | grep -q 1; then
  printf "CREATE ROLE hive LOGIN PASSWORD '%s';\n" "$DB_PASSWORD" | runuser -u postgres -- psql -v ON_ERROR_STOP=1
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='hive_metastore'" | grep -q 1; then
  runuser -u postgres -- createdb -O hive hive_metastore
fi
python3 <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
password=Path('/etc/hive/metastore.password').read_text().strip()
shared={
'hive.metastore.uris':'thrift://127.0.0.1:9083',
'hive.metastore.warehouse.dir':'/user/hive/warehouse',
'hive.metastore.warehouse.external.dir':'/user/hive/warehouse-external',
'hive.exec.scratchdir':'/tmp/hive',
'hive.exec.local.scratchdir':'/var/lib/hive/tmp',
'hive.execution.engine':'mr',
'yarn.app.mapreduce.am.staging-dir':'/user/hive/staging',
'hive.aux.jars.path':'file:///opt/hive/lib/commons-collections-3.2.2.jar',
'hive.server2.thrift.bind.host':'127.0.0.1',
'hive.server2.thrift.port':'10000',
'hive.server2.webui.host':'127.0.0.1',
'hive.server2.webui.port':'10002',
'hive.server2.enable.doAs':'false',
'hive.server2.authentication':'NONE',
'hive.server2.support.dynamic.service.discovery':'false',
'hive.metastore.schema.verification':'true',
'datanucleus.schema.autoCreateAll':'false',
}
db={
'javax.jdo.option.ConnectionURL':'jdbc:postgresql://127.0.0.1:5432/hive_metastore',
'javax.jdo.option.ConnectionDriverName':'org.postgresql.Driver',
'javax.jdo.option.ConnectionUserName':'hive',
'javax.jdo.option.ConnectionPassword':password,
'hive.metastore.thrift.bind.host':'127.0.0.1',
}
for name, props in [('hive-site.xml',shared),('hivemetastore-site.xml',db)]:
    root=ET.Element('configuration')
    for key,value in props.items():
        prop=ET.SubElement(root,'property')
        ET.SubElement(prop,'name').text=key
        ET.SubElement(prop,'value').text=value
    ET.indent(root)
    ET.ElementTree(root).write('/etc/hive/'+name,encoding='utf-8',xml_declaration=True)
tree=ET.parse('/etc/hive/hadoop/core-site.xml')
root=tree.getroot()
for key,value in {'hadoop.proxyuser.hive.hosts':'127.0.0.1','hadoop.proxyuser.hive.groups':'hive'}.items():
    for prop in list(root):
        if prop.findtext('name') == key: root.remove(prop)
    prop=ET.SubElement(root,'property')
    ET.SubElement(prop,'name').text=key
    ET.SubElement(prop,'value').text=value
ET.indent(root)
tree.write('/etc/hive/hadoop/core-site.xml',encoding='utf-8',xml_declaration=True)
PY
chown root:hive /etc/hive/*site.xml
chmod 0640 /etc/hive/*site.xml
cat > /etc/hive/hive-env.sh <<EOF
export JAVA_HOME=$JAVA
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=/etc/hive/hadoop
export HADOOP_HEAPSIZE=512
export HIVE_LOG_DIR=/var/log/hive
EOF
chmod 0644 /etc/hive/hive-env.sh
cp /opt/hive/conf/hive-log4j2.properties.template /etc/hive/hive-log4j2.properties
sed -i 's|^property.hive.log.dir = .*|property.hive.log.dir = /var/log/hive|' /etc/hive/hive-log4j2.properties
runuser -u hadoop -- env JAVA_HOME="$JAVA" HADOOP_CONF_DIR=/etc/hadoop-yarn /opt/hadoop/bin/hdfs dfs -mkdir -p /user/hive/warehouse /user/hive/warehouse-external /tmp/hive /user/hive
runuser -u hadoop -- env HADOOP_CONF_DIR=/etc/hadoop-yarn /opt/hadoop/bin/hdfs dfs -chown -R hive /user/hive /tmp/hive
runuser -u hadoop -- env HADOOP_CONF_DIR=/etc/hadoop-yarn /opt/hadoop/bin/hdfs dfs -chmod 1777 /tmp/hive
HIVE_ENV=(JAVA_HOME="$JAVA" HADOOP_HOME=/opt/hadoop HADOOP_CONF_DIR=/etc/hive/hadoop HIVE_HOME=/opt/hive HIVE_CONF_DIR=/etc/hive HADOOP_HEAPSIZE=512)
if ! runuser -u hive -- env "${HIVE_ENV[@]}" /opt/hive/bin/schematool -dbType postgres -info; then
  # Создаём схему только в пустой БД. Если там уже есть таблицы, сначала разбираемся с ошибкой.
  TABLES=$(runuser -u postgres -- psql -d hive_metastore -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
  [[ $TABLES -eq 0 ]] || { echo 'Metastore database is not empty; inspect schema before retry'; exit 1; }
  runuser -u hive -- env "${HIVE_ENV[@]}" /opt/hive/bin/schematool -dbType postgres -initSchema
fi
for SERVICE in metastore hiveserver2; do
  cat > "/etc/systemd/system/hive-${SERVICE}.service" <<EOF
[Unit]
Description=Apache Hive ${SERVICE}
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
User=hive
Group=hive
Environment=JAVA_HOME=$JAVA
Environment=HADOOP_HOME=/opt/hadoop
Environment=HADOOP_CONF_DIR=/etc/hive/hadoop
Environment=HIVE_HOME=/opt/hive
Environment=HIVE_CONF_DIR=/etc/hive
Environment=HADOOP_HEAPSIZE=512
Environment=HIVE_LOG_DIR=/var/log/hive
WorkingDirectory=/var/lib/hive
ExecStart=/opt/hive/bin/hive --service ${SERVICE}
Restart=on-failure
RestartSec=10
UMask=0027
StandardOutput=append:/var/log/hive/${SERVICE}.log
StandardError=inherit
[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
systemctl enable --now hive-metastore
python3 - <<'PY'
import socket,time
for i in range(90):
    try:
        with socket.create_connection(('127.0.0.1',9083),2): break
    except OSError: time.sleep(2)
else: raise SystemExit('Metastore did not open port 9083; check /var/log/hive/metastore.log')
PY
systemctl enable --now hive-hiveserver2
python3 - <<'PY'
import socket,time
for i in range(120):
    try:
        with socket.create_connection(('127.0.0.1',10000),2): break
    except OSError: time.sleep(2)
else: raise SystemExit('HiveServer2 did not open port 10000; check /var/log/hive/hiveserver2.log')
PY
runuser -u hive -- env "${HIVE_ENV[@]}" /opt/hive/bin/beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive -e 'SHOW DATABASES; SELECT 1;'
