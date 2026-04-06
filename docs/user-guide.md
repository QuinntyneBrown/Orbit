# Orbit User Guide

Orbit is a local career management platform. It tracks job search activity, manages resume variants, evaluates opportunities, and maintains a recruiter CRM — all from a SQLite database and PowerShell scripts that run on your own machine. Nothing is sent to any external service.

---

## Table of Contents

1. [Prerequisites & Setup](#1-prerequisites--setup)
2. [Project Layout](#2-project-layout)
3. [Configuration](#3-configuration)
4. [Base Resumes](#4-base-resumes)
5. [Resume Variants](#5-resume-variants)
6. [PDF Generation](#6-pdf-generation)
7. [Job Search](#7-job-search)
8. [Offer Evaluation & Scoring](#8-offer-evaluation--scoring)
9. [Application Pipeline](#9-application-pipeline)
10. [Interview Story Bank](#10-interview-story-bank)
11. [Recruiter & Account CRM](#11-recruiter--account-crm)
12. [Outreach Messages](#12-outreach-messages)
13. [Maintenance Scripts](#13-maintenance-scripts)
14. [Database Reference](#14-database-reference)
15. [Module Function Reference](#15-module-function-reference)
16. [Typical Weekly Workflow](#16-typical-weekly-workflow)

---

## 1. Prerequisites & Setup

### Requirements

| Requirement | Minimum version | Notes |
|---|---|---|
| PowerShell | 7.2 | All `.ps1` / `.psm1` scripts require PS 7.2+ |
| PSSQLite module | any | `Install-Module PSSQLite -Scope CurrentUser` |
| Node.js | 18+ | Required for PDF generation only |
| npm packages | — | `npm install` in the repo root |
| Playwright Chromium | — | `npx playwright install chromium` |

### First-time setup

```powershell
# 1. Install the PSSQLite PowerShell module (once, per machine)
Install-Module PSSQLite -Scope CurrentUser

# 2. Install Node dependencies (for PDF generation)
npm install
npx playwright install chromium

# 3. Install the pre-commit hook
Copy-Item scripts/hooks/pre-commit .git/hooks/pre-commit
# On Linux/macOS: chmod +x .git/hooks/pre-commit

# 4. Fill in your candidate profile
# Edit config/profile.yml — see Section 3

# 5. Create your base resumes
# Edit content/base/focused-base.md and content/base/comprehensive-base.md — see Section 4
```

The database (`data/orbit.db`) is created automatically the first time any script runs. All migrations are applied automatically — no manual SQL setup is needed.

---

## 2. Project Layout

```
Orbit/
├── config/
│   ├── profile.yml              ← Your personal profile & search keywords (gitignored)
│   ├── archetype-rules.json     ← Role classification patterns (5 archetypes)
│   └── search-settings.json     ← Search window size and other settings
│
├── content/
│   ├── base/
│   │   ├── focused-base.md      ← Primary base resume (used for most tailoring)
│   │   └── comprehensive-base.md ← Full experience variant (includes everything)
│   ├── tailored/                ← Job-specific variants (gitignored)
│   ├── notes/                   ← Tailoring notes per role (gitignored)
│   └── outreach/                ← LinkedIn & email drafts (gitignored)
│
├── data/
│   ├── orbit.db                 ← SQLite database — single source of truth (gitignored)
│   └── search-results/          ← Rolling window of search exports (gitignored)
│
├── db/
│   ├── schema.sql               ← Reference schema (do not edit directly)
│   └── migrations/              ← Numbered SQL migration files
│
├── docs/
│   ├── specs/                   ← Requirements (L1.md, L2.md)
│   └── user-guide.md            ← This file
│
├── exports/                     ← Generated PDFs (gitignored)
├── scripts/                     ← All automation scripts & modules
└── templates/                   ← Resume HTML, notes template, eval form template
```

### What is gitignored

The following are excluded from version control:
- `data/` — database and search exports
- `content/tailored/`, `content/notes/`, `content/outreach/` — job-specific content
- `config/profile.yml` — personal contact details and keywords
- `exports/` — generated PDFs

Your base resumes (`content/base/*.md`) and templates are tracked. The scripts and schema are tracked.

---

## 3. Configuration

### `config/profile.yml`

Fill this in once. It controls session integrity checks and job search keyword extraction.

```yaml
candidate:
  name: "Your Name"
  email: "you@example.com"
  phone: "+1 555 000 0000"
  linkedin: "https://linkedin.com/in/yourhandle"
  location: "Ottawa, ON"

search:
  keywords:
    - cloud architect
    - solution architect
    - platform engineering
    - API design
  location: "Remote"
  remote: true

preferences:
  base_resume: focused-base.md
```

The `keywords` list drives board search queries. Each keyword is searched independently on each board.

### `config/search-settings.json`

Controls how many search export files to keep:

```json
{
  "resultHistoryWindow": 8
}
```

Increase this if you want longer search history. Older files are pruned automatically after each search run.

### `config/archetype-rules.json`

Defines the five role archetypes and their keyword patterns. Edit this to add patterns relevant to your industry. Archetypes are evaluated in priority order — the first match wins.

| Archetype | Description |
|---|---|
| Government / Public Sector | Federal, security clearance, public-sector agencies |
| AI / Innovation | LLM, ML, AI research, generative AI |
| Consulting Firm | Advisory firms, big four, management consulting |
| Product Company | SaaS, startup, product engineering |
| Enterprise Contract | Default — staff augmentation, body-shop contracts |

---

## 4. Base Resumes

Orbit maintains two canonical base resumes in `content/base/`:

| File | Purpose |
|---|---|
| `focused-base.md` | Curated, forward-looking variant. Used as the default source for tailoring. |
| `comprehensive-base.md` | Complete work history — every role, technology, certification. |

### Rules

- Content flows **from comprehensive → focused**, never the reverse. If something is in `focused-base.md` it must also exist in `comprehensive-base.md`.
- YAML front matter is required on both files (name, email, phone, linkedin, date).
- Run `verify-sync.ps1` regularly to catch drift between the two files.

### YAML front matter format

```yaml
---
name: Your Name
email: you@example.com
phone: +1 555 000 0000
linkedin: https://linkedin.com/in/yourhandle
date: 2025-01-01
---
```

---

## 5. Resume Variants

### Creating a single variant

```powershell
# Create a tailored resume for a specific role
.\new-variant.ps1 -Name acme-cloud-architect

# Also create a notes file from the template
.\new-variant.ps1 -Name acme-cloud-architect -Notes

# Overwrite an existing variant without prompting
.\new-variant.ps1 -Name acme-cloud-architect -Force
```

**Naming convention:** Use lowercase letters, numbers, and hyphens only. For example: `acme-cloud-architect`, `globex-platform-lead`, `initech-senior-sre`.

**What happens:**
1. `content/base/focused-base.md` is copied to `content/tailored/resume-acme-cloud-architect.md`
2. YAML front matter is injected with placeholder fields:
   ```yaml
   source_base: focused-base.md
   company: ""
   role: ""
   ```
3. You fill in `company` and `role` before committing (the pre-commit hook enforces this).
4. If `-Notes` is passed, `content/notes/acme-cloud-architect.md` is created from `templates/notes-template.md`.

### Creating multiple variants in parallel

```powershell
# Tailor four roles simultaneously (default: up to 4 concurrent jobs)
.\scripts\batch-tailor.ps1 -Roles @('acme-cloud-architect', 'globex-platform-lead', 'initech-senior-sre', 'umbrella-devops-lead')

# Limit concurrency to 2 jobs at a time
.\scripts\batch-tailor.ps1 -Roles @('role-a', 'role-b', 'role-c') -MaxJobs 2
```

### After creating a variant

1. Open `content/tailored/resume-{name}.md` and edit it — remove irrelevant sections, adjust bullet points, add role-specific achievements.
2. Fill in `company:` and `role:` in the YAML front matter.
3. Open `content/notes/{name}.md` (if created) and fill in tailoring angles, keywords, baseline bullets.
4. Generate a PDF when ready (see Section 6).

### Pre-commit validation

The git pre-commit hook (`scripts/hooks/pre-commit`) validates every staged file in `content/tailored/`:
- YAML front matter must start with `---`
- `source_base`, `company`, and `role` must all be present and non-empty
- Files must not have outreach suffixes (those belong in `content/outreach/`)

A commit is rejected if any check fails.

---

## 6. PDF Generation

```bash
node scripts/build-pdf.mjs content/tailored/resume-acme-cloud-architect.md
```

**Output:** `exports/resume-acme-cloud-architect.pdf`

**Requirements:**
- `npm install` (installs `marked` and `playwright`)
- `npx playwright install chromium` (downloads the headless browser)
- `templates/resume.html` must contain a `{{CONTENT}}` placeholder

**What happens:**
1. YAML front matter is stripped (metadata does not appear in the PDF).
2. Markdown is parsed to HTML using `marked`.
3. HTML is injected into `templates/resume.html`.
4. Playwright Chromium renders the page and prints it to A4 PDF.
5. PDF is written to `exports/`.

**Customising the PDF layout:** Edit `templates/resume.html`. Use CSS `@page` rules, `@media print`, and `page-break-*` properties to control margins and page breaks.

---

## 7. Job Search

```powershell
# Run all search modes (default when no flags given)
.\scripts\Invoke-JobSearch.ps1

# Run specific modes
.\scripts\Invoke-JobSearch.ps1 -BoardSearch
.\scripts\Invoke-JobSearch.ps1 -ScanPortals
.\scripts\Invoke-JobSearch.ps1 -RecruiterBoards

# Run all modes and generate outreach for high-scoring listings
.\scripts\Invoke-JobSearch.ps1 -Outreach
```

### What each mode does

| Flag | What it searches |
|---|---|
| `-BoardSearch` | LinkedIn, Indeed, Glassdoor, Remote.io, WeWorkRemotely — using your profile keywords |
| `-ScanPortals` | Career pages of companies in your `target_accounts` table |
| `-RecruiterBoards` | Opportunity boards of high-priority (`priority_tier = 'High'`) recruiter contacts |
| `-Outreach` | After search: generates LinkedIn messages for listings with `auto_score ≥ 4.5` |

> **Note:** Board search, portal scan, and recruiter board search are currently stub implementations. They run the full pipeline (dedup, classification, compensation research, export) but return no listings until the Playwright web automation is wired in.

### Session integrity checks

Before searching, the script verifies:
- `config/profile.yml` exists
- `content/base/focused-base.md` exists and is not older than 90 days (prompts if stale)
- The database can be initialised (all migrations applied)

### What happens to results

1. **Deduplication:** Each result is upserted to `job_listings` on the `(company, title)` key.
   - First time seen: `status = 'New'`, `first_seen_date = today`
   - Seen again: `status = 'Seen'`, `last_seen_date = today`
   - Already `Applied`: protected — status is never overwritten
2. **Archetype classification:** Each listing is classified into one of the five archetypes.
3. **Compensation research:** Listings without an explicit rate are researched; results cached 30 days.
4. **Export:** A Markdown summary is written to `data/search-results/YYYY-MM-DD.md`.

### Reading the search export

Each export file has a YAML header and a listing per role:

```markdown
---
date: 2025-04-06
total_results: 14
boards_searched:
  - LinkedIn
  - Indeed
new_listings: 8
seen_listings: 6
---

## Diff

- New listings: 8
- Removed listings: 2
- Status changes: 1

## Results

### Cloud Architect — Acme Corp

- **title**: cloud architect
- **company**: acme corp
- **source**: LinkedIn
- **date**: 2025-04-04
- **rate**: $120/hr
- **url**: https://...
- **archetype**: Enterprise Contract
```

### Adding target accounts and recruiter contacts

Use the module functions directly from a PowerShell session:

```powershell
Import-Module .\scripts\modules\Invoke-RecruiterCrm.psm1 -Force

# Add a target company to watch
Add-TargetAccount -Company "Acme Corp" `
  -CareerPageUrl "https://acme.com/careers" `
  -AtsType "Greenhouse" `
  -Priority "High"

# Add a recruiter contact
Add-RecruiterContact -FirmName "Apex Staffing" `
  -ContactName "Jane Smith" `
  -ContactLinkedin "https://linkedin.com/in/janesmith" `
  -PriorityTier "High" `
  -OpportunityPageUrl "https://apexstaffing.com/jobs" `
  -EngagementStatus "Active"
```

---

## 8. Offer Evaluation & Scoring

```powershell
# Evaluate a role for the first time
.\scripts\Invoke-OfferEvaluation.ps1 -Company "Acme Corp" -Role "Cloud Architect"

# Re-evaluate (creates a new version, preserving the old one)
.\scripts\Invoke-OfferEvaluation.ps1 -Company "Acme Corp" -Role "Cloud Architect" -Force
```

### The evaluation form

The script opens `templates/offer-eval-template.md` pre-filled with the company, role, and date. You fill in a rating for each of the five dimensions:

| Dimension | Weight | What to assess |
|---|---|---|
| Technical Match | 35% | How well your skills match the stated requirements |
| Seniority Alignment | 25% | Whether the level and scope matches your target |
| Archetype Fit | 20% | Whether the employer type fits your preferences |
| Compensation Fairness | 10% | Whether the rate is market-appropriate |
| Market Demand | 10% | How many similar roles are currently available |

**Rating values:** `A` (strong match), `B` (acceptable), `C` (weak match), `Skip` (not applicable — excluded from score)

### Scoring formula

```
Score = (TechnicalMatch × 0.35) + (SeniorityAlignment × 0.25)
      + (ArchetypeFit × 0.20) + (CompensationFairness × 0.10)
      + (MarketDemand × 0.10)
```

Where A = 5.0, B = 3.5, C = 2.0, Skip = 0.0. Maximum possible score: 5.0.

### Labels and recommended actions

| Score | Label | Recommended Action |
|---|---|---|
| ≥ 4.5 | **Priority** | Tailor — invest full effort in a targeted resume |
| ≥ 3.0 | **Viable** | Watch — keep the opportunity visible, lighter tailoring |
| < 3.0 | **Low Fit** | Skip — move on |

### Versioning

Each time you re-evaluate the same company+role, a new row is created in `offer_evaluations` with an incremented `version`. The previous row is linked via `superseded_by`. Your pipeline entry always points to the latest evaluation. The full history is preserved.

---

## 9. Application Pipeline

The pipeline tracks every application from initial evaluation through offer or rejection.

### Pipeline statuses

| Status | Meaning |
|---|---|
| `Evaluated` | Offer evaluated; resume tailored; not yet submitted |
| `Applied` | Application submitted |
| `Responded` | Recruiter or employer has responded |
| `Interview` | Interview scheduled or in progress |
| `Offer` | Offer received |
| `Rejected` | Application rejected |
| `Discarded` | Removed from active consideration |
| `SKIP` | Intentionally skipped |

### Adding an entry

```powershell
Import-Module .\scripts\modules\Invoke-PipelineDb.psm1 -Force
Initialize-OrbitDb

$id = Add-PipelineEntry `
  -Company "Acme Corp" `
  -Role "Cloud Architect" `
  -Source "LinkedIn" `
  -AppliedDate "2025-04-06" `
  -Status "Applied" `
  -Rate "`$120/hr" `
  -PdfPath "exports/resume-acme-cloud-architect.pdf"
```

### Updating status

```powershell
Update-PipelineStatus -Id $id -Status "Interview"
```

### Linking an evaluation

```powershell
Set-PipelineEvalLink -Id $pipelineId -EvalId $evalId
```

`Invoke-OfferEvaluation.ps1` links the evaluation automatically if a pipeline entry already exists for the same company+role.

### Querying the pipeline

```powershell
# All entries
Get-PipelineEntries

# Filter by status
Get-PipelineEntries -Status "Interview"
```

### Applied-status protection

When a subsequent job search finds a listing you have already applied to, the `status` is **never** overwritten. Applied listings are counted separately (`AppliedProtected`) in the search summary.

---

## 10. Interview Story Bank

The story bank stores STAR-format behavioural interview answers, indexed by keyword for relevance matching.

### Adding a story

```powershell
# Interactive — prompts for any missing fields
.\scripts\Add-InterviewStory.ps1

# Fully specified
.\scripts\Add-InterviewStory.ps1 `
  -Title "Led platform migration to AWS" `
  -Context "Company X, Principal Engineer, 2022–2023" `
  -Situation "Legacy on-prem infrastructure caused 40% of incidents." `
  -Task "Own the migration of 12 services to AWS ECS with zero downtime." `
  -Action "Designed a strangler-fig migration strategy; led a 3-person squad; built CI/CD pipelines." `
  -Result "Migration completed in 6 months; incidents dropped 65%; $200k annual savings." `
  -Reflection "Learned the value of incremental rollouts and stakeholder communication cadence." `
  -Skills "AWS","Architecture","Leadership" `
  -Keywords "cloud migration","AWS","platform engineering","incident reduction"
```

**Requirements:**
- All STAR fields plus Reflection must be non-empty.
- At least one keyword is required.

### Retrieving relevant stories

```powershell
Import-Module .\scripts\modules\Invoke-StoryBank.psm1 -Force

# Returns top 5 stories by keyword overlap with the job description
$stories = Get-RelevantStories -JdKeywords @("cloud", "AWS", "platform engineering") -TopN 5
$stories | Format-List title, situation, result, keywords
```

The overlap score is the count of JD keywords that appear in each story's keywords array. Stories with the highest overlap are returned first.

**Warning:** If your story bank has fewer than 3 stories, a warning is printed each time stories are retrieved. Build up the bank before interview preparation.

---

## 11. Recruiter & Account CRM

### Managing recruiter contacts

```powershell
Import-Module .\scripts\modules\Invoke-RecruiterCrm.psm1 -Force

# Add a new recruiter
Add-RecruiterContact `
  -FirmName "Apex Staffing" `
  -ContactName "Jane Smith" `
  -ContactLinkedin "https://linkedin.com/in/janesmith" `
  -PriorityTier "High" `
  -OpportunityPageUrl "https://apexstaffing.com/jobs" `
  -EngagementStatus "Active"

# Record a conversation
Update-RecruiterContact `
  -FirmName "Apex Staffing" `
  -LastContactedDate "2025-04-06" `
  -EngagementStatus "Active" `
  -Notes "Discussed cloud architect roles in the federal space."

# See who is overdue for follow-up (High priority, not contacted in 90+ days)
Get-FollowUpDue
```

**PriorityTier values:** `High`, `Medium`, `Low`
**EngagementStatus values:** `Active`, `Passive`, `Dormant`, `Closed`

### Managing target accounts

```powershell
# Add a company to watch
Add-TargetAccount `
  -Company "Globex Corporation" `
  -CareerPageUrl "https://globex.com/careers" `
  -AtsType "Lever" `
  -Priority "High" `
  -Notes "Strong cloud team; remote-friendly culture."
```

**AtsType values:** `Greenhouse`, `Ashby`, `Lever`, `Wellfound`, `Workable`

### Cross-referencing accounts and recruiters

If a recruiter firm and a target account share the same name, `Set-AccountCrossRef` links them:

```powershell
Set-AccountCrossRef
```

This auto-populates `target_accounts.recruiter_contact_id` for matched names.

---

## 12. Outreach Messages

Outreach messages are stored in `content/outreach/` and recorded in the `outreach_records` database table.

### Generating a LinkedIn message

```powershell
Import-Module .\scripts\modules\Invoke-OutreachManagement.psm1 -Force

$path = New-LinkedInMessage `
  -Company "Acme Corp" `
  -Role "Cloud Architect" `
  -CandidateName "Your Name" `
  -ValueProp "I specialise in cloud platform modernisation with a track record of leading complex migrations from design through production."
```

**Output file:** `content/outreach/acme-corp-cloud-architect-linkedin-message-v1.txt`

### Creating any outreach type

```powershell
$path = New-OutreachFile `
  -Company "Acme Corp" `
  -Role "Cloud Architect" `
  -MessageText "Hi Jane, I noticed the Cloud Architect role at Acme Corp..." `
  -Type "email" `
  -ListingId 42
```

**Types:** `linkedin-message`, `email`, `follow-up`

**Versioning:** If a file for the same company, role, and type already exists, the version number increments: `-v2.txt`, `-v3.txt`, and so on.

### Automatic outreach during search

Run `Invoke-JobSearch.ps1 -Outreach` to automatically generate LinkedIn messages for all listings with `auto_score ≥ 4.5`.

---

## 13. Maintenance Scripts

### `verify-sync.ps1` — Check base resume consistency

```powershell
.\scripts\verify-sync.ps1
```

Compares `focused-base.md` and `comprehensive-base.md` for consistency in:
- Current role title (first `##` heading after the name)
- Certifications section content
- Contact details from YAML front matter (email, phone, LinkedIn)
- Dates on the most recent role

Exits 0 if clean, exits 1 on errors. Warnings are printed for mismatches (both files have the section but values differ).

### `Check-Gitignore.ps1` — Verify protected paths

```powershell
.\scripts\Check-Gitignore.ps1
```

Checks that the following paths do not appear in `git status`:
- `data/orbit.db` and WAL/SHM files
- `data/search-results/`
- `content/tailored/`, `content/outreach/`, `content/notes/`
- `config/profile.yml`
- `resumes/`, `exports/`

Run this if you suspect you may have accidentally un-gitignored something.

### `Validate-Pipeline.ps1` — Check pipeline data integrity

```powershell
.\scripts\Validate-Pipeline.ps1
.\scripts\Validate-Pipeline.ps1 -DbPath "path\to\other.db"
```

Verifies all rows in `pipeline_entries` for:
- `applied_date` in `YYYY-MM-DD` format
- `seq_no` unique and monotonically increasing
- `pdf_path` files exist on disk (when set)
- `notes` do not contain invalid leading characters

---

## 14. Database Reference

The database lives at `data/orbit.db` and is created automatically. You can inspect it with any SQLite browser (e.g., [DB Browser for SQLite](https://sqlitebrowser.org/)).

### Tables

#### `pipeline_entries`
Tracks every application. One row per application.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | Auto-increment |
| `seq_no` | INTEGER UNIQUE | Sequential application number |
| `applied_date` | TEXT | ISO date: YYYY-MM-DD |
| `company` | TEXT NOT NULL | |
| `role` | TEXT NOT NULL | |
| `source` | TEXT NOT NULL | Where you found the role |
| `status` | TEXT NOT NULL | See status values below |
| `rate` | TEXT | Nullable; hourly or annual |
| `pdf_path` | TEXT | Relative path to submitted PDF |
| `eval_id` | INTEGER | FK → offer_evaluations.id |
| `notes` | TEXT | Free-text notes |

**Status values:** `Evaluated`, `Applied`, `Responded`, `Interview`, `Offer`, `Rejected`, `Discarded`, `SKIP`

#### `offer_evaluations`
One row per evaluation. Multiple rows per company+role (versioned).

| Column | Type | Notes |
|---|---|---|
| `company`, `role` | TEXT | Key identifying the opportunity |
| `version` | INTEGER | Starts at 1, increments on re-evaluation |
| `superseded_by` | INTEGER | FK → newer evaluation for same role |
| `technical_match` … `market_demand` | TEXT | A / B / C / Skip |
| `score` | REAL | 0.0 – 5.0 |
| `label` | TEXT | Priority / Viable / Low Fit |
| `recommended_action` | TEXT | Tailor / Watch / Skip |

#### `job_listings`
Every listing found by job search. Deduplicated on `(company, title)`.

| Column | Type | Notes |
|---|---|---|
| `status` | TEXT | New / Seen / Applied / Archived |
| `archetype` | TEXT | One of the five archetypes |
| `archetype_inferred` | INTEGER | 1 if auto-classified, 0 if manually set |
| `auto_score` | REAL | Pre-evaluation fit estimate |
| `is_stale` | INTEGER | 1 if posting is old |
| `is_priority_recruiter` | INTEGER | 1 if from a high-priority recruiter |

#### `recruiter_contacts`
| Column | Type | Notes |
|---|---|---|
| `firm_name` | TEXT UNIQUE | Key |
| `priority_tier` | TEXT | High / Medium / Low |
| `engagement_status` | TEXT | Active / Passive / Dormant / Closed |
| `last_contacted_date` | TEXT | ISO date |

#### `target_accounts`
| Column | Type | Notes |
|---|---|---|
| `name` | TEXT UNIQUE | Company name |
| `career_page_url` | TEXT | Portal scan URL |
| `ats_type` | TEXT | Greenhouse / Ashby / Lever / Wellfound / Workable |
| `priority` | TEXT | High / Medium / Low |

#### `interview_stories`
Append-only STAR story bank.

| Column | Type | Notes |
|---|---|---|
| `keywords` | TEXT | JSON array — used for overlap matching |
| `skills` | TEXT | JSON array |
| `situation`, `task`, `action`, `result`, `reflection` | TEXT NOT NULL | All required |

#### `compensation_estimates`
One row per `listing_id`. Re-researched if older than 30 days.

| Column | Type | Notes |
|---|---|---|
| `range_low`, `range_high` | REAL | Nullable when no data found |
| `confidence` | TEXT | High / Medium / Low / NULL |
| `source` | TEXT | `'No data found'` when unavailable |

#### `scan_runs`
One row per `Invoke-JobSearch.ps1` execution.

| Column | Type | Notes |
|---|---|---|
| `boards_searched` | TEXT | JSON array of board/portal names |
| `total_results`, `new_listings`, `seen_listings` | INTEGER | Counts for the run |

---

## 15. Module Function Reference

All modules are in `scripts/modules/`. Import them with:

```powershell
Import-Module .\scripts\modules\ModuleName.psm1 -Force
```

### `Invoke-PipelineDb.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `Initialize-OrbitDb` | `-DbPath` | void — creates DB, applies migrations |
| `Add-PipelineEntry` | `-Company`, `-Role`, `-Source`, `-AppliedDate`, `-Status` | `[int]` new row id |
| `Update-PipelineStatus` | `-Id`, `-Status` | void |
| `Get-PipelineEntries` | `-Status` (optional filter) | array of rows |
| `Set-PipelineEvalLink` | `-Id`, `-EvalId` | void |
| `Set-PipelinePdfPath` | `-Id`, `-PdfPath` | void |

### `Invoke-HistoryStore.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `New-ScanRun` | `-BoardsSearched`, `-DbPath` | `[int]` scan run id |
| `Invoke-HistoryPersist` | `-ScanRunId`, `-Results`, `-DbPath` | object with `.New`, `.Seen`, `.AppliedProtected` |
| `Get-RunDiff` | `-CurrentRunId`, `-DbPath` | object with `.NewListings`, `.RemovedListings`, `.ChangedListings`, `.IsFirstRun` |
| `Write-SearchExport` | `-ScanRunId`, `-Diff`, `-DbPath`, `-ExportDir` | `[string]` export file path |

### `Invoke-RecruiterCrm.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `Add-RecruiterContact` | `-FirmName`, `-PriorityTier`, `-EngagementStatus` | `[int]` new row id |
| `Update-RecruiterContact` | `-FirmName`, optional: `-LastContactedDate`, `-EngagementStatus`, `-Notes` | void |
| `Get-FollowUpDue` | `-DbPath` | array — high-priority contacts not contacted in 90+ days |
| `Set-AccountCrossRef` | `-DbPath` | `[int]` count of links created |
| `Add-TargetAccount` | `-Company`, optional: `-CareerPageUrl`, `-AtsType`, `-Priority` | `[int]` new/existing row id |

### `Invoke-OutreachManagement.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `New-OutreachFile` | `-Company`, `-Role`, `-MessageText`, `-Type` | `[string]` file path |
| `New-LinkedInMessage` | `-Company`, `-Role`, `-CandidateName`, `-ValueProp` | `[string]` file path |

### `Invoke-StoryBank.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `Add-InterviewStory` | `-Title`, `-Situation`, `-Task`, `-Action`, `-Result`, `-Reflection`, `-Keywords` | `[int]` new row id |
| `Get-RelevantStories` | `-JdKeywords`, `-TopN` (default 5) | array of story rows sorted by keyword overlap |

### `Invoke-ArchetypeClassification.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `Get-Archetype` | `-Title`, `-Company`, `-Description` | object with `.Archetype`, `.IsInferred` |
| `Invoke-ArchetypeClassification` | `-Listings`, `-DbPath` | modified listings array with archetype set |

### `Invoke-CompensationResearch.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `Invoke-CompensationResearch` | `-Listings`, `-DbPath` | modified listings array with `.RateEstimate` set |
| `Test-ExplicitRate` | `-RateField`, `-DescriptionBody` | `[bool]` — true if posting has explicit pay |

### `Compute-OfferScore.psm1`

| Function | Key parameters | Returns |
|---|---|---|
| `Compute-OfferScore` | `-TechnicalMatch`, `-SeniorityAlignment`, `-ArchetypeFit`, `-CompensationFairness`, `-MarketDemand` | object with `.Score`, `.Label`, `.RecommendedAction` |

---

## 16. Typical Weekly Workflow

```
Monday — Search & triage
  1. pwsh scripts/Invoke-JobSearch.ps1
  2. Read data/search-results/<today>.md
  3. For each interesting listing: Invoke-OfferEvaluation.ps1 -Company X -Role Y
  4. Prioritise: focus on "Priority" (score ≥ 4.5) and "Viable" (≥ 3.0) results

Tuesday–Wednesday — Tailor & apply
  5. new-variant.ps1 -Name <slug> -Notes  (one per priority role)
  6. Edit content/tailored/resume-<slug>.md  (customise bullets, emphasise relevant tech)
  7. Fill in content/notes/<slug>.md  (tailoring angles, keyword bank)
  8. node scripts/build-pdf.mjs content/tailored/resume-<slug>.md
  9. Submit application
  10. Add-PipelineEntry -Company X -Role Y -Source LinkedIn -AppliedDate (Get-Date -Format yyyy-MM-dd) -Status Applied

Thursday — Relationship maintenance
  11. Import-Module scripts/modules/Invoke-RecruiterCrm.psm1 -Force
  12. Get-FollowUpDue  →  follow up with any overdue high-priority recruiters
  13. Update-RecruiterContact after each conversation

Friday — Prep & review
  14. verify-sync.ps1  →  fix any drift between base resumes
  15. Add-InterviewStory.ps1  →  capture any new stories from recent experience
  16. Update-PipelineStatus for any roles that have progressed
```

---

## Troubleshooting

**"Migrations directory not found"**
The `db/migrations/` directory is missing. Ensure you cloned the full repository. If you deleted it manually, restore it from git: `git checkout db/migrations`.

**"Base resume not found"**
`content/base/focused-base.md` does not exist. Create it before running any search or variant scripts.

**"Base resume was last modified N days ago (>90). Continue anyway?"**
Your base resume is stale. Update it with recent experience before searching.

**Pre-commit hook rejects a file**
Open the file and check that `company:` and `role:` in the YAML front matter are filled in with actual values (not empty strings).

**PDF has no content / template error**
`templates/resume.html` must contain exactly `{{CONTENT}}` (uppercase, double braces). Check that the placeholder is present.

**`Install-Module PSSQLite` fails**
Try: `Install-Module PSSQLite -Scope CurrentUser -Force -AllowClobber`

**Playwright fails to find Chromium**
Run: `npx playwright install chromium`
