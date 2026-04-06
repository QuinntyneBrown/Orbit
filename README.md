# Orbit

A career management and job search automation platform.

Orbit maintains a single source of truth for resume content, automates document generation, tracks the full application pipeline, and drives structured job discovery and evaluation — reducing manual effort during high-volume search periods.

## What it does

- **Resume management** — version-controlled Markdown source files for base and tailored resume variants
- **Document generation** — converts Markdown to professional Word (.docx) and PDF outputs suitable for ATS submission
- **Application pipeline** — tracks every role through a defined lifecycle, linked to tailored resumes, source, dates, and compensation details
- **Offer evaluation** — scores job postings across weighted dimensions before tailoring effort is invested
- **Job discovery** — searches job boards, company portals, and recruiter boards for roles matching a configured candidate profile
- **Deduplication and history** — persists search results across runs, surfaces net-new postings and status changes
- **Compensation research** — estimates market rates for roles that do not list pay
- **Outreach management** — generates LinkedIn messages, email drafts, and recruiter follow-ups
- **Interview prep** — maintains a STAR+Reflection story bank linked to work history
- **Recruiter CRM** — tracks contacts, engagement status, and priority tier
- **Workflow automation** — multi-step automation for variant creation, batch tailoring, doc builds, and base resume sync

## Project structure

```
docs/
  specs/        # Requirements documents (L1 high-level, L2 detailed)
```

## Requirements

See [`docs/specs/L1.md`](docs/specs/L1.md) for high-level requirements.
