# Feature 11 — Recruiter Relationship Management: Detailed Design

## 1. Overview

Feature 11 tracks recruiter and staffing vendor relationships — contact info, last-contacted date, engagement status, and priority tier — and integrates this data with the application pipeline. It surfaces recruiters overdue for follow-up and cross-references staffing vendors that also appear on the target account list.

**In-scope requirements:**

| ID | Requirement |
|----|-------------|
| L1-011 | Track recruiter/vendor contact info, last contacted date, engagement status, and priority tier; integrate with application pipeline. |
| L2-020 | `docs/recruiter-vendor-list.md` with columns: Firm Name, Priority Tier, Contact Name, Contact LinkedIn, Last Contacted Date, Current Engagement Status, Notes. Reviewed quarterly. High-priority recruiters not contacted in 90+ days surfaced as "Due for follow-up". Cross-reference with target account list. |

**Out of scope:** Automated outreach sending, CRM integration, email parsing.

---

## 2. Architecture

### 2.1 C4 Context Diagram

![C4 Context](diagrams/c4_context.png)

The candidate maintains the recruiter list and uses the job-search skill to identify follow-up actions. No external CRM systems are involved.

### 2.2 C4 Container Diagram

![C4 Container](diagrams/c4_container.png)

Two Markdown files form the data layer: `docs/recruiter-vendor-list.md` and `docs/target-accounts.md`. The job-search skill reads both to produce follow-up and cross-reference reports.

### 2.3 C4 Component Diagram

![C4 Component](diagrams/c4_component.png)

Inside the job-search skill, a Follow-Up Checker and a Cross-Reference Linker operate on recruiter and account data independently, then merge results into a single report section.

---

## 3. Component Details

### Recruiter/Vendor List (`docs/recruiter-vendor-list.md`)

- Human-maintained Markdown table reviewed quarterly.
- Columns: `Firm Name | Priority Tier | Contact Name | Contact LinkedIn | Last Contacted Date | Current Engagement Status | Notes`
- Priority Tier values: `High`, `Medium`, `Low`.
- Last Contacted Date format: `YYYY-MM-DD`.
- Current Engagement Status values: `Active`, `Passive`, `Dormant`, `Closed`.

### Follow-Up Checker (inside job-search skill)

- Reads recruiter list and parses all rows.
- For each row where Priority Tier = `High` and Last Contacted Date is ≥ 90 days before today: adds entry to "Due for follow-up" section.
- Outputs count of overdue contacts and their details.

### Cross-Reference Linker (inside job-search skill)

- Reads both `docs/recruiter-vendor-list.md` and `docs/target-accounts.md`.
- Matches on Firm Name (case-insensitive).
- For each match, notes the recruiter record should reference the target account entry and vice versa.
- Reports unlinked matches as action items.

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 Entity Descriptions

| Entity | Description |
|--------|-------------|
| `RecruiterList` | Container for all recruiter/vendor records. Backed by `docs/recruiter-vendor-list.md`. |
| `RecruiterRecord` | Single recruiter or staffing vendor contact with tier, status, and contact metadata. |
| `PriorityTier` | Enum: High, Medium, Low. Determines follow-up urgency threshold. |
| `EngagementStatus` | Enum: Active, Passive, Dormant, Closed. |
| `TargetAccount` | A company on the target account list. May overlap with recruiter firms. |
| `FollowUpReport` | Output of follow-up check: list of overdue high-priority contacts. |
| `CrossReferenceReport` | Output of cross-reference check: matched firm names with link status. |

---

## 5. Key Workflows

### 5.1 Updating a Recruiter Record

![Update Recruiter Sequence](diagrams/sequence_update_recruiter.png)

The candidate opens the recruiter list, updates the relevant row (last contacted date, status, notes), and saves. No automated write-back occurs; the skill reads the updated file on next run.

### 5.2 Checking for Follow-Up Due

![Follow-Up Check Sequence](diagrams/sequence_followup_check.png)

The job-search skill reads the recruiter list, computes days since last contact for each High-priority record, and emits a "Due for follow-up" section for any record ≥ 90 days overdue. It also performs the cross-reference check against the target account list in the same pass.

---

## 6. Security Considerations

- `docs/recruiter-vendor-list.md` contains personal contact data (LinkedIn URLs, names). It is excluded from version control via `.gitignore` (see L2-024).
- No recruiter data is sent to external services; all processing is local.
- LinkedIn URLs stored as plain text; no authentication tokens are stored in the file.

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | Should the quarterly review reminder be surfaced automatically, or only on manual trigger? | — | Open |
| 2 | Should Medium-priority recruiters have a different follow-up threshold (e.g. 180 days)? | — | Open |
| 3 | How should duplicate firm names (e.g. parent/subsidiary) be handled in cross-reference? | — | Open |
