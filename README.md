# claude-commands

My Claude Code commands, packaged as a plugin.

## `/explain-pr`

Reading every line of a PR is easy. Understanding it without the context is the hard part: why the author made the change, how the code worked before, why they did it this way. `/explain-pr` answers those questions in a blog-style page that opens in your browser.

It's for understanding and learning, not for commenting. Nothing is posted to GitHub.

```
/explain-pr                 # the current branch (its PR if there is one)
/explain-pr 123             # PR #123 in this repo
/explain-pr <PR URL>        # same, pasted from GitHub
```

Run it inside a checkout of the repo. Open, merged and closed PRs all work. Reading old merged PRs is a good way to learn an area of the codebase.

### What's in the report

1. **TL;DR**: what it's for, what changed, the one thing to understand.
2. **Background**: how this part of the system works *before* the change, with links to exact lines and a diagram when a flow is involved.
3. **Why this change**: the problem, quoted from the author where possible.
4. **What changed**: in the order that tells the story, not file by file.
5. **Why it was done this way**: decisions, trade-offs, alternatives considered.
6. **Before → after**: how behavior changes for users, callers and data.
7. **Reviewing it**: what to check, the risky spots, what the tests don't cover.
8. **Ask the author**: what couldn't be worked out.
9. **Sources**: everything it read.

Every claim about intent is tagged **Stated** (someone wrote it down: PR, issue, commit, human review) or **Inferred** (Claude worked it out from the code). Bot reviews such as CodeRabbit and Copilot count as Inferred. The point is to never learn a confident guess as fact.

### How it works

1. `scripts/gather.sh` collects the evidence with `gh` and `git` into `/tmp/explain-pr/<repo>-pr-<n>/`:
   - the PR description
   - linked issues and PRs, with their comments
   - commits
   - review summaries, inline threads and conversation
   - the diff
   - earlier PRs that touched the same files
   - `CLAUDE.md`/`AGENTS.md`/READMEs near the change
   - the repo's GitHub wiki

   It only uses sources everyone can reach, so the report doesn't depend on whose machine runs it.
2. Claude reads the evidence and the code at both commits (via `git show`, never from your working tree), then writes the article.
3. `scripts/render.sh` wraps it in `templates/report.html` and opens it.

Your working tree is never touched: no checkout, no stash. Uncommitted work is safe.

## Install

```
/plugin marketplace add hsk-kr/claude-commands
/plugin install claude-commands@hsk-kr
```

Requires `git`, `bash` and the [GitHub CLI](https://cli.github.com) (`gh auth login`).

To update: `/plugin marketplace update hsk-kr`, or turn on auto-update for the marketplace in `/plugin`.

If another command is already called `/explain-pr`, use the full name `/claude-commands:explain-pr`.

## Develop

```
claude --plugin-dir ~/dev/claude-commands     # load the local copy
claude plugin validate --strict .             # check the manifests
```

Run `/reload-plugins` after editing. Each command is a skill in `skills/<name>/`: a `SKILL.md` plus any scripts and templates it needs.
