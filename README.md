# ДЗ №3 — Apache Hive: развёртывание

Автоматизированное развёртывание Apache Hive для нескольких клиентов: отдельные HiveServer2, Metastore и PostgreSQL, партиционированная таблица в HDFS и скрипт повторяемой загрузки данных.

Репозиторий: https://github.com/zarmeux/hw3-hive

## Быстрый запуск

На управляющей машине с существующим кластером Hadoop, конфигурацией `/etc/hadoop-yarn`, Java 11 и пользователем `hadoop`, имеющим административный доступ к HDFS:

```bash
git clone https://github.com/zarmeux/hw3-hive.git
cd hw3-hive
mkdir -p evidence
set -o pipefail
sudo bash scripts/install.sh 2>&1 | tee evidence/install.log
sudo bash scripts/demo.sh 2>&1 | tee evidence/demo.log
```

Предполагается размещение проекта в `~/hw3-hive`. Кластер должен иметь корректную собственную конфигурацию в `/etc/hadoop-yarn`; установка HDFS/YARN относится к предыдущим работам. Для установки требуется `sudo`, доступ к репозиториям Ubuntu и архиву Apache, около 2 ГБ свободного места и порядка 2 ГБ доступной памяти на управляющей машине.

## Окружение

- Управляющая машина: Ubuntu 24.04, 4 ГБ RAM.
- Java: OpenJDK 11; Hadoop: 3.4.2, установлен в `/opt/hadoop`.
- Конфигурация действующего кластера: `/etc/hadoop-yarn`.
- Адрес HDFS NameNode берётся из существующего `core-site.xml`.
- Адрес YARN ResourceManager берётся из существующего `yarn-site.xml`; проверено с тремя рабочими узлами.
- Hive: `4.0.0-alpha-2`, официальный архив Apache, проверка SHA256.
- PostgreSQL: пакет Ubuntu; JDBC-драйвер из `libpostgresql-jdbc-java`.

Скрипт использует существующий MapReduce/YARN. Для выполнения старой версии Hive с Hadoop 3.4.2 библиотека `commons-collections-3.2.2.jar` из дистрибутива Hive передаётся контейнерам через `hive.aux.jars.path`. Рабочий каталог MapReduce для Hive — `/user/hive/staging`, задан через `yarn.app.mapreduce.am.staging-dir`; закрытый каталог пользователя `yarn` не используется.

## Архитектура

```text
Beeline client 1 ─┐
                 ├─ HiveServer2 (127.0.0.1:10000)
Beeline client 2 ─┘          │
                            ├─ отдельный Metastore (127.0.0.1:9083)
                            │           └─ PostgreSQL / hive_metastore
                            └─ существующие HDFS и YARN
```

Metastore и HiveServer2 работают отдельными процессами под пользователем `hive`. `hive.metastore.uris` задан явно; embedded Derby не используется. PostgreSQL хранит метаданные, HDFS — данные таблиц. Каталоги: `/user/hive/warehouse`, `/user/hive/warehouse-external`, `/tmp/hive`.

Для служебного API уведомлений Metastore задано `hadoop.proxyuser.hive.hosts=127.0.0.1` и `hadoop.proxyuser.hive.groups=hive` в отдельной копии Hadoop-конфигурации `/etc/hive/hadoop/core-site.xml`. Hive использует `HADOOP_CONF_DIR=/etc/hive/hadoop`. Конфигурация действующего Hadoop-кластера не меняется. Проверка доступа к API уведомлений остаётся включённой. Отдельный core-site.xml нужен, чтобы правила были доступны при ранней инициализации ProxyUsers в Hadoop 3.4.2.

Сервисы Hive слушают loopback. Подключение извне выполняется через SSH-туннель. Учебная конфигурация использует `authentication=NONE` и `doAs=false`: запросы обоих клиентов выполняются от сервисного пользователя `hive`; это не разграничение доступа между пользователями.

## Установка

На управляющей машине, где уже доступен работающий кластер:

```bash
cd ~/hw3-hive
mkdir -p evidence
set -o pipefail
sudo bash scripts/install.sh 2>&1 | tee evidence/install.log
```

Скрипт устанавливает PostgreSQL и Hive, проверяет архив, создаёт пользователя и конфигурацию, инициализирует пустую БД Metastore, создаёт каталоги HDFS и службы systemd, ожидает порты и выполняет запросы через Beeline. Существующие конфигурации Hadoop не изменяются.

Пароль БД генерируется на сервере и хранится в `/etc/hive/metastore.password` с правами `0600`; конфигурация с паролем — `/etc/hive/hivemetastore-site.xml`, доступна root и группе hive. Эти файлы нельзя включать в публичный репозиторий. При повторном запуске пароль сохраняется; непустая БД с ошибкой схемы требует ручной диагностики. Повторная установка не перезапускает уже работающие службы автоматически после изменения конфигурации.

## Проверка

```bash
cd ~/hw3-hive
sudo -u hive bash scripts/check.sh 2>&1 | tee evidence/check.log
sudo systemctl status hive-metastore hive-hiveserver2 --no-pager
sudo ss -lntp | grep -E ':(9083|10000|10002)\b'
```

Проверка запускает два клиента Beeline параллельно. Каждый выполняет `SHOW DATABASES` и `SELECT 1`; ожидается успешное завершение обоих. Это проверка нескольких подключений, а не нагрузочный тест.

Логи: `/var/log/hive/metastore.log`, `/var/log/hive/hiveserver2.log`, `/var/log/hive/hive.log`; также `journalctl -u hive-metastore -u hive-hiveserver2`.

## Подключение с компьютера

```bash
ssh -N -L 10000:127.0.0.1:10000 USER@SSH_HOST
```

В другом терминале с установленным Beeline:

```bash
beeline -u jdbc:hive2://127.0.0.1:10000/default -n hive
```

Или выполнить Beeline непосредственно на сервере через `sudo -u hive` с переменными окружения из `scripts/check.sh`.

## Таблица и автоматизированная загрузка

Таблица `hw3.events` — внешняя таблица TEXTFILE в HDFS, с колонками `event_id BIGINT`, `user_id BIGINT`, `event_type STRING` и партицией `event_date STRING`. SQL находится в `sql/create-events.sql`; данные — в `/user/hive/warehouse-external/hw3/events/event_date=YYYY-MM-DD/`.

Создание базы и таблицы, затем загрузка демонстрационных файлов:

```bash
cd ~/hw3-hive
sudo bash scripts/create-table.sh
sudo bash scripts/load-partition.sh data/events-2026-10-20.csv 2026-10-20
sudo bash scripts/load-partition.sh data/events-2026-10-21.csv 2026-10-21
sudo bash scripts/run-sql.sh sql/inspect-events.sql
```

Формат CSV: без заголовка, по три значения в строке, например `1,101,page_view`. Идентификаторы — неотрицательные BIGINT, тип события — латинские буквы, цифры и подчёркивания, начинается с буквы. Кавычки, запятые внутри поля и пустые файлы этот учебный загрузчик не поддерживает. Дата передаётся отдельно; в CSV её нет.

`load-partition.sh` проверяет дату и строки CSV, копирует файл в отдельный временный каталог HDFS и выполняет `LOAD DATA INPATH ... OVERWRITE INTO TABLE hw3.events PARTITION (event_date='...')` через HiveServer2. Партиция регистрируется автоматически. Временные файлы очищаются; исходный CSV сохраняется. Локальная блокировка сериализует запуски этого скрипта для одной даты на управляющей машине.

Каждая загрузка **заменяет всё содержимое выбранной партиции**. Файл должен содержать полный набор событий за эту дату. Другие даты остаются без изменений; повторный запуск с тем же файлом даёт тот же результат. Загрузка не является транзакционной гарантией для конкурентных читателей и сторонних загрузчиков.

Повторная загрузка первой даты:

```bash
sudo bash scripts/load-partition.sh data/events-2026-10-20.csv 2026-10-20
sudo bash scripts/run-sql.sh sql/inspect-events.sql
```

Ожидаемый результат: две партиции, 3 строки за `2026-10-20` и 2 строки за `2026-10-21`, всего 5 строк. `scripts/run-sql.sh` запускает произвольный локальный SQL-файл от сервисного пользователя `hive` через Beeline. При повторном создании таблицы `IF NOT EXISTS` сохраняет существующую таблицу; изменение её схемы требует отдельной миграции.

Синтаксис загрузки: [официальная документация Hive DML](https://hive.apache.org/docs/latest/language/languagemanual-dml/).

## Распределённый запрос и полная демонстрация

```bash
sudo bash scripts/check-yarn.sh
```

Скрипт выполняет `sql/check-yarn.sql`: группировку событий по датам с `COUNT(*)`. В сессии отключены FetchTask и получение ответа из статистики; выбран движок `mr`. Затем скрипт проверяет результаты `3` и `2`, наличие mapper/reducer, тип приложения `MAPREDUCE` и его итоговый статус `SUCCEEDED` через YARN CLI. Логи сохраняются в `evidence/yarn-query.log` и `evidence/yarn-application.log`.

Полный сценарий после установки:

```bash
sudo bash scripts/demo.sh
```

Он создаёт таблицу, загружает две даты, повторяет загрузку первой, проверяет двух клиентов и запускает распределённую агрегацию. Этот сценарий перезаписывает две демонстрационные партиции. Проверки относятся к небольшому демонстрационному набору, без нагрузочного тестирования.

## Результат проверки 22 октября 2026

- Установка завершилась с кодом `0`; Hive и схема Metastore имеют версию `4.0.0-alpha-2`.
- Службы Metastore и HiveServer2 активны, включён запуск после загрузки ОС.
- Порты `9083`, `10000`, `10002` привязаны к `127.0.0.1`.
- `scripts/check.sh` завершился с кодом `0`: оба клиента получили базу `default` и результат `SELECT 1`.
- В журнале HiveServer2 зафиксировано `current sessions:2`, то есть сессии действительно пересекались во времени.
- HDFS доступен; YARN показывает три узла в состоянии `RUNNING`.
- Полные диагностические логи сохраняются локально и исключены из Git. Публичный отчёт — [evidence/RESULTS.md](evidence/RESULTS.md). Обычные выборки строк используют FetchTask; `check-yarn.sql` принудительно запускает распределённую задачу.

### Проверка таблицы и загрузки

Созданы две партиции и загружено 5 событий. Полная выборка до и после повторной загрузки `2026-10-20` совпала с исходными CSV:

| Партиция | До повторной загрузки | После повторной загрузки |
| --- | ---: | ---: |
| `2026-10-20` | 3 | 3 |
| `2026-10-21` | 2 | 2 |
| Всего | 5 | 5 |

Проверено равенство всех полей всех строк, а не только количества. Дубли не появились, вторая партиция сохранилась.

Загрузки и проверка повторного запуска выполнены на сервере. Логи хранятся локально; команды воспроизведения приведены выше.

### Проверка полного сценария и YARN

`sudo bash scripts/demo.sh` завершился с кодом `0`. Повторная загрузка сохранила ожидаемые 3 и 2 события; два клиента Beeline успешно выполнили запросы. Распределённая агрегация: тип `MAPREDUCE`, один mapper и один reducer, `Final-State: SUCCEEDED`. Результат — `2026-10-20: 3`, `2026-10-21: 2`.

`scripts/demo.sh` и `scripts/check-yarn.sh` сохраняют подробные журналы для проверки на сервере. Они не публикуются, поскольку могут содержать инфраструктурные данные.

Документация: [Hive configuration](https://hive.apache.org/docs/latest/admin/adminmanual-configuration/), [Hive Schema Tool](https://hive.apache.org/docs/latest/admin/hive-schema-tool/), [архив версии](https://archive.apache.org/dist/hive/hive-4.0.0-alpha-2/).
