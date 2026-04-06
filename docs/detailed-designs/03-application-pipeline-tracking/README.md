# Feature 03 — Application Pipeline Tracking — Detailed Design

## 1. Overview

This feature provides structured tracking of every role applied to through a defined lifecycle of states. The pipeline is stored in the `pipeline_entries` table in the Orbit SQLite database (`data/orbit.db`). Each row links to the originating tailored resume PDF, the application date, compensation details, current status, and optionally to an offer evaluation record.

**Scope of this feature:**
- `pipeline_entries` table — authoritative tracking for all applications
- `Validate-Pipeline.ps1` — validation script run as a CLI tool or pre-commit hook
- Workflow for adding entries, updating status, and querying the pipeline

**Requirements satisfied:**
- L1-003: Track every role through a defined lifecycle with full traceability
- L2-007: `pipeline_entries` table with all required columns
- L2-008: Status values enforced by CHECK constraint in the database schema

---

## 2. Architecture

### 2.1 C4 Context Diagram

![C4 Context](diagrams/c4_context.png)

The Application Pipeline interacts with the candidate directly (via PowerShell scripts), with Document Generation (which produces PDFs linked from entries), and with Resume Content Management (which produces the tailored Markdown sources). The Offer Evaluation feature writes `eval_id` back to pipeline rows.

### 2.2 C4 Container Diagram

![C4 Container](diagrams/c4_container.png)

The pipeline system consists of the SQLite database container (`data/orbit.db`) and two automation scripts: the pipeline management script and the validator. The `PSSQLite` PowerShell module bridges scripts to the database.

### 2.3 C4 Component Diagram

![C4 Component](diagrams/c4_component.png)

Key components: the `pipeline_entries` table, the `StatusModel` (enforced by CHECK constraint), and `Validate-Pipeline.ps1`.

---

## 3. Component Details

### 3.1 `pipeline_entries` Table

Column layout (see `db/schema.sql` for full definition with constraints):

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| `id` | INTEGER PK | No | Auto-increment surrogate key |
| `seq_no` | INTEGER UNIQUE | No | Human-visible sequence number |
| `applied_date` | TEXT (ISO date) | No | Date application was submitted |
| `company` | TEXT | No | Company name |
| `role` | TEXT | No | Job title |
| `source` | TEXT | No | Where the role was found |
| `status` | TEXT | No | Lifecycle status (CHECK constraint) |
| `rate` | TEXT | Yes | Compensation figure |
| `pdf_path` | TEXT | Yes | Relative path to submitted PDF |
| `eval_id` | INTEGER FK | Yes | FK → `offer_evaluations.id` (most recent) |
| `notes` | TEXT | Yes | Free-text annotations |
| `created_at` | TEXT | No | Row creation timestamp |
| `updated_at` | TEXT | No | Last modification timestamp |

### 3.2 Status Model (CHECK Constraint)

Valid `status` values, enforced at the database layer:

| Status | Meaning |
|--------|---------|
| `Evaluated` | Role reviewed and deemed worth pursuing |
| `Applied` | Application submitted |
| `Responded` | Recruiter or hiring manager has responded |
| `Interview` | Interview scheduled or completed |
| `Offer` | Offer received |
| `Rejected` | Application rejected |
| `Discarded` | Decided not to pursue after initial evaluation |
| `SKIP` | Role noted but intentionally skipped without evaluation |

There is no separate `templates/states.yml` file; the constraint is the authoritative definition.

### 3.3 `scripts/Validate-Pipeline.ps1`

Queries `pipeline_entries` and asserts data quality rules not enforced by the DB schema:

- `applied_date` matches `^\d{4}-\d{2}-\d{2}$`
- `seq_no` values are unique and monotonically increasing (no gaps in query order)
- `pdf_path` values, when non-null, point to existing files on disk
- No `notes` value starts with a backtick or HTML tag (catches Markdown-contaminated cells)

Reports one line per violation: `Row id=<n>: <column> — <reason>`.

### 3.4 `scripts/modules/Invoke-PipelineDb.psm1`

Encapsulates all database operations for the pipeline:

```powershell
function Add-PipelineEntry { ... }       # INSERT with auto seq_no
function Update-PipelineStatus { ... }   # UPDATE status + updated_at only
function Get-PipelineEntries { ... }     # SELECT with optional -Status filter
function Set-PipelineEvalLink { ... }    # UPDATE eval_id
function Set-PipelinePdfPath { ... }     # UPDATE pdf_path
```

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 Entity Descriptions

**PipelineEntry**
Maps directly to a `pipeline_entries` row. `status` is constrained by the DB CHECK. `evalId` is a nullable FK to the most recent `offer_evaluations` row for this application.

**StatusModel**
Not a stored entity — it is the CHECK constraint in the schema. The eight valid values are the only authoritative list.

---

## 5. Key Workflows

### 5.1 Add Pipeline Entry

![Sequence Diagram](diagrams/sequence_add_entry.png)

After building a tailored resume PDF (Feature 02), the candidate invokes `Add-PipelineEntry` with the required fields. The module computes the next `seq_no` via `SELECT MAX(seq_no) + 1`, inserts the row, and returns the new `id`. Initial status is typically `Applied` or `Evaluated`.

### 5.2 Update Application Status

![Sequence Diagram](diagrams/sequence_update_status.png)

When the application status changes, the candidate invokes `Update-PipelineStatus -Id <n> -Status Interview`. The module runs `UPDATE pipeline_entries SET status = ?, updated_at = ? WHERE id = ?`. Only `status` and `updated_at` change; all other columns are untouched.

### 5.3 Validate Pipeline

![Sequence Diagram](diagrams/sequence_validate_pipeline.png)

`Validate-Pipeline.ps1` queries all `pipeline_entries` rows, runs each data-quality assertion, and reports violations. Schema-level violations (bad status values) are caught by the DB before they reach the validator — the validator handles quality rules above the schema layer.

---

## 6. API Contracts

### `scripts/Validate-Pipeline.ps1`

```
.\scripts\Validate-Pipeline.ps1 [-DbPath <path>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-DbPath` | No | Path to `data/orbit.db` (default: `data/orbit.db` relative to repo root) |

Exit codes: `0` = all entries valid, `1` = one or more validation failures.

---

**PowerShell module function signatures:**

```powershell
function Add-PipelineEntry {
    param (
        [Parameter(Mandatory)] [string] $Company,
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $AppliedDate,   # YYYY-MM-DD
        [Parameter(Mandatory)] [string] $Status,
        [string] $Rate,
        [string] $PdfPath,
        [string] $Notes
    )
    # Returns: [int] id of the new row
}

function Update-PipelineStatus {
    param (
        [Parameter(Mandatory)] [int]    $Id,
        [Parameter(Mandatory)] [string] $Status
    )
    # Returns: [void]; throws on invalid status (DB CHECK violation)
}

function Get-PipelineEntries {
    param (
        [string] $Status   # Optional filter; returns all if omitted
    )
    # Returns: [PSCustomObject[]] one object per matching row
}
```

**DB access library:**
- PowerShell: `PSSQLite` module (`Install-Module PSSQLite`)
- Node.js: `better-sqlite3` (`npm install better-sqlite3`)

---

## 7. Security Considerations

- `data/orbit.db` contains compensation data, recruiter names, and application outcomes. It is gitignored (L2-024) and must never be committed to a public repository.
- The `PSSQLite` module uses parameterised queries; no raw string interpolation into SQL.
- `Validate-Pipeline.ps1` is read-only; it never modifies the database.

---

## 8. Open Questions

| # | Question | Status |
|---|----------|--------|
| 1 | Should `Validate-Pipeline.ps1` run as a Git pre-commit hook automatically? | Open |
| 2 | Should a summary view (count by status) be generated as a CLI command? | Open |
| 3 | Should the pipeline table be exportable to Markdown for sharing/printing? | Open |
