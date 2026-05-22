# Claude ⇄ PR-Agent Pre-PR Self-Review (MVP — Phase 1)

Status: implemented (2026-05-22). `scripts/review-local.sh --local <target> [review|improve]`
+ user-scope `/pr-self-review` command.

## 1. Purpose
Let Claude review its OWN work before opening a PR: run PR-Agent against the local branch
diff, read the must/should suggestions, fix them, and (optionally) re-run — a bounded
self-review loop Claude consumes. No PR and no posting in this phase.

## 2. Why it's feasible
PR-Agent ships `LocalGitProvider` (`pr_agent/git_providers/local_git_provider.py`, registered
as `'local'`): it diffs the current `HEAD` against a target branch with NO PR URL. It cannot
publish (no PR exists) — which is exactly right for a local self-review.

Phase 1 needs only the `claude` CLI + the local git repo. **No GitHub token required**
(local provider uses git, not the GitHub API).

## 3. Components

### 3.1 Wrapper: `scripts/review-local.sh` — add a `--local <target>` mode
- Sets `CONFIG__GIT_PROVIDER=local` and runs against `HEAD` vs `<target>` (default `master`,
  fallback `main`). No PR URL argument in this mode.
- Emits **structured output to stdout**: `improve` → `code_suggestions` JSON
  (`commitable_code_suggestions=false`); `review` → markdown. Never posts.
- Model = `claude_cli/sonnet` (existing handler), style + conventions instructions reused.
- **Conventions source forks for local mode:** read the repo's on-disk `./AGENTS.md`
  (not the gh-API fetch, which needs owner/repo from a PR URL) + `~/.config/pr-agent/conventions.md`.

### 3.2 Claude-side glue: `/pr-self-review [target]` (user-scope skill/command, NOT in this repo)
- Claude invokes after finishing a task, before opening a PR.
- Runs the wrapper `--local`, parses `code_suggestions`, and surfaces the **must/should** items
  (use `score` / label to filter; ignore low/nice-to-have).
- Claude fixes the flagged items, then MAY re-run. **Bounded loop: max 2 passes**; stop when no
  must/should suggestions remain or the pass limit is hit. No infinite churn.

## 4. Flow
```
Claude finishes work on a branch
  → /pr-self-review master
     → review-local.sh --local master improve  (git_provider=local, HEAD vs master)
        → code_suggestions JSON (no PR, no post)
     → Claude reads must/should → fixes → (optional re-run, ≤2 passes)
  → Claude proceeds to open the PR (Phase 2 auto-post is OUT of scope here)
```

## 5. Failure modes
- Target branch absent locally → clear error ("Branch X does not exist") with a hint to fetch.
- No diff / empty changeset → `empty` (not an error); skip the loop.
- `claude` not authenticated / missing → fail with remediation copy.
- Large diff → PR-Agent's existing token clipping applies (`MAX_TOKENS` / `claude_cli/*` entries).

## 6. Testing
- Wrapper `--local` emits valid `code_suggestions` JSON on a sample feature branch vs master.
- Local mode reads on-disk `AGENTS.md` (assert conventions line: `repo-AGENTS=yes` from file, not API).
- Skill: parses JSON, filters must/should, respects the ≤2-pass bound.

## 7. Non-goals (deferred)
- **Phase 2** — `PostToolUse` hook on `gh pr create*` that posts the final review to the new PR
  (github provider). Separate, follow-on spec.
- Posting anything to GitHub in Phase 1.
- Wiring into the existing pre-PR review gate (can integrate once Phase 1 proves out).

## 8. Open questions for implementation
- Exact must/should filter on `code_suggestions` (score threshold vs label) — calibrate on real runs.
- Where the `/pr-self-review` skill lives (user `~/.claude` skills/commands) and how it returns
  suggestions to Claude compactly (JSON summary, not full artifact).
- Whether LocalGitProvider needs a clean working tree (committed changes) vs also seeing staged/unstaged.
