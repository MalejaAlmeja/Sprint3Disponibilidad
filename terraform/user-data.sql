CREATE DATABASE IF NOT EXISTS wms;
USE wms;

CREATE TABLE IF NOT EXISTS inventory (
  sku           VARCHAR(64) PRIMARY KEY,
  available_qty INT NOT NULL,
  version       BIGINT NOT NULL,
  updated_at    DATETIME(6) NOT NULL
);

INSERT INTO inventory (sku, available_qty, version, updated_at) VALUES
  ('ABC-123', 100, 1, NOW(6))
ON DUPLICATE KEY UPDATE available_qty=VALUES(available_qty);