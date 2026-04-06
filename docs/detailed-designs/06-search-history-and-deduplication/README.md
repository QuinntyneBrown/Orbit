# Feature 06 — Search History and Deduplication — Detailed Design

## 1. Overview

Feature 06 provides persistent job search history with intelligent deduplication backed by the Orbit SQLite database. After each job search run, results are upserted into the `job_listings` table using `(company, title)` as the deduplication key. Each run creates a `scan_runs` row. A human-readable Markdown export is generated from the database after each run, with a diff summary computed by querying across the two most recent `scan_runs` rows.

**Stories covered:**
- **L2-014** — Search Result Persistence: upsert into `job_listings` with `(company, title)` deduplication
- **L2-015** — Dated Search Result Export: generate `data/search-results/YYYY-MM-DD.md` from DB; retain N most recent files (configurable)

**Design constraints:**
- SQLite database is the persistence layer; no TSV or flat-file history store
- User-set `Applied` status on `job_listings` rows must never be overwritten by a scan
- Rolling export window size is read from `config/search-settings.json` key `resultHistoryWindow` (default: 8)
- First run produces "First run — no prior results to compare" diff block

---

## 2. Architecture

### 2.1 C4 Context Diagram

![C4 Context](diagrams/c4_context.png)

### 2.2 C4 Container Diagram

![C4 Container](diagrams/c4_container.png)

### 2.3 C4 Component Diagram

![C4 Component](diagrams/c4_component.png)

---

## 3. Component Details

### 3.1 HistoryStore

Manages all read/write operations against `job_listings` and `scan_runs`. On each run:
1. INSERT a new `scan_runs` row and capture its id
2. For each incoming result, attempt an INSERT into `job_listings`
3. On UNIQUE constraint conflict `(company, title)`: UPDATE `last_seen_date` and set `status = 'Seen'` — **unless `status = 'Applied'`**, which is left untouched
4. UPDATE `scan_runs` totals (`total_results`, `new_listings`, `seen_listings`)

### 3.2 DeduplicationEngine

Runs as part of the upsert logic in HistoryStore:

```sql
INSERT INTO job_listings (..., status, first_seen_date, last_seen_date)
VALUES (?, ?, ?, ..., 'New', date('now'), date('now'))
ON CONFLICT (company, title) DO UPDATE SET
    last_seen_date = date('now'),
    status = CASE WHEN status = 'Applied' THEN 'Applied' ELSE 'Seen' END,
    scan_run_id = excluded.scan_run_id;
```

Normalisation: `company` and `title` are stored lowercased and trimmed before the upsert to ensure consistent matching regardless of board formatting differences.

### 3.3 DiffGenerator

Computes the run diff by querying the two most recent `scan_runs` rows:

```sql
-- New listings in current run
SELECT COUNT(*) FROM job_listings WHERE scan_run_id = ? AND status = 'New';

-- Listings in previous run absent from current run
SELECT COUNT(*) FROM job_listings
WHERE scan_run_id = ? AND (company, title) NOT IN (
    SELECT company, title FROM job_listings WHERE scan_run_id = ?
);

-- Listings with changed status between runs
SELECT COUNT(*) FROM job_listings j1
JOIN job_listings j2 ON j1.company = j2.company AND j1.title = j2.title
WHERE j1.scan_run_id = ? AND j2.scan_run_id = ? AND j1.status != j2.status;
```

If fewer than two `scan_runs` rows exist, returns a first-run sentinel.

### 3.4 DatedExportWriter

Generates `data/search-results/YYYY-MM-DD.md` by:
1. Querying `scan_runs JOIN job_listings WHERE scan_run_id = <current>`
2. Rendering listings grouped by source with YAML front-matter and diff header
3. Writing the file to disk

### 3.5 RollingWindowManager

After writing the export, enumerates files matching `data/search-results/*.md`, sorts by filename (ISO date), and deletes the oldest when count exceeds the configured window size.

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 TSV Schema → Database Tables

The former `data/scan-history.tsv` is replaced by the `job_listings` and `scan_runs` tables defined in `db/schema.sql`. See `db/schema.sql` for full column definitions and constraints.

**`scan_runs` key columns:**

| Column | Description |
|--------|-------------|
| `id` | Auto-increment PK; used as the `scan_run_id` FK on `job_listings` |
| `run_date` | ISO date of the run |
| `new_listings` | Count of `job_listings` rows with `status = 'New'` for this run |
| `seen_listings` | Count of `job_listings` rows with `status = 'Seen'` for this run |
| `boards_searched` | JSON array of board/portal names scanned |

**`job_listings` deduplication key:** `UNIQUE (company, title)` — both stored normalised (lowercase, trimmed).

### 4.3 Entity Descriptions

| Entity | Description |
|--------|-------------|
| `ScanRun` | Maps to a `scan_runs` row. Represents one execution of the job search module. |
| `JobListing` | Maps to a `job_listings` row. Deduplicated across runs by `(company, title)`. |
| `DeduplicationResult` | Output of the upsert pass: counts of new, seen, and applied-protected rows. |
| `RunDiff` | Computed from DiffGenerator: newListings, removedListings, changedListings. |
| `DatedExport` | A single dated Markdown file generated from DB data. |

---

## 5. Key Workflows

### 5.1 Persist Results

![Persist Results Sequence](diagrams/sequence_persist_results.png)

After each search run, `HistoryStore` opens a DB transaction, inserts/updates each listing via the upsert query, updates the `scan_runs` totals, and commits. `Applied`-status rows pass through the `CASE` expression unchanged.

### 5.2 Deduplication

![Deduplication Sequence](diagrams/sequence_deduplication.png)

The SQLite `ON CONFLICT` clause handles deduplication atomically. No separate pre-pass is needed.

### 5.3 Generate Diff

![Generate Diff Sequence](diagrams/sequence_generate_diff.png)

`DiffGenerator` queries `job_listings` using the two most recent `scan_run_id` values. The three diff queries (new, removed, changed) run in a single read transaction and are embedded in the export header.

---

## 6. API Contracts

This feature is invoked automatically by the Job Search Orchestrator (Feature 05) after each search run.

```
SearchOrchestrator
  → HistoryStore.Persist(scanRunId, results)      # upsert job_listings
  → DiffGenerator.Compute(currentRunId)           # SQL diff queries
  → DatedExportWriter.Write(scanRunId, diff)      # generate Markdown file
  → RollingWindowManager.Prune()                  # delete oldest export
```

**PowerShell function signatures:**

```powershell
function Invoke-HistoryPersist {
    param (
        [Parameter(Mandatory)] [int]           $ScanRunId,
        [Parameter(Mandatory)] [SearchResult[]] $Results
    )
    # Returns: [DeduplicationResult] @{ New; Seen; AppliedProtected }
}

function Get-RunDiff {
    param (
        [Parameter(Mandatory)] [int] $CurrentRunId
    )
    # Returns: [RunDiff] or first-run sentinel
}
```

**File contracts:**
- `data/search-results/<YYYY-MM-DD>.md` — one file per run; overwritten if same-day run repeats
- `data/orbit.db` — the persistent store; never written directly by this module (all via HistoryStore)

---

## 7. Security Considerations

- `data/orbit.db` contains employer intelligence and search history; it is gitignored (L2-024)
- `data/search-results/` exports are also gitignored
- `Applied` status protection prevents accidental data loss if a listing is re-scraped after the candidate has progressed

---

## 8. Open Questions

1. Should `resultHistoryWindow` in `config/search-settings.json` also cap the number of `scan_runs` rows retained in the DB, or only the file exports? **Currently: file exports only.**
2. How should URL changes for the same `(company, title)` be handled — currently treated as a `Seen` match (key wins). Recommend surfacing URL changes in the diff as a note.
3. Should the diff report distinguish truly removed listings from listings that moved boards (same title+company, different URL)?
