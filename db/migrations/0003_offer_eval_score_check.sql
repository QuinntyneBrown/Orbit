-- Migration 0003: Add L2-009 AC3 score-to-action CHECK constraint to offer_evaluations
-- SQLite does not support ALTER TABLE ADD CHECK; the table must be recreated.
-- The constraint enforces that any score below 3.0 must have recommended_action = 'Skip'.

PRAGMA foreign_keys = OFF;

-- Step 1: rename existing table so we can create the new one with the correct name
--         (self-referential FK superseded_by must reference 'offer_evaluations', not a temp name)
ALTER TABLE offer_evaluations RENAME TO offer_evaluations_old;

-- Step 2: create the table with all original constraints plus the new cross-column CHECK
CREATE TABLE offer_evaluations (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    company               TEXT    NOT NULL,
    role                  TEXT    NOT NULL,
    eval_date             TEXT    NOT NULL,
    technical_match       TEXT    NOT NULL CHECK (technical_match       IN ('A','B','C','Skip')),
    seniority_alignment   TEXT    NOT NULL CHECK (seniority_alignment   IN ('A','B','C','Skip')),
    archetype_fit         TEXT    NOT NULL CHECK (archetype_fit         IN ('A','B','C','Skip')),
    compensation_fairness TEXT    NOT NULL CHECK (compensation_fairness IN ('A','B','C','Skip')),
    market_demand         TEXT    NOT NULL CHECK (market_demand         IN ('A','B','C','Skip')),
    dim_technical         REAL    NOT NULL DEFAULT 0.0,
    dim_seniority         REAL    NOT NULL DEFAULT 0.0,
    dim_archetype_fit     REAL    NOT NULL DEFAULT 0.0,
    dim_compensation      REAL    NOT NULL DEFAULT 0.0,
    dim_market_demand     REAL    NOT NULL DEFAULT 0.0,
    score                 REAL    NOT NULL CHECK (score >= 0.0 AND score <= 5.0),
    label                 TEXT    NOT NULL CHECK (label IN ('Priority', 'Viable', 'Low Fit')),
    recommended_action    TEXT    NOT NULL CHECK (recommended_action IN ('Tailor', 'Watch', 'Skip')),
    notes                 TEXT,
    version               INTEGER NOT NULL DEFAULT 1,
    superseded_by         INTEGER REFERENCES offer_evaluations (id),
    evaluated_at          TEXT    NOT NULL DEFAULT (datetime('now')),
    created_at            TEXT    NOT NULL DEFAULT (datetime('now')),
    -- L2-009 AC3: scores below 3.0 must result in Skip at the database layer
    CHECK (score >= 3.0 OR recommended_action = 'Skip')
);

-- Step 3: copy all existing rows; explicit column list guards against column-order assumptions
INSERT INTO offer_evaluations
    SELECT id, company, role, eval_date,
           technical_match, seniority_alignment, archetype_fit,
           compensation_fairness, market_demand,
           dim_technical, dim_seniority, dim_archetype_fit, dim_compensation, dim_market_demand,
           score, label, recommended_action,
           notes, version, superseded_by, evaluated_at, created_at
    FROM offer_evaluations_old;

-- Step 4: drop the old table and recreate the index
DROP TABLE offer_evaluations_old;
CREATE INDEX IF NOT EXISTS idx_eval_company_role ON offer_evaluations (company, role);

PRAGMA foreign_keys = ON;

INSERT OR IGNORE INTO schema_migrations (version) VALUES (3);
