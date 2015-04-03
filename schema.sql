CREATE TABLE readings (
	stamp BIGINT PRIMARY KEY,
	ms INTEGER NOT NULL
);

CREATE TABLE readings_hourly (
       stamp BIGINT PRIMARY KEY,
       events INTEGER NOT NULL,
       sum_ms INTEGER NOT NULL,
       min_ms INTEGER NOT NULL,
       max_ms INTEGER NOT NULL
);

CREATE OR REPLACE FUNCTION do_monthly_aggregate() RETURNS trigger AS
$BODY$
DECLARE
  as_date TIMESTAMP WITH TIME ZONE;
  hour BIGINT;
BEGIN
  as_date := TIMESTAMP WITH TIME ZONE 'epoch' + trunc(NEW.stamp/1000) * INTERVAL '1 second';
  hour := 1000::BIGINT * extract(epoch from date_trunc('hour', as_date));
  INSERT INTO readings_hourly (stamp, events, sum_ms, min_ms, max_ms)
  SELECT hour, 0, 0, NEW.ms, NEW.ms
   WHERE NOT EXISTS (SELECT 1 FROM readings_hourly R WHERE R.stamp=hour);
  UPDATE readings_hourly
     SET events = events + 1,
         sum_ms = sum_ms + NEW.ms,
         min_ms = LEAST(min_ms, NEW.ms),
         max_ms = GREATEST(max_ms, NEW.ms)
   WHERE stamp = hour;
  RETURN NEW;
END;
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100;

CREATE TRIGGER monthly_aggregate AFTER INSERT
    ON readings
   FOR EACH ROW
EXECUTE PROCEDURE do_monthly_aggregate();

CREATE OR REPLACE VIEW usage_hourly AS
SELECT stamp, 3600000.0::DOUBLE PRECISION * events / sum_ms AS wh, min_ms, max_ms, events
  FROM readings_hourly;


CREATE TABLE device_history (
  id INTEGER NOT NULL,
  stamp BIGINT NOT NULL,
  active BOOLEAN NOT NULL,
  description VARCHAR(140),
  unit VARCHAR(20),
  poll_interval INTEGER,
  PRIMARY KEY (id, stamp)
);

CREATE VIEW device_status AS
SELECT id, stamp, active, description, unit, poll_interval
  FROM (SELECT id AS max_id, MAX(stamp) AS max_stamp
          FROM device_history AS dh1
         GROUP BY id) find_newest
 INNER JOIN device_history AS dh2
    ON (max_id = id AND max_stamp = stamp);

CREATE VIEW device_last_active_status AS
SELECT max_active_id AS id, active_history.stamp, newest_history.active, active_history.description, active_history.unit, active_history.poll_interval
  FROM (SELECT id AS max_active_id, MAX(stamp) AS max_active_stamp
          FROM device_history AS dh1
         WHERE active = TRUE
         GROUP BY id) newest_active
 INNER JOIN device_history AS active_history
    ON (max_active_id = active_history.id
    AND max_active_stamp = active_history.stamp)
 INNER JOIN device_history AS newest_history
    ON (newest_history.id = max_active_id
    AND newest_history.stamp = (SELECT MAX(stamp)
                                  FROM device_history AS dh3
                                 WHERE dh3.id = max_active_id));

CREATE TABLE device_log (
  id INTEGER NOT NULL,
  stamp BIGINT NOT NULL,
  value FLOAT(24) NOT NULL,
  PRIMARY KEY (id, stamp));

CREATE VIEW device_log_full AS
SELECT L.id, L.stamp, L.value, H.description, H.unit
  FROM device_log L
  LEFT JOIN device_history H
    ON (L.id = H.id
    AND H.stamp = (SELECT MAX(H2.stamp)
                     FROM device_history H2
                    WHERE H2.id = L.id
                      AND L.stamp >= H2.stamp
                      AND H2.active = TRUE));

