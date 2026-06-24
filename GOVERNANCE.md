# macMTP Governance

## Roles

| Role | Permissions |
|------|-------------|
| Contributor | Submit PRs, open issues |
| Regular Contributor | Review PRs, triage issues |
| Maintainer | Merge PRs, manage releases, add labels |
| Lead Maintainer | Final decisions when disagreements arise |

## Decision-Making

- **Routine changes** (bug fixes, small features, docs): one maintainer approval to merge.
- **Significant changes** (architectural, breaking API changes, new dependencies): at least two maintainer approvals and community discussion via an issue or discussion thread.
- **Disagreements**: Lead Maintainer makes the final call after discussion.

## PR Approval

- Minimum **1 maintainer approval** required before merging.
- CI checks must pass.
- Stale approvals are dismissed when new commits are pushed.
- Direct pushes to `main` are blocked — all changes go through PRs.

## Maintainer Promotion

Regular contributors who consistently submit quality reviews and patches may be invited to become maintainers. There is no set timeframe — promotion is based on trust, consistency, and alignment with the project's goals.
