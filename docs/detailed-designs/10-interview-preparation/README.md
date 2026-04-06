# Feature 10 — Interview Preparation: Detailed Design

## 1. Overview

Feature 10 maintains a cumulative bank of STAR+Reflection behavioral stories linked to the candidate's work history. Stories are surfaced during offer evaluation and after reaching the Interview stage, ensuring the candidate enters every interview with relevant, well-practiced narratives.

**In-scope requirements:**

| ID | Requirement |
|----|-------------|
| L1-010 | Maintain a cumulative behavioral story bank linked to work history; surface relevant stories at Interview and Offer stages. |
| L2-019 | `interview-prep/story-bank.md` — STAR+Reflection format, tagged with situation context, skills demonstrated, and mappable JD keywords. Surface ≥2 relevant stories by keyword overlap. Warn if fewer than 3 stories exist. Append-only writes. |

**Out of scope:** Automated story generation, AI story scoring, real-time interview coaching.

---

## 2. Architecture

### 2.1 C4 Context Diagram

![C4 Context](diagrams/c4_context.png)

The candidate interacts with the story bank directly via a Markdown editor and indirectly through the job-search skill when an application reaches the Interview or Offer stage. No external systems are involved.

### 2.2 C4 Container Diagram

![C4 Container](diagrams/c4_container.png)

The system consists of a single Markdown file (`interview-prep/story-bank.md`) consumed by the job-search Claude Code skill and edited manually by the candidate.

### 2.3 C4 Component Diagram

![C4 Component](diagrams/c4_component.png)

Inside the job-search skill, a Story Surfacing component reads the story bank, extracts JD keywords from the active role, computes overlap, and returns the top matching stories.

---

## 3. Component Details

### Story Bank File (`interview-prep/story-bank.md`)

- Human-edited Markdown file; append-only convention.
- Each story is a level-2 heading block containing: Situation, Task, Action, Result, Reflection sub-sections.
- YAML-style inline tags at the top of each story block:
  - `skills:` — comma-separated skill labels
  - `keywords:` — JD-mappable terms
  - `context:` — company/role/period the story comes from

### Story Surfacing Component (inside job-search skill)

- Triggered when a role transitions to `Interview` or `Offer` state in `data/pipeline.md`.
- Reads `interview-prep/story-bank.md` and parses story blocks.
- Extracts keywords from the role's JD (stored in `content/evaluations/<slug>.md`).
- Computes intersection count between story keywords and JD keywords.
- Returns top-N stories sorted by overlap score (N ≥ 2).
- Emits a warning to stdout if total story count < 3.

---

## 4. Data Model

### 4.1 Class Diagram

![Class Diagram](diagrams/class_diagram.png)

### 4.2 Entity Descriptions

| Entity | Description |
|--------|-------------|
| `StoryBank` | Container for all behavioral stories. Backed by `interview-prep/story-bank.md`. |
| `BehavioralStory` | Single STAR+Reflection narrative. Has a unique slug, free-text sections, and tag lists. |
| `StoryTag` | A keyword or skill label attached to a story for matching purposes. |
| `RoleApplication` | A job application record from `data/pipeline.md`. Carries state and JD keyword list. |
| `SurfacingResult` | Output of the keyword-overlap computation: ordered list of matched stories with scores. |

---

## 5. Key Workflows

### 5.1 Adding a New Story

![Add Story Sequence](diagrams/sequence_add_story.png)

The candidate writes a new STAR+Reflection block and appends it to `interview-prep/story-bank.md`. No automated step modifies existing entries. The skill validates tag presence on next run.

### 5.2 Surfacing Relevant Stories

![Surface Stories Sequence](diagrams/sequence_surface_stories.png)

When the job-search skill detects a role in `Interview` or `Offer` state, it reads the story bank, scores each story against the role's JD keywords, and outputs the top matches with overlap scores. If fewer than 3 stories exist in the bank, a warning is prepended to the output.

---

## 6. Security Considerations

- `interview-prep/story-bank.md` may contain personal career history; it is listed in `.gitignore` to prevent accidental public exposure (see L2-024).
- No external API calls are made during story surfacing; all processing is local.
- The file is append-only by convention; automated tooling must never truncate or rewrite existing entries.

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | Should story scores be persisted between runs, or always recomputed? | Quinntyne | Open |
| 2 | What is the maximum recommended story bank size before performance degrades? | Quinntyne | Open |
| 3 | Should stories be versioned individually (e.g. via Git tags)? | Quinntyne | Open |
