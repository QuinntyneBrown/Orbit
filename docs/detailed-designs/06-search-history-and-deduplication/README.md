# Feature 06 — Search History and Deduplication — Detailed Design

## 1. Overview

Feature 06 provides persistent job search history with intelligent deduplication within Orbit. After each job search run, the full result set is appended to a TSV history file. Listings are deduplicated by Company + Title across runs, and a human-readable dated export captures net-new, removed, and status-changed listings relative to the previous run.

**Stories covered:**
- **L2-014** — Search Result Persistence: append to `data/scan-history.tsv` with deduplication logic
- **L2-015** — Dated Search Result Export: write `data/search-results/YYYY-MM-DD.md` with diff summary; retain 8 most recent files

**Design constraints:**
- No database server; TSV file is the persistence layer
- User-set `Applied` status must never be overwritten by a scan
- Rolling window of 8 dated export files; oldest deleted on overflow
- First run produces a "no prior results" note rather than a diff

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

### HistoryStore
Manages all read/write operations against `data/scan-history.tsv`. Responsible for creating the file on first run, appending new records, and enforcing the status-protection rule (never overwrite `Applied`).

### DeduplicationEngine
Compares an incoming result set against existing history records. Uses a normalised `Company + Title` key. Returns three buckets: `New`, `Seen`, and `Applied` (pass-through).

### DiffGenerator
Loads the two most recent dated export files (or signals first-run) and computes:
- Net-new listings (present in current, absent in previous)
- Removed listings (present in previous, absent in current)
- Status-changed listings (same key, different status)

### DatedExportWriter
Serialises the current result set with its diff summary to `data/search-results/YYYY-MM-DD.md`. After writing, prunes any files beyond the 8-file rolling window.

### RollingWindowManager
Enumerates files matching `data/search-results/*.md`, sorts by name (ISO date), and deletes the oldest when count exceeds 8.

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 Entity Descriptions

| Entity | Description |
|---|---|
| `ScanRecord` | One row in `scan-history.tsv`. Fields: `Date`, `Title`, `Company`, `Board`, `URL`, `Status`. |
| `ScanHistory` | In-memory representation of the full TSV; provides lookup by composite key. |
| `SearchResult` | Raw listing returned by a single search run before deduplication. |
| `DeduplicationResult` | Output of the deduplication pass: lists of new, seen, and applied records. |
| `RunDiff` | Computed difference between two consecutive runs: newListings, removedListings, changedListings. |
| `DatedExport` | A single dated Markdown export file and its content, including the diff header block. |

---

## 5. Key Workflows

### 5.1 Persist Results

![Persist Results Sequence](diagrams/sequence_persist_results.png)

After each search run, the `SearchOrchestrator` passes raw results to `HistoryStore`. The store loads the current TSV, feeds data through `DeduplicationEngine`, merges the tagged records back, and flushes to disk. Records already marked `Applied` are never re-tagged.

### 5.2 Deduplication

![Deduplication Sequence](diagrams/sequence_deduplication.png)

`DeduplicationEngine` normalises Company and Title (lowercase, trimmed) to form a composite key. Each incoming result is checked against the key set from existing history. Matches with `Applied` status pass through unchanged; other matches are tagged `Seen`; non-matches are tagged `New`.

### 5.3 Generate Diff

![Generate Diff Sequence](diagrams/sequence_generate_diff.png)

`DiffGenerator` reads the two most recent dated export files. If fewer than two exist, it returns a first-run sentinel. Otherwise it computes set-difference and status-change comparisons and returns a `RunDiff` that the `DatedExportWriter` embeds as a human-readable header.

---

## 6. Security Considerations

- The TSV and dated exports may contain personal job-search data; the repository should remain private.
- No credentials or API tokens are stored in history files.
- `Applied` status protection prevents accidental data loss if a listing is re-scraped after the candidate has progressed.

---

## 7. Open Questions

1. Should `scan-history.tsv` be excluded from version control to avoid leaking employer intelligence in a public fork?
2. Is 8 the right rolling-window size, or should it be configurable via a setting in `config.json`?
3. How should URL changes for the same Company+Title be handled — treated as a new listing or as a status change?
4. Should the diff header distinguish between truly removed listings and listings that moved boards (same title, different URL)?
