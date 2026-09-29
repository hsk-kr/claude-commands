---
name: explain-pr
description: Explain a pull request, or the current branch, as a blog-style HTML page that opens in the browser, covering why it was made, how the code worked before, what changed, why it was done that way and what to check. For understanding and learning a codebase through its PRs, not for posting review comments. Use when asked to explain, walk through or give context on a PR or branch.
argument-hint: "[pr-number | pr-url]"
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/gather.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/render.sh *)
  - Bash(git show *)
  - Bash(git log *)
  - Bash(git grep *)
  - Bash(git blame *)
  - Bash(git diff *)
  - Bash(git ls-tree *)
  - Bash(gh pr view *)
  - Bash(gh issue view *)
  - Read(//tmp/explain-pr/**)
  - Read(//private/tmp/explain-pr/**)
  - Edit(//tmp/explain-pr/**)
  - Edit(//private/tmp/explain-pr/**)
  - Grep
  - Glob
---

# /explain-pr

Write a blog-style explainer of a pull request for someone who has to review it but lacks the context: a capable developer who doesn't know this part of the codebase, or why the change was made. The page exists so they understand the change and learn the codebase. It is not a review, and nothing is posted to GitHub.

## Context bundle

!`"${CLAUDE_SKILL_DIR}/scripts/gather.sh" '$ARGUMENTS'`

If no manifest appears above (the line shows as plain text, or shell execution is disabled), run `${CLAUDE_SKILL_DIR}/scripts/gather.sh '$ARGUMENTS'` yourself. If it printed an `explain-pr:` error, tell the user that error in one line and stop.

The manifest gives you the two commits that matter: **before** (the merge base) and **after** (the PR head). Everything below uses them.

## 1. Read the evidence

Read the bundle files in this order: `pr.md`, `issues.md`, `commits.md`, `threads.md`, `diffstat.txt`, then `diff.patch`. Then:

- `history.md`: earlier PRs that touched the same files. Use them to explain why the code looked the way it did before this change.
- `docs.md`: read the `CLAUDE.md` / `AGENTS.md` / `README.md` files on the path to the changed code.
- `wiki/` (if present): search it with the Grep tool (it sits outside the repo, so `git grep` can't see it) for the main nouns of the change (feature, module, table and flag names), then read the pages that match.

The reference scan is mechanical. Ignore linked items that turn out to be unrelated, such as a `#1` from a numbered list.

## 2. Understand the code before and after

Read the code, not only the diff. **The working tree is at neither commit and may hold the user's uncommitted work. Never read changed files from the working tree, and never check out, stash, reset or switch branches.** Read through git instead:

- Old version: `git show <before>:<path>`. New version: `git show <after>:<path>`.
- Callers and usages: `git grep -n '<symbol>' <before>` (or `<after>`).
- Line numbers for links: `git grep -n '<text>' <sha> -- <path>`.
- Why a line exists: `git log -L <start>,<end>:<path> <before>` or `git blame <before> -- <path>`.

The session already runs in the repo root, and these git commands are pre-approved only in their plain form. Run **one git command per call**, with the full SHA written out. Don't use `cd`, `git -C`, pipes, `&&`, `;` or shell variables, or you'll trigger permission prompts. Read the bundle files with the Read tool, not `cat`.

For the Background section, trace the flow the PR touches end to end in the **before** state: where it starts (route, job, UI event, CLI), what it passes through, and where it ends up (DB write, response, side effect).

Stop researching once you can back every section with evidence. Chasing every usage of every symbol makes the page slower to produce, not better. As a rough budget, a small PR needs about 20 code lookups and a medium one about 40.

How much to do yourself depends on the size in the manifest:

- **small / medium**: do it all yourself.
- **large**: split the code exploration. Spawn up to 3 Explore subagents in parallel, each with one concrete question, e.g. "At commit `<before>`, trace how a signup request goes from the route handler to the database write. Report `file:line` for each hop." Subagents don't see this skill, so give each one the repo path, both SHAs, the rule to read through `git show` / `git grep` only, and what to report. Write the article yourself from their findings.

## 3. Write the article

Write the article to the `article.html` path from the manifest. It is an HTML **fragment**: a `header.hero` followed by `section`s. Don't include `<html>`, `<head>`, `<style>` or `<script>`. The template supplies the page, fonts, light/dark theme, table of contents, syntax highlighting and diagram rendering.

Scale the length to the change. A small PR can be 500 words. A large one can run past 3,000. Sections, in order (the `h2` ids feed the table of contents):

1. **`header.hero`**
   - Kicker: `<p class="kicker">owner/repo · PR #123 · merged</p>`. For a branch with no PR: `owner/repo · branch name · no PR yet`.
   - `h1`: a plain-English title. You may rephrase the PR title so a newcomer understands it.
   - `p.dek`: one sentence saying what this is about.
   - `dl.meta`: author, base ← head, size, linked issues (as links), and the opened/merged date.
2. **TL;DR** (`section.tldr`, `h2#tldr`): three short sentences or bullets covering what it's for, what changed, and the one thing to understand.
3. **Background: how this part works** (`#background`): for someone new to this area. Cover what this part of the system is for, the main pieces, and how data and control flow through them *before* the change, with `file:line` links. Define domain terms on first use, or add a `dl.terms` glossary when there are many. Add a diagram when a flow or relationship is involved. Stop at what the reader needs to follow the change; this is not a tour of the repo.
4. **Why this change** (`#why`): the problem or motivation. Quote the author where you can.
5. **What changed** (`#what`): walk through the change in the order that tells the story (cause before effect, core logic before plumbing), not file by file. Collapse mechanical edits into one line, e.g. "the rename touches 15 files". Show the key snippets, before and after.
6. **Why it was done this way** (`#design`): decisions, trade-offs, and alternatives that were considered and why they lost (from threads and issues). When nothing is written down, reason it out carefully and tag it Inferred.
7. **Before → after** (`#before-after`): how behavior changes for users, callers and data. Use a `.compare` grid or a table. Include migrations, data backfills and rollout effects.
8. **Reviewing it** (`#review`): a `ul.checklist` of what a reviewer should verify. Include the riskiest spots (with links), edge cases, and what the tests cover and don't (check the test files in the diff). No style nits.
9. **Ask the author** (`#questions`): an `ol.questions` list of what you couldn't determine. Only real questions.
10. **Sources** (`#sources`): a `ul.sources` list of everything you used (PR, issues, earlier PRs, wiki pages, docs), with links.

TL;DR, Background, Why, What changed and Sources are always present. Leave out any other section that would be empty.

### Evidence rules (the most important part)

The reader will learn from this page and repeat it to teammates, so a confident guess is worse than an admitted gap.

- **Every claim about intent or reasoning** (why, why this way, which alternatives) gets a tag right after it:
  - `<span class="tag stated">Stated · PR description</span>` when a person wrote it down: the PR description, an issue, a commit message or a human review comment. Name the source inside the tag. When the exact wording matters, quote it: `<blockquote class="source"><p>…</p><cite><a href="…">PR description</a></cite></blockquote>`.
  - `<span class="tag inferred">Inferred</span>` when you worked it out from the code. **Bot output is Inferred too**: CodeRabbit, Copilot and anything marked `[bot, treat as inference]` in the bundle summarize the change, they don't know the author's intent.
- **Facts about code** (what a function does, what calls what) don't need a tag, but they need a link to the exact line. Use the before SHA for old code and the after SHA for new code: `<a class="ref" href="https://github.com/owner/repo/blob/<sha>/<path>#L<n>"><code>path/file.ts:42</code></a>`. Check each line number with `git grep -n` before linking.
- Treat PRs in `history.md` as the reason for something only when the connection is clear. Say so and tag it: "#123 introduced the `legacy_` prefix <span class="tag stated">Stated · #123</span>".
- When you can't determine something, say so plainly and add it to Ask the author. Never fill a gap with a plausible-sounding reason.
- Mention any gap listed in the manifest (e.g. no PR description) where it's relevant.

### Markup

```html
<aside class="callout"><p><strong>Note</strong> Useful aside.</p></aside>
<aside class="callout warn"><p><strong>Watch out</strong> A risk or gotcha.</p></aside>

<figure class="code">
  <figcaption><code>src/billing/validate.ts</code> · before</figcaption>
  <pre><code class="language-ts">if (a &lt; b) { … }</code></pre>
</figure>

<div class="compare">
  <div class="before"><h4>Before</h4><p>…</p></div>
  <div class="after"><h4>After</h4><p>…</p></div>
</div>

<figure class="diagram">
  <pre class="mermaid">flowchart LR
  A["POST /signup"] --> B["validate()"] --> C[("users table")]</pre>
  <figcaption>How a signup is handled before this change.</figcaption>
</figure>

<dl class="terms"><dt>Term</dt><dd>Meaning in this codebase.</dd></dl>
```

Tables, `h3` subheadings, lists, `code` and links all work as normal HTML.

- **Code:** HTML-escape `&`, `<` and `>` inside `pre`/`code`. Set the language class (`language-ts`, `language-ruby`, `language-sql`, `language-diff`, …). Keep snippets to about 25 lines and trim the rest with `// …`. A `language-diff` block works well for small before/after changes.
- **Diagrams:** Mermaid `flowchart TD` or `sequenceDiagram`, with about 12 nodes at most. The column is 720px wide, so use `flowchart LR` only for chains of about 5 nodes or fewer. Quote labels that contain punctuation: `A["api/x.ts: handle()"]`. Escape `<` `>` `&`. Only draw one when it's clearer than prose.

### Style

- English, plain words, short paragraphs. Write for a smart developer who is new to this code.
- Explain why things matter and connect them to the wider system, not just what the lines do.
- Use the real names from the code (functions, tables, flags, settings) in `<code>`.
- No filler ("This PR introduces…"), no praise, no verdict on the author.

## 4. Render and finish

Run `${CLAUDE_SKILL_DIR}/scripts/render.sh <bundle-dir>`. It wraps the article in the template, writes `<bundle-dir>.html` and opens it in the browser. If it rejects the article, fix the article and run it again.

Then reply in the terminal with two or three lines: one sentence on what the PR is for, plus the report path.

## Never

- Check out, stash, reset, commit or push, or change the user's working tree in any other way.
- Post comments or reviews, or run any `gh` command that writes to GitHub.
- Write anywhere except the bundle directory.
