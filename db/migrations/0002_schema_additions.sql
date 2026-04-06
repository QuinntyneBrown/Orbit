-- Migration 0002: Schema additions for Features 04–13
-- NOTE: Most columns referenced here already exist in the initial schema (0001).
-- This migration adds the columns that were NOT in 0001, and marks version 2 as applied.
-- It is safe to re-run because all ALTER TABLE statements are guarded by the migration
-- version check in Initialize-OrbitDb.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- Feature 04: offer_evaluations — legacy numeric dimension columns used by Invoke-OfferEvaluation.ps1
-- (dim_* are placeholder floats stored alongside the letter-grade columns)
ALTER TABLE offer_evaluations ADD COLUMN dim_technical    REAL NOT NULL DEFAULT 0.0;
ALTER TABLE offer_evaluations ADD COLUMN dim_seniority    REAL NOT NULL DEFAULT 0.0;
ALTER TABLE offer_evaluations ADD COLUMN dim_archetype_fit REAL NOT NULL DEFAULT 0.0;
ALTER TABLE offer_evaluations ADD COLUMN dim_compensation REAL NOT NULL DEFAULT 0.0;
ALTER TABLE offer_evaluations ADD COLUMN dim_market_demand REAL NOT NULL DEFAULT 0.0;

-- Feature 09: outreach_records — add type column for linkedin-message / email / follow-up
ALTER TABLE outreach_records ADD COLUMN type TEXT NOT NULL DEFAULT 'linkedin-message'
    CHECK(type IN ('linkedin-message','email','follow-up'));

-- Feature 11: target_accounts — add company alias and priority column
-- (existing 'name' column is the company name; 'company' is added as an alias for scripting convenience)
ALTER TABLE target_accounts ADD COLUMN company  TEXT;
ALTER TABLE target_accounts ADD COLUMN priority TEXT NOT NULL DEFAULT 'Medium'
    CHECK(priority IN ('High','Medium','Low'));

-- Feature 06: compensation_estimates — add estimated_at alias for Invoke-CompensationResearch.psm1
-- (existing researched_date covers this; estimated_at is added for the ON CONFLICT upsert)
ALTER TABLE compensation_estimates ADD COLUMN estimated_at TEXT NOT NULL DEFAULT (datetime('now'));

INSERT OR IGNORE INTO schema_migrations(version) VALUES (2);
