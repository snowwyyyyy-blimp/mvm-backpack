-- MvM Backpack schema (SQLite, created automatically by the plugin on first load).
-- Kept here for reference / manual inspection.

CREATE TABLE IF NOT EXISTS mvm_backpack (
    steamid     CHAR(32)      NOT NULL,          -- SteamID3 (e.g. [U:1:123456])
    item_key    CHAR(32)      NOT NULL,          -- key from mvm_rewards.cfg
    item_name   VARCHAR(96)   NOT NULL,          -- display name
    item_class  VARCHAR(32)   NOT NULL,          -- tf2 classname
    item_index  INT           NOT NULL,          -- defindex (e.g. 169 = Golden Wrench)
    quality     INT           NOT NULL,          -- TF2 quality (11 = Strange)
    pool        INT           NOT NULL,          -- 0 = australium, 1 = golden
    got_at      INT           NOT NULL,          -- unix ts when earned
    claimed_at  INT           NULL,              -- unix ts when claimed in-game (NULL = not yet)
    PRIMARY KEY (steamid, item_key)
);

CREATE INDEX IF NOT EXISTS idx_mvm_backpack_steamid ON mvm_backpack(steamid);