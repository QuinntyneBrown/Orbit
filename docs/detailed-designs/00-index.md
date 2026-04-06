# Detailed Designs — Index

| # | Feature | Status | Description |
|---|---------|--------|-------------|
| 01 | [Resume Content Management](01-resume-content-management/README.md) | Draft | Base resume structure, notes template enforcement, and outreach file organization |
| 02 | [Document Generation](02-document-generation/README.md) | Draft | Markdown → Word (.docx) via Pandoc, Markdown → PDF via Playwright, base resume sync verification |
| 03 | [Application Pipeline Tracking](03-application-pipeline-tracking/README.md) | Draft | Pipeline Markdown table, canonical eight-state status model, validation |
| 04 | [Offer Evaluation](04-offer-evaluation/README.md) | Draft | Structured evaluation template, five-dimension weighted scoring (1.0–5.0), evaluation report storage |
| 05 | [Job Search and Discovery](05-job-search-and-discovery/README.md) | Draft | Job board search, company portal scanner (--scan-portals), recruiter board search (--recruiter-boards) |
| 06 | [Search History and Deduplication](06-search-history-and-deduplication/README.md) | Draft | TSV persistence, Company+Title deduplication, dated export files with rolling 8-file window |
| 07 | [Compensation Research](07-compensation-research/README.md) | Draft | Market rate estimation for unrated postings with range, confidence qualifier, and cited sources |
| 08 | [Role Archetype Classification](08-role-archetype-classification/README.md) | Draft | Five-archetype classification system with fallback default and security clearance flag |
| 09 | [Outreach Management](09-outreach-management/README.md) | Draft | LinkedIn message generation for Strong Match listings (score ≥ 4.5), versioned file output |
| 10 | [Interview Preparation](10-interview-preparation/README.md) | Draft | STAR+Reflection story bank, keyword-based story surfacing, append-only convention |
| 11 | [Recruiter Relationship Management](11-recruiter-relationship-management/README.md) | Draft | Recruiter tracking table, 90-day follow-up rule, cross-reference with target account list |
| 12 | [Workflow Automation](12-workflow-automation/README.md) | Draft | new-variant.ps1 variant creation, batch-tailor.ps1 parallel job execution (max 4 concurrent) |
| 13 | [Skill Infrastructure](13-skill-infrastructure/README.md) | Draft | Startup validation (existence, staleness, live read), .gitignore enforcement, output format standardization |
