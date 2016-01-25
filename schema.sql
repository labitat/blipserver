CREATE TABLE readings (
	stamp BIGINT PRIMARY KEY,
	ms INTEGER NOT NULL
);

CREATE TABLE readings_minutely (
       stamp BIGINT PRIMARY KEY,
       events INTEGER NOT NULL,
       sum_ms INTEGER NOT NULL,
       min_ms INTEGER NOT NULL,
       max_ms INTEGER NOT NULL
);

CREATE TABLE readings_hourly (
       stamp BIGINT PRIMARY KEY,
       events INTEGER NOT NULL,
       sum_ms INTEGER NOT NULL,
       min_ms INTEGER NOT NULL,
       max_ms INTEGER NOT NULL
);

CREATE TABLE device_history (
  id INTEGER NOT NULL,
  stamp BIGINT NOT NULL,
  active BOOLEAN NOT NULL,
  description VARCHAR(140),
  unit VARCHAR(20),
  poll_interval INTEGER,
  PRIMARY KEY (id, stamp)
);

CREATE VIEW device_status_find_newest AS
SELECT id AS max_id, MAX(stamp) AS max_stamp
  FROM device_history AS dh1
 GROUP BY id;

CREATE VIEW device_status AS
SELECT id, stamp, active, description, unit, poll_interval
  FROM device_status_find_newest
 INNER JOIN device_history AS dh2
    ON (max_id = id AND max_stamp = stamp);

CREATE VIEW device_last_active_status_newest_active AS
SELECT id AS max_active_id, MAX(stamp) AS max_active_stamp
  FROM device_history AS dh1
 WHERE active = TRUE
 GROUP BY id;

CREATE VIEW device_last_active_status AS
SELECT max_active_id AS id, active_history.stamp, newest_history.active, active_history.description, active_history.unit, active_history.poll_interval
  FROM device_last_active_status_newest_active
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

