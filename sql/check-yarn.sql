SET hive.execution.engine=mr;
SET hive.fetch.task.conversion=none;
SET hive.compute.query.using.stats=false;
SELECT event_date, COUNT(*) AS event_count
FROM hw3.events
GROUP BY event_date;
