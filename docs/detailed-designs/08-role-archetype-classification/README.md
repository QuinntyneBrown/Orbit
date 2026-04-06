# Role Archetype Classification — Detailed Design

## 1. Overview

Feature 08 classifies every discovered job posting into exactly one of five role archetypes. The archetype informs evaluation weighting, resume tailoring emphasis, and pipeline tracker display. Downstream features (outreach generation, offer evaluation) consume the archetype to apply archetype-specific logic.

**Stories covered:**
- **L2-017** — Role Archetype Classification: classify each listing into one of five archetypes; surface in results, evaluations, and tracker. Apply archetype-specific flags and defaults.

**Archetypes defined:**

| Archetype | Key Signal | Special Rule |
|---|---|---|
| `Enterprise Contract` | Staff aug, contract-to-hire, large SI | Recommend focused base resume |
| `Product Company` | SaaS, ISV, product engineering | — |
| `Consulting Firm` | Agency, advisory, professional services | — |
| `AI / Innovation` | AI/ML, GenAI, R&D, deep tech | — |
| `Government / Public Sector` | Federal, provincial, municipal, crown corp | Flag for security clearance reference |

Unknown postings default to `Enterprise Contract` with `[Archetype: inferred]` flag.

**Design constraints:**
- Every `job_listings` row must carry exactly one archetype (NULL not permitted after classification)
- Classification is deterministic given the listing content
- No external API calls; classification uses keyword heuristics against title and description

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

### 3.1 ArchetypeClassificationOrchestrator

**Module:** `scripts/modules/Invoke-ArchetypeClassification.psm1`

Iterates `job_listings` rows for the current `scan_run_id` where `archetype IS NULL` and dispatches each to the classifier. Updates the `archetype`, `archetype_inferred`, and `is_priority_recruiter` columns via UPDATE after classification.

### 3.2 ArchetypeClassifier
Applies a prioritised keyword rule set against the listing title, company name, and description body. Returns an `ArchetypeResult` containing the matched archetype and a boolean `isInferred` flag.

### 3.3 ArchetypeRuleSet

**Config file:** `config/archetype-rules.json` (resolves Open Question 1)

Configuration data: an ordered list of archetype rules, each containing a set of keyword patterns and a target archetype. Evaluated in priority order; first match wins.

**Priority order and example rules:**

The evaluation order is fixed and intentional — `Government / Public Sector` is checked first because it carries a mandatory security clearance flag that must never be suppressed by another archetype (resolves Open Question 2):

| Priority | Archetype | Example keyword patterns |
|----------|-----------|--------------------------|
| 1 | `Government / Public Sector` | `federal`, `provincial`, `municipal`, `crown`, `public sector`, `government`, `dnd`, `cra`, `gc.ca`, `security clearance` |
| 2 | `AI / Innovation` | `ai`, `ml`, `machine learning`, `llm`, `genai`, `generative ai`, `deep learning`, `r&d`, `research engineer` |
| 3 | `Consulting Firm` | `consulting`, `advisory`, `professional services`, `accenture`, `deloitte`, `kpmg`, `mckinsey`, `agency` |
| 4 | `Product Company` | `saas`, `isv`, `product engineering`, `platform`, `startup`, `series`, `b2b software` |
| 5 | `Enterprise Contract` | `staff augmentation`, `contract-to-hire`, `t&m`, `body shop`, `staffing`, *(default fallback)* |

Multi-signal listings (e.g., a government AI contract) are assigned the highest-priority matching archetype (`Government / Public Sector`). The `[Archetype: inferred]` flag is only set when no rule matches and the default fallback fires.

### 3.4 ArchetypeFlagHandler
Post-processes the classified listing to apply archetype-specific side effects: recommending the base resume for `Enterprise Contract`, adding a security clearance flag for `Government / Public Sector`, and appending `[Archetype: inferred]` when no rule matched.

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 Entity Descriptions

| Entity | Description |
|---|---|
| `JobListing` | Maps to `job_listings` row. `archetype` and `archetype_inferred` columns are set by classification. |
| `ArchetypeResult` | Output of classification: the matched `Archetype` enum value and `IsInferred` boolean. |
| `Archetype` | Enum of the five defined archetypes plus an `Unknown` sentinel. |
| `ArchetypeRule` | One rule in the rule set: a priority rank, a list of keyword patterns, and a target archetype. |
| `ArchetypeRuleSet` | Ordered collection of `ArchetypeRule` entries; evaluated top-to-bottom. |
| `ArchetypeFlags` | Bit-set of flags applied post-classification: `RecommendBaseResume`, `FlagClearance`, `Inferred`. |

---

## 5. Key Workflows

### 5.1 Classify Listing

![Classify Listing Sequence](diagrams/sequence_classify_listing.png)

Each listing passes through the classifier, which evaluates rules in priority order. The first matching rule determines the archetype. If no rule matches, `Enterprise Contract` is assigned with the `Inferred` flag. Post-classification, `ArchetypeFlagHandler` applies any archetype-specific side effects before the listing is written back to the result set.

---

## 6. API Contracts

This module is invoked automatically by the Job Search Orchestrator (Feature 05) after deduplication and before the dated export is written.

**PowerShell function signatures:**

```powershell
function Invoke-ArchetypeClassification {
    param (
        [Parameter(Mandatory)] [JobListing[]] $Listings
    )
    # Returns: [JobListing[]] with Archetype and ArchetypeFlags populated on each listing
}

function Get-Archetype {
    param (
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Company,
        [string] $Description = ""
    )
    # Returns: [ArchetypeResult] @{ Archetype; IsInferred }
    # Loads rules from config/archetype-rules.json on first call (cached for session)
}
```

**Rule file schema (`config/archetype-rules.json`):**

```json
[
  {
    "priority": 1,
    "archetype": "Government / Public Sector",
    "patterns": ["federal", "provincial", "crown", "security clearance"]
  },
  {
    "priority": 2,
    "archetype": "AI / Innovation",
    "patterns": ["ai", "ml", "machine learning", "genai"]
  }
]
```

Rules are evaluated in ascending `priority` order. Patterns are matched case-insensitively against the concatenated `title + company + description` string.

---

## 7. Security Considerations

- The `Government / Public Sector` archetype triggers a clearance flag, ensuring the candidate does not omit clearance references from applications to those roles.
- Classification rules are stored in plaintext configuration; they do not contain sensitive data.
- Misclassification to `Enterprise Contract` is the safe default; it never silently drops a security-relevant flag.

---

## 8. Open Questions

1. Should the rule set be stored in a dedicated `config/archetype-rules.json` file to allow updates without touching scripts?
2. How should multi-signal listings be handled — e.g. a government AI contract that matches both `AI / Innovation` and `Government / Public Sector`?
3. Should classification confidence be tracked separately from the `Inferred` flag for reporting purposes?
4. Is a manual override mechanism needed (e.g. a comment in the TSV) to correct misclassified listings without re-running the full pipeline?
