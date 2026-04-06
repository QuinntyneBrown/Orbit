# Feature 04 — Offer Evaluation — Detailed Design

## 1. Overview

Feature 04 provides a structured, scored evaluation framework for job postings within Orbit. Before any tailoring effort is invested, each opportunity is assessed against a defined set of weighted dimensions and assigned a numeric score. Evaluations are stored as rows in the `offer_evaluations` table in the Orbit SQLite database, with full version history via the `superseded_by` foreign key. The pipeline entry for the role is updated with a reference to the most recent evaluation.

**Scope:**
- L1-004: Structured evaluation of job postings with weighted scoring
- L2-009: Offer evaluation stored in `offer_evaluations` table with all dimension columns
- L2-010: Weighted numeric scoring (0.0–5.0) with recommended action thresholds
- L2-025: Evaluation versioning via `superseded_by` FK (no file renaming, no file storage)

**Key design decisions:**
- Evaluations live entirely in the database — no evaluation Markdown files
- Score computation is deterministic from the five dimension columns
- Re-evaluation inserts a new row; old row is linked via `superseded_by`
- Pipeline integration is a FK update (`pipeline_entries.eval_id`) only

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

### 3.1 Offer Evaluator (`Invoke-OfferEvaluation.ps1`)

**Responsibilities:**
- Accept `--company` and `--role` parameters
- Generate an evaluation form (temp Markdown file from template) for the candidate to fill in
- Open the form via VS Code (`code <path>`); falls back to `notepad.exe` if `code` is not on PATH
- After the candidate saves and closes the editor, parse the five dimension ratings from the form
- Compute the score, label, and recommended action
- INSERT a new row into `offer_evaluations`
- If a prior evaluation exists for the same company+role, set its `superseded_by` to the new row's id
- UPDATE `pipeline_entries.eval_id` for the matching row

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--company` | Yes | Company name |
| `--role` | Yes | Role title |
| `--force` | No | Skip confirmation if a prior evaluation exists |

### 3.2 Score Computer (`Compute-OfferScore.psm1`)

**Module:** `scripts/modules/Compute-OfferScore.psm1`

**Responsibilities:**
- Accept five dimension ratings (A/B/C/Skip) as input
- Map ratings to numeric values
- Apply dimension weights
- Return composite score, label, and recommended action
- Raise an error if any dimension is absent (NULL) — never silently default

**Weight table:**

| Dimension | Weight |
|-----------|--------|
| Technical Match | 35% |
| Seniority Alignment | 25% |
| Archetype Fit | 20% |
| Compensation Fairness | 10% |
| Market Demand | 10% |

**Score thresholds:**

| Score | Label | Recommended Action |
|-------|-------|--------------------|
| ≥ 4.5 | Priority | Tailor |
| 3.0–4.4 | Viable | Watch |
| < 3.0 | Low Fit | Skip |

> **Note:** `Watch` aligns with L2-009 AC2. `Tailor`, `Watch`, and `Skip` are the only three permitted recommended-action values — enforced by CHECK constraint in the schema.

**Missing dimension handling (L2-010 AC4):** If any of the five weighted dimensions has no rating (NULL or empty in the parsed form), `Compute-OfferScore` must throw with a message identifying the missing dimension. The evaluation record must not be inserted with a NULL score.

### 3.3 Evaluation Form Template

**File:** `templates/offer-eval-template.md`

Used as a temporary editing scaffold only — not stored long-term. After the candidate fills in the form, the script parses the five dimension ratings, inserts the structured row into the database, and discards the temp file. The template is never modified.

**Evaluated dimensions recorded in the form:**
1. Role fit vs. candidate profile
2. Rate vs. target rate
3. Remote/hybrid terms
4. Domain alignment
5. Company stability
6. Contract length
7. Interview likelihood
8. Growth potential

The five weighted dimensions (Technical Match, Seniority Alignment, Archetype Fit, Compensation Fairness, Market Demand) map to a subset of the above and drive the numeric score. The other dimensions provide qualitative notes only and are captured in the `notes` TEXT column.

### 3.4 Pipeline Linker

Updates `pipeline_entries.eval_id` to point to the newly inserted evaluation row:

```sql
UPDATE pipeline_entries
SET eval_id = ?, updated_at = datetime('now')
WHERE company = ? AND role = ?
```

Uses exact company + role match. If no pipeline row exists for the combination, logs a warning but does not fail.

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 Entity Descriptions

#### offer_evaluations (table)

See `db/schema.sql` for full column definitions and CHECK constraints.

| Column | Type | Description |
|--------|------|-------------|
| `company` | TEXT | Company name |
| `role` | TEXT | Role title |
| `eval_date` | TEXT | Evaluation date (ISO) |
| `technical_match` | TEXT | A / B / C / Skip |
| `seniority_alignment` | TEXT | A / B / C / Skip |
| `archetype_fit` | TEXT | A / B / C / Skip |
| `compensation_fairness` | TEXT | A / B / C / Skip |
| `market_demand` | TEXT | A / B / C / Skip |
| `score` | REAL | Computed composite score 0.0–5.0 |
| `label` | TEXT | Priority / Viable / Low Fit |
| `recommended_action` | TEXT | Tailor / Watch / Skip |
| `notes` | TEXT | Qualitative notes block |
| `version` | INTEGER | 1 for first eval; increments per re-evaluation |
| `superseded_by` | INTEGER FK | Points to newer evaluation row; NULL = current |

**Rating-to-numeric mapping:**

| Rating | Numeric Value |
|--------|---------------|
| A | 5.0 |
| B | 3.5 |
| C | 2.0 |
| Skip | 0.0 |

> A `Skip` rating scores 0 (deliberate "not evaluating this"). A *missing* (NULL) dimension is an error per L2-010 AC4.

---

## 5. Key Workflows

### 5.1 Evaluate Offer

![Sequence Diagram](diagrams/sequence_evaluate_offer.png)

The candidate invokes `Invoke-OfferEvaluation.ps1 --company "Acme Corp" --role "Staff Engineer"`. The script creates a temp evaluation form, opens it in VS Code, waits for the editor to close, parses the five dimension ratings, computes the score, inserts the `offer_evaluations` row, and updates `pipeline_entries.eval_id`.

### 5.2 Compute Score

![Sequence Diagram](diagrams/sequence_compute_score.png)

`Compute-OfferScore` receives the five ratings, maps each to a numeric value, multiplies by weight, sums, and returns `{ Score; Label; RecommendedAction }`. Any NULL dimension causes an immediate error with the dimension name.

### 5.3 Re-evaluate (Versioning)

![Sequence Diagram](diagrams/sequence_save_evaluation.png)

When `Invoke-OfferEvaluation.ps1` is run again for the same company+role:
1. SELECT the existing evaluation row
2. INSERT the new row (version incremented)
3. UPDATE the old row's `superseded_by` = new row's id
4. UPDATE `pipeline_entries.eval_id` = new row's id

The old row is preserved in full with its original score and notes.

---

## 6. API Contracts

**PowerShell function signatures:**

```powershell
# Main entry point
function Invoke-OfferEvaluation {
    param (
        [Parameter(Mandatory)] [string] $Company,
        [Parameter(Mandatory)] [string] $Role,
        [switch] $Force
    )
    # Returns: [int] id of the inserted offer_evaluations row
}

# Score computation
function Compute-OfferScore {
    param (
        [Parameter(Mandatory)] [string] $TechnicalMatch,
        [Parameter(Mandatory)] [string] $SeniorityAlignment,
        [Parameter(Mandatory)] [string] $ArchetypeFit,
        [Parameter(Mandatory)] [string] $CompensationFairness,
        [Parameter(Mandatory)] [string] $MarketDemand
    )
    # Returns: [PSCustomObject] @{ Score; Label; RecommendedAction }
    # Throws: if any parameter is null/empty (L2-010 AC4)
}

# DB write
function Save-EvaluationToDb {
    param (
        [Parameter(Mandatory)] [string] $Company,
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [PSCustomObject] $Dimensions,  # five ratings
        [Parameter(Mandatory)] [PSCustomObject] $Score,       # from Compute-OfferScore
        [string] $Notes,
        [switch] $Force
    )
    # Returns: [int] id of the new offer_evaluations row
    # Side effects: sets superseded_by on prior row; updates pipeline_entries.eval_id
}
```

**DB access:** `PSSQLite` module with parameterised queries only.

---

## 7. Security Considerations

- `offer_evaluations` rows may contain salary/rate expectations and negotiation context — `data/orbit.db` must be gitignored (L2-024)
- The temp evaluation form is written to the system temp directory and deleted after parsing; it never persists in the repo
- The `Compute-OfferScore` function is pure (no side effects); it does not write to the database

---

## 8. Open Questions

| # | Question | Status |
|---|----------|--------|
| 1 | Should weight overrides be configurable per-candidate via `config/profile.yml`? | Open |
| 2 | Should superseded evaluations be queryable via a `Get-EvaluationHistory` function? | Open |
| 3 | Should archived (superseded) evaluations be visible in pipeline exports with an `[Archived]` tag? | Open |
