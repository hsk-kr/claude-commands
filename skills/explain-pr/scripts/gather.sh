#!/usr/bin/env bash
# Collects everything /explain-pr needs about a PR (or the current branch) into
# /tmp/explain-pr/<repo>-<id>/ and prints a manifest for Claude to work from.
#
# Only uses sources every machine can reach (GitHub + git), so two people
# running it on the same PR start from the same evidence.
#
# Never touches the working tree: no checkout, stash or commit. It only
# fetches commits and reads them.
#
# usage: gather.sh [pr-number | #pr-number | pr-url]
set -euo pipefail

OUT_ROOT="${EXPLAIN_PR_OUT:-/tmp/explain-pr}"
MAX_REFS=8            # linked issues / PRs to pull in
MAX_HISTORY_FILES=15  # changed files to look up history for
MAX_HISTORY_PRS=6     # earlier PRs to pull in
HISTORY_BODY_CHARS=2500
BOT_BODY_CHARS=4000
LARGE_LINES=800
LARGE_FILES=25

# Lockfiles and generated files: kept out of diff.patch, still listed in the stat.
EXCLUDES=(':(exclude)*.lock' ':(exclude)*package-lock.json' ':(exclude)*pnpm-lock.yaml'
  ':(exclude)*go.sum' ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.snap'
  ':(exclude)*.map')

die() { echo "explain-pr: $*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
lines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
gap() { printf -- '- %s\n' "$*" >> "$DIR/gaps.txt"; }

command -v gh >/dev/null || die "the GitHub CLI (gh) is required: https://cli.github.com"
git rev-parse --git-dir >/dev/null 2>&1 || die "run this inside a git checkout of the repo"
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "couldn't work out the GitHub repo for this checkout (is gh logged in? with several remotes, run: gh repo set-default)"
REPO_NAME=${REPO#*/}

# The remote that points at $REPO (not always "origin", e.g. fork setups).
REMOTE=origin
for r in $(git remote); do
  case "$(lower "$(git remote get-url "$r")")" in
    *"$(lower "$REPO")"|*"$(lower "$REPO").git") REMOTE=$r; break ;;
  esac
done
fetch() { git fetch --quiet --no-tags "$REMOTE" "$@" 2>/dev/null; }

# --- which PR? ---------------------------------------------------------------
ARG="${1:-}"
PR=""
case "$ARG" in
  "")
    PR=$(gh pr view --json number --jq .number 2>/dev/null || true) ;;
  *github.com/*/pull/*)
    url_repo=$(printf '%s' "$ARG" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#')
    PR=$(printf '%s' "$ARG" | sed -E 's#.*/pull/([0-9]+).*#\1#')
    [ "$(lower "$url_repo")" = "$(lower "$REPO")" ] \
      || die "that PR is in $url_repo but this checkout is $REPO. cd into a checkout of $url_repo and run it again" ;;
  *)
    PR=${ARG#\#}
    [[ "$PR" =~ ^[0-9]+$ ]] || die "usage: /explain-pr [pr-number | pr-url]" ;;
esac

if [ -n "$PR" ]; then
  MODE=pr
  ID="pr-$PR"
else
  MODE=branch
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != HEAD ] || die "detached HEAD with no PR. Pass a PR number, e.g. /explain-pr 123"
  ID="branch-$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '-')"
fi

DIR="$OUT_ROOT/$REPO_NAME-$ID"
rm -rf "$DIR"
mkdir -p "$DIR"
: > "$DIR/gaps.txt"

# --- resolve before (merge base) and after (head) commits --------------------
if [ "$MODE" = pr ]; then
  IFS=$'\t' read -r HEAD_OID BASE_REF BASE_OID MERGE_OID STATE AUTHOR URL < <(
    gh pr view "$PR" --json headRefOid,baseRefName,baseRefOid,mergeCommit,state,author,url \
      --jq '[.headRefOid, .baseRefName, .baseRefOid, (.mergeCommit.oid // "-"), .state, (.author.login // "ghost"), .url] | @tsv'
  ) || die "couldn't load PR #$PR from $REPO"
  gh pr view "$PR" --json title --jq .title > "$DIR/title.txt"

  fetch "pull/$PR/head" || die "couldn't fetch PR #$PR's commits from $REMOTE"
  git cat-file -e "$HEAD_OID^{commit}" 2>/dev/null || die "PR #$PR's head commit $HEAD_OID isn't reachable"

  # A merged PR's head is already inside the base branch, so the merge base
  # against today's base branch would be the head itself. Use the commit the
  # base branch was on just before the merge instead.
  if [ "$MERGE_OID" != "-" ] && { git cat-file -e "$MERGE_OID^{commit}" 2>/dev/null || fetch "$MERGE_OID"; }; then
    BEFORE_TIP="$MERGE_OID^1"
  elif fetch "$BASE_REF"; then
    BEFORE_TIP=$(git rev-parse FETCH_HEAD)
  elif fetch "$BASE_OID"; then
    BEFORE_TIP=$BASE_OID
  else
    die "couldn't fetch the base branch $BASE_REF"
  fi
else
  DEFAULT=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
  BASE_REF=$DEFAULT
  if fetch "$DEFAULT"; then
    BEFORE_TIP=$(git rev-parse FETCH_HEAD)
  elif git rev-parse -q --verify "$REMOTE/$DEFAULT" >/dev/null; then
    BEFORE_TIP="$REMOTE/$DEFAULT"
    gap "Couldn't fetch $DEFAULT; compared against the local $REMOTE/$DEFAULT, which may be stale."
  else
    die "couldn't find the default branch $DEFAULT"
  fi
  HEAD_OID=$(git rev-parse HEAD)
  STATE="no PR yet"
  AUTHOR=$(git log -1 --format=%an HEAD)
  URL="-"
  printf '%s\n' "$BRANCH" > "$DIR/title.txt"
  gap "No PR exists for $BRANCH, so there is no PR description, linked issue or review thread. The 'why' can only come from commits and code."
  [ -z "$(git status --porcelain --untracked-files=no)" ] \
    || gap "The working tree has uncommitted changes; they are NOT part of this explanation (only committed work is)."
fi

BASE=$(git merge-base "$BEFORE_TIP" "$HEAD_OID") || die "couldn't find a merge base"
[ "$BASE" != "$HEAD_OID" ] || die "nothing to explain: $HEAD_OID has no commits beyond $BASE_REF. Pass a PR number, e.g. /explain-pr 123"
TITLE=$(cat "$DIR/title.txt")

# --- the change itself ---------------------------------------------------------
git diff --stat=120 "$BASE" "$HEAD_OID" > "$DIR/diffstat.txt"
git diff -M --numstat "$BASE" "$HEAD_OID" > "$DIR/.numstat"
git diff -M "$BASE" "$HEAD_OID" -- . "${EXCLUDES[@]}" > "$DIR/diff.patch"
EXCLUDED=$(git diff --name-only "$BASE" "$HEAD_OID" | grep -E '(\.lock|package-lock\.json|pnpm-lock\.yaml|go\.sum|\.min\.(js|css)|\.snap|\.map)$' | tr '\n' ' ' || true)
FILES=$(lines "$DIR/.numstat")
CHANGED=$(git diff --numstat "$BASE" "$HEAD_OID" -- . "${EXCLUDES[@]}" | awk '{ a += ($1 == "-" ? 0 : $1); d += ($2 == "-" ? 0 : $2) } END { print a + d }')
SIZE=small
[ "$CHANGED" -gt 150 ] && SIZE=medium
{ [ "$CHANGED" -gt "$LARGE_LINES" ] || [ "$FILES" -gt "$LARGE_FILES" ]; } && SIZE=large

git log --reverse --no-merges --format='### %h %s%n%nAuthor: %an, %as%n%n%b' "$BASE..$HEAD_OID" > "$DIR/commits.md"
COMMITS=$(git rev-list --count --no-merges "$BASE..$HEAD_OID")

# --- PR description, discussion and linked issues --------------------------------
TRUNC_BOT="if .user.type == \"Bot\" and (.body | length) > $BOT_BODY_CHARS then .body[0:$BOT_BODY_CHARS] + \"\n…[truncated]\" else .body end"
WHO='"@\(.user.login)\(if .user.type == "Bot" then " [bot, treat as inference]" else "" end)"'

if [ "$MODE" = pr ]; then
  gh pr view "$PR" --json number,title,url,state,isDraft,author,createdAt,mergedAt,baseRefName,headRefName,additions,deletions,changedFiles,labels,body,closingIssuesReferences --jq '
    "# \(.title)\n",
    "- PR: #\(.number) \(.url)",
    "- Author: @\(.author.login)",
    "- State: \(.state)\(if .isDraft then " (draft)" else "" end), created \(.createdAt), merged \(.mergedAt // "-")",
    "- Base ← head: \(.baseRefName) ← \(.headRefName)",
    "- Size: +\(.additions) −\(.deletions) across \(.changedFiles) files",
    "- Labels: \([.labels[].name] | join(", ") | if . == "" then "-" else . end)",
    "- Closes: \([.closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name)#\(.number)"] | join(", ") | if . == "" then "-" else . end)",
    "\n## Description (written by the author)\n",
    (.body // "" | if . == "" then "(empty)" else . end)' > "$DIR/pr.md"

  {
    echo "# Discussion on #$PR"
    echo
    echo "## Review summaries"
    echo
    gh api "repos/$REPO/pulls/$PR/reviews" --paginate --jq ".[] | select(.body != \"\") |
      \"### Review by \($WHO): \(.state) (\(.submitted_at))\n\n\($TRUNC_BOT)\n\""
    echo "## Inline comments (threads: a reply names the id it answers)"
    echo
    gh api "repos/$REPO/pulls/$PR/comments" --paginate --jq ".[] |
      \"### [id \(.id)] \(.path):\(.line // .original_line // \"?\") by \($WHO)\(if .in_reply_to_id then \" (reply to \(.in_reply_to_id))\" else \"\" end)\n\" +
      (if .in_reply_to_id then \"\" else \"\n\`\`\`diff\n\(.diff_hunk | split(\"\n\") | .[-6:] | join(\"\n\"))\n\`\`\`\n\" end) +
      \"\n\($TRUNC_BOT)\n\""
    echo "## Conversation"
    echo
    gh api "repos/$REPO/issues/$PR/comments" --paginate --jq ".[] |
      \"### \($WHO) (\(.created_at))\n\n\($TRUNC_BOT)\n\""
  } > "$DIR/threads.md"
  REVIEWS=$(grep -c '^### Review by' "$DIR/threads.md" || true)
  INLINE=$(grep -c '^### \[id ' "$DIR/threads.md" || true)

  # Linked issues/PRs: closing references first, then anything the description
  # or commit messages mention (#12, owner/repo#12, or a full URL).
  gh pr view "$PR" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name)#\(.number)"' > "$DIR/.refs"
  gh pr view "$PR" --json body --jq '.body // ""' > "$DIR/.body"
else
  : > "$DIR/threads.md"; : > "$DIR/.refs"; : > "$DIR/.body"
  REVIEWS=0; INLINE=0
fi
git log --format=%B "$BASE..$HEAD_OID" >> "$DIR/.body"
grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' "$DIR/.body" \
  | sed -E "s@https://github\.com/([^/]+/[^/]+)/(issues|pull)/([0-9]+)@\1#\3@; s@^#@$REPO#@" >> "$DIR/.refs" || true
# The scan also catches things like CSS colours (#333), so try up to 3x the
# limit and count only the refs that resolve.
REFS=$(awk -v self="$(lower "$REPO#${PR:-none}")" '{ k = tolower($0) } k != self && !seen[k]++' "$DIR/.refs" | head -n $((MAX_REFS * 3)))

: > "$DIR/issues.md"
FOUND_REFS=""
FOUND=0
for ref in $REFS; do
  [ "$FOUND" -lt "$MAX_REFS" ] || break
  repo=${ref%#*}; num=${ref##*#}
  gh api "repos/$repo/issues/$num" --jq "
    \"# \(if .pull_request then \"PR\" else \"Issue\" end) $ref: \(.title)\n\",
    \"- \(.html_url)\",
    \"- State: \(.state), opened by \($WHO)\n\",
    (.body // \"\" | if . == \"\" then \"(empty)\" else . end), \"\"" >> "$DIR/issues.md" 2>/dev/null || continue
  gh api "repos/$repo/issues/$num/comments" --paginate --jq ".[] |
    \"## Comment by \($WHO) (\(.created_at))\n\n\($TRUNC_BOT)\n\"" >> "$DIR/issues.md" 2>/dev/null || true
  FOUND_REFS="$FOUND_REFS $ref"
  FOUND=$((FOUND + 1))
done
[ -n "$FOUND_REFS" ] || [ "$MODE" = branch ] || gap "No linked issue or referenced PR was found."

# --- history of the touched code ----------------------------------------------
# Earlier PRs that shaped these files, from first-parent history of the base
# branch. Works with merge commits ("... (#12)", "Merge pull request #12") and
# squash merges.
: > "$DIR/.history_files"
: > "$DIR/.hist_prs"
sort -t$'\t' -k1,1nr "$DIR/.numstat" | awk -F'\t' '$1 != "-" { print $3 }' \
  | grep -vE '(\.lock|package-lock\.json|pnpm-lock\.yaml|go\.sum|\.min\.(js|css)|\.snap|\.map)$' \
  | grep -v ' => ' | head -n "$MAX_HISTORY_FILES" > "$DIR/.hist_files" || true
while IFS= read -r f; do
  git cat-file -e "$BASE:$f" 2>/dev/null || continue
  log=$(git log --first-parent -n 6 --format='%h %as %an: %s' "$BASE" -- "$f")
  [ -n "$log" ] || continue
  printf '### %s\n\n%s\n\n' "$f" "$log" >> "$DIR/.history_files"
  printf '%s\n' "$log" | sed -nE 's/.*\(#([0-9]+)\)$/\1/p; s/.*Merge pull request #([0-9]+).*/\1/p' >> "$DIR/.hist_prs"
done < "$DIR/.hist_files"

HIST_PRS=$(sort "$DIR/.hist_prs" | uniq -c | sort -k1,1nr -k2,2nr | awk -v self="${PR:-none}" '$2 != self { print $2 }' | head -n "$MAX_HISTORY_PRS")
{
  echo "# Earlier PRs that touched the same files"
  echo
  [ -n "$HIST_PRS" ] || echo "(none found in commit subjects)"
  for n in $HIST_PRS; do
    gh pr view "$n" --json number,title,author,mergedAt,url,body --jq "
      \"## #\(.number) \(.title)\n\",
      \"- \(.url), by @\(.author.login), merged \(.mergedAt // \"-\")\n\",
      (.body // \"\" | if length > $HISTORY_BODY_CHARS then .[0:$HISTORY_BODY_CHARS] + \"\n…[truncated]\" else . end), \"\"" 2>/dev/null || true
  done
  echo "# Recent commits per changed file (base branch, before this change)"
  echo
  cat "$DIR/.history_files"
} > "$DIR/history.md"

# --- project knowledge ----------------------------------------------------------
# Docs checked into the repo near the change, plus the repo's GitHub wiki.
{
  echo "# Project docs at the head commit"
  echo
  echo "## Agent / contributor guides and READMEs on the path to changed files"
  echo
  awk -F'\t' '{ print $3 }' "$DIR/.numstat" | sed -E 's#\{[^}]*=> ([^}]*)\}#\1#; s#.* => ##' \
    | while IFS= read -r f; do
        d=$(dirname "$f")
        while :; do
          for doc in CLAUDE.md AGENTS.md README.md; do
            p="$doc"; [ "$d" = . ] || p="$d/$doc"
            echo "$p"
          done
          [ "$d" = . ] && break
          d=$(dirname "$d")
        done
      done | awk '!seen[$0]++' | while IFS= read -r p; do
        git cat-file -e "$HEAD_OID:$p" 2>/dev/null && echo "- $p"
      done
  echo
  echo "## Other agent guides in the repo"
  echo
  git ls-tree -r --name-only "$HEAD_OID" | grep -E '(^|/)(CLAUDE|AGENTS)\.md$' | sed 's/^/- /' | head -n 40
  echo
  echo "## docs/ folders"
  echo
  git ls-tree -r --name-only "$HEAD_OID" | grep -E '(^|/)docs?/.*\.(md|mdx|txt)$' | sed 's/^/- /' | head -n 60
} > "$DIR/docs.md" 2>/dev/null || true

WIKI="none"
if [ "$(gh api "repos/$REPO" --jq .has_wiki 2>/dev/null)" = true ]; then
  wiki_url=$(git remote get-url "$REMOTE" | sed -E 's#(\.git)?$#.wiki.git#')
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
       git clone --quiet --depth 1 "$wiki_url" "$DIR/wiki" 2>/dev/null; then
    rm -rf "$DIR/wiki/.git"
    WIKI="$(find "$DIR/wiki" -type f -name '*.md' | wc -l | tr -d ' ') pages in wiki/"
  else
    WIKI="none (wiki enabled but empty or not reachable)"
  fi
fi

rm -f "$DIR"/.numstat "$DIR"/.refs "$DIR"/.body "$DIR"/.hist_* "$DIR"/.history_files

# --- manifest ---------------------------------------------------------------------
BLOB="https://github.com/$REPO/blob"
cat <<EOF
# explain-pr context bundle

- Mode: $MODE
- Repo: $REPO
- Title: $TITLE
- Link: $URL
- State: $STATE
- Author: $AUTHOR
- Base branch: $BASE_REF
- Before (merge base): $BASE
- After (head): $HEAD_OID
- Size: $FILES files, $CHANGED changed lines excluding lockfiles/generated → **$SIZE**
- Excluded from diff.patch: ${EXCLUDED:-nothing}
- Link a line before the change: $BLOB/$BASE/<path>#L<n>
- Link a line after the change:  $BLOB/$HEAD_OID/<path>#L<n>

## Bundle: $DIR/

| File | What | Size |
|---|---|---|
| pr.md | PR metadata + the author's description | $(lines "$DIR/pr.md") lines |
| issues.md | Linked issues/PRs:${FOUND_REFS:- none} | $(lines "$DIR/issues.md") lines |
| commits.md | $COMMITS commits, oldest first | $(lines "$DIR/commits.md") lines |
| threads.md | $REVIEWS review summaries, $INLINE inline comments, conversation | $(lines "$DIR/threads.md") lines |
| diffstat.txt | Files changed | $(lines "$DIR/diffstat.txt") lines |
| diff.patch | The diff (merge base → head) | $(lines "$DIR/diff.patch") lines |
| history.md | Earlier PRs on these files: $(echo $HIST_PRS | sed -E 's/([0-9]+)/#\1/g; s/^$/none/') | $(lines "$DIR/history.md") lines |
| docs.md | Project docs to check | $(lines "$DIR/docs.md") lines |
| wiki/ | GitHub wiki | $WIKI |

## Gaps

$(if [ -s "$DIR/gaps.txt" ]; then cat "$DIR/gaps.txt"; else echo "- none"; fi)

## Output

- Write the article to: $DIR/article.html
- Then run: render.sh $DIR
- Report: $DIR.html
EOF
