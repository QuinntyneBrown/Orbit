-- Migration 0001: Initial schema
-- Creates all tables defined in db/schema.sql.
-- Applied automatically on first run by the startup validator.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version     INTEGER PRIMARY KEY,
    applied_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS pipeline_entries (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    seq_no       INTEGER NOT NULL UNIQUE,
    applied_date TEXT    NOT NULL,
    company      TEXT    NOT NULL,
    role         TEXT    NOT NULL,
    source       TEXT    NOT NULL,
    status       TEXT    NOT NULL CHECK (status IN (
                     'Evaluated', 'Applied', 'Responded',
                     'Interview', 'Offer', 'Rejected', 'Discarded', 'SKIP'
                 )),
    rate         TEXT,
    pdf_path     TEXT,
    eval_id      INTEGER REFERENCES offer_evaluations (id),
    notes        TEXT,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_pipeline_status  ON pipeline_entries (status);
CREATE INDEX IF NOT EXISTS idx_pipeline_company ON pipeline_entries (company, role);

CREATE TABLE IF NOT EXISTS offer_evaluations (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    company               TEXT NOT NULL,
    role                  TEXT NOT NULL,
    eval_date             TEXT NOT NULL,
    technical_match       TEXT NOT NULL CHECK (technical_match       IN ('A','B','C','Skip')),
    seniority_alignment   TEXT NOT NULL CHECK (seniority_alignment   IN ('A','B','C','Skip')),
    archetype_fit         TEXT NOT NULL CHECK (archetype_fit         IN ('A','B','C','Skip')),
    compensation_fairness TEXT NOT NULL CHECK (compensation_fairness IN ('A','B','C','Skip')),
    market_demand         TEXT NOT NULL CHECK (market_demand         IN ('A','B','C','Skip')),
    score                 REAL NOT NULL CHECK (score >= 0.0 AND score <= 5.0),
    label                 TEXT NOT NULL CHECK (label IN ('Priority', 'Viable', 'Low Fit')),
    recommended_action    TEXT NOT NULL CHECK (recommended_action IN ('Tailor', 'Watch', 'Skip')),
    notes                 TEXT,
    version               INTEGER NOT NULL DEFAULT 1,
    superseded_by         INTEGER REFERENCES offer_evaluations (id),
    evaluated_at          TEXT NOT NULL DEFAULT (datetime('now')),
    created_at            TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_eval_company_role ON offer_evaluations (company, role);

CREATE TABLE IF NOT EXISTS scan_runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    run_date         TEXT NOT NULL,
    total_results    INTEGER NOT NULL DEFAULT 0,
    new_listings     INTEGER NOT NULL DEFAULT 0,
    seen_listings    INTEGER NOT NULL DEFAULT 0,
    boards_searched  TEXT,
    keywords         TEXT,
    notes            TEXT,
    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS job_listings (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_run_id           INTEGER REFERENCES scan_runs (id),
    title                 TEXT NOT NULL,
    company               TEXT NOT NULL,
    source                TEXT NOT NULL,
    posted_date           TEXT,
    rate                  TEXT,
    url                   TEXT,
    ats_type              TEXT,
    archetype             TEXT NOT NULL DEFAULT 'Enterprise Contract' CHECK (archetype IN (
                              'Enterprise Contract', 'Product Company',
                              'Consulting Firm', 'AI / Innovation',
                              'Government / Public Sector'
                          )),
    archetype_inferred    INTEGER NOT NULL DEFAULT 1 CHECK (archetype_inferred IN (0,1)),
    auto_score            REAL,
    is_stale              INTEGER NOT NULL DEFAULT 0 CHECK (is_stale IN (0,1)),
    is_priority_recruiter INTEGER NOT NULL DEFAULT 0 CHECK (is_priority_recruiter IN (0,1)),
    status                TEXT NOT NULL DEFAULT 'New' CHECK (status IN ('New', 'Seen', 'Applied', 'Archived')),
    first_seen_date       TEXT NOT NULL,
    last_seen_date        TEXT NOT NULL,
    UNIQUE (company, title)
);

CREATE INDEX IF NOT EXISTS idx_listings_scan_run ON job_listings (scan_run_id);
CREATE INDEX IF NOT EXISTS idx_listings_status   ON job_listings (status);

CREATE TABLE IF NOT EXISTS compensation_estimates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    listing_id      INTEGER NOT NULL UNIQUE REFERENCES job_listings (id),
    range_low       REAL,
    range_high      REAL,
    currency        TEXT NOT NULL DEFAULT 'CAD',
    unit            TEXT NOT NULL DEFAULT 'hr' CHECK (unit IN ('hr', 'yr')),
    confidence      TEXT CHECK (confidence IN ('High', 'Medium', 'Low')),
    source          TEXT NOT NULL,
    researched_date TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS recruiter_contacts (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    firm_name            TEXT NOT NULL UNIQUE,
    contact_name         TEXT,
    contact_linkedin     TEXT,
    priority_tier        TEXT NOT NULL DEFAULT 'Medium' CHECK (priority_tier IN ('High', 'Medium', 'Low')),
    opportunity_page_url TEXT,
    last_contacted_date  TEXT,
    engagement_status    TEXT NOT NULL DEFAULT 'Active' CHECK (engagement_status IN ('Active', 'Passive', 'Dormant', 'Closed')),
    notes                TEXT,
    created_at           TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at           TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS target_accounts (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    name                 TEXT NOT NULL UNIQUE,
    career_page_url      TEXT,
    ats_type             TEXT CHECK (ats_type IN (
                             'Greenhouse', 'Ashby', 'Lever', 'Wellfound', 'Workable', NULL
                         )),
    priority             TEXT NOT NULL DEFAULT 'Medium' CHECK (priority IN ('High', 'Medium', 'Low')),
    recruiter_contact_id INTEGER REFERENCES recruiter_contacts (id),
    notes                TEXT,
    created_at           TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS interview_stories (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    title      TEXT NOT NULL,
    context    TEXT NOT NULL,
    situation  TEXT NOT NULL,
    task       TEXT NOT NULL,
    action     TEXT NOT NULL,
    result     TEXT NOT NULL,
    reflection TEXT NOT NULL,
    skills     TEXT NOT NULL DEFAULT '[]',
    keywords   TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS outreach_records (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    listing_id INTEGER REFERENCES job_listings (id),
    company    TEXT NOT NULL,
    role       TEXT NOT NULL,
    file_path  TEXT NOT NULL,
    version    INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_outreach_listing ON outreach_records (listing_id);

INSERT OR IGNORE INTO schema_migrations (version) VALUES (1);
