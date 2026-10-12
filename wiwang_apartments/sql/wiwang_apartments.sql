-- Created automatically on first start as well; run manually if your DB user may not CREATE TABLE.
CREATE TABLE IF NOT EXISTS `wiwang_apartments` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `room` VARCHAR(20) NOT NULL,            -- e.g. wiwang_03_12 (floor 3, room 12)
  `floor` TINYINT UNSIGNED NOT NULL,
  `number` TINYINT UNSIGNED NOT NULL,
  `label` VARCHAR(32) NOT NULL,           -- e.g. Room 312
  `citizenid` VARCHAR(50) NOT NULL,
  `keys` LONGTEXT NULL,                   -- JSON array of citizenids with a key
  `furniture` LONGTEXT NULL,              -- JSON array of props (NULL = Wiwang.DefaultFurniture)
  `locked` TINYINT(1) NOT NULL DEFAULT 1,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `room` (`room`),
  UNIQUE KEY `citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
