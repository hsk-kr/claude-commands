# /explain-pr: design

Date: 2026-09-29

## Problem

When reviewing a PR (or a branch), reading the lines isn't the hard part. The hard part is the missing context: why the author made the change, how the code worked before, why they chose this approach, and what you need to know to review it. The goal is understanding the change and learning the codebase for later, not posting review comments.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Keep reports as a knowledge base? | No. Write to a temp folder, open, done. | A command whose quality depends on history files on one machine gives different results on different machines. |
| Inputs | Only sources anyone can reach: GitHub (via `gh`) and git. | Same evidence for everyone, whoever runs it. |
| Scope beyond the diff | Background first (how this part works), then the change. Length scales with the PR. | The real gap is not knowing how the codebase works. |
| Language | English. | Matches the code, PRs and team vocabulary. |
| Architecture | Skill + gather script (not instructions only, not multi-agent). | The script collects the same full evidence every run. Multi-agent only kicks in for large PRs, for code exploration. |
| Packaging | A skill in a plugin, in a repo that is also its own marketplace. | Skills are the current way to make slash commands. The marketplace makes it installable and extendable. |

## Rules borrowed from existing tools

- Skills with bundled scripts for the deterministic parts.
- A codebase-guide style: cite `file:line`, never guess, say so when unsure, check project knowledge (docs, the wiki) first.
- Bot review output (CodeRabbit, Copilot) is inference, not author intent.

## Behavior

- `/explain-pr` with no argument: the current branch's PR, or the branch against the default branch when there's no PR (commits + diff only, with the gap stated).
- `/explain-pr 123` or `/explain-pr <url>`: that PR, which must be in the current checkout's repo. Open, merged and closed PRs all work.
- The working tree is never touched. The script fetches `pull/N/head` and reads through git. For a merged PR, the "before" commit is the merge base against the merge commit's first parent (today's base branch already contains the PR).
- Bundle: `/tmp/explain-pr/<repo>-<id>/`. Report: `/tmp/explain-pr/<repo>-<id>.html`, opened in the browser. A rerun overwrites both.

## Report

Header → TL;DR → Background → Why → What changed → Why this way → Before/after → Reviewing it → Ask the author → Sources. Every intent claim is tagged Stated (with its source) or Inferred. Code facts link to the exact line at the before or after SHA.

## Files

- `skills/explain-pr/SKILL.md`: procedure, evidence rules, markup contract.
- `skills/explain-pr/scripts/gather.sh`: evidence collection plus the manifest (injected into the skill with `!`).
- `skills/explain-pr/scripts/render.sh`: fragment + template → HTML, opens it.
- `skills/explain-pr/templates/report.html`: design (light/dark, TOC, highlight.js, Mermaid).

## Testing

- `claude plugin validate --strict` on the marketplace, plugin and skills.
- `gather.sh` on merged PRs, an open PR, a PR URL, a URL from another repo, a bad argument, and a branch with no PR.
- End-to-end with `claude -p "/explain-pr <n>" --plugin-dir .` on real PRs, checking the report for accuracy against the PR.
- Install from the GitHub marketplace and confirm `/explain-pr` resolves.
