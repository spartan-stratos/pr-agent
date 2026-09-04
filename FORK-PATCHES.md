# Fork Patches

Local-only changes this fork carries on top of upstream PR-Agent. Each entry is a
future upstream-merge cost — keep this list current so the cost stays visible.

## LocalGitProvider / `--local` review surface

`/review-local --local` drives PR-Agent's `LocalGitProvider` (diff HEAD vs a target
branch, no PR). PR-Agent's own docstring calls this an MVP; it hard-disables inline
comments (`pr_agent/git_providers/local_git_provider.py:47`) and `NotImplementedError`s
`publish_code_suggestions`. The patches below all cluster on this least-maintained
surface and the wrapper (`scripts/review-local.sh`) that drives it.

1. **stdout-sink dropped-suggestion recovery** — PR-Agent's loguru sink writes to
   stdout, not stderr. `scripts/post-dropped-suggestions.py` captures stdout, parses
   the dropped-suggestion ERROR lines, and reposts them as one consolidated PR comment.
2. **out-of-hunk inline-comment drop handling** — rename/move PRs produce suggestions
   whose target line is outside any diff hunk; GitHub rejects those inline. Console
   noise is suppressed and the suggestions are recovered via (1).
3. **SIGPIPE-under-`pipefail` truncation fix** — `cat|head -c N` under `set -o pipefail`
   aborts the script (exit 141) when truncating. All truncation switched to bash
   substrings (`${var:0:N}`) in `scripts/review-local.sh`.
4. **404-as-fake-conventions guard** — `gh api .../AGENTS.md` prints "Not Found" JSON
   to stdout and exits 1 on 404; the wrapper now gates on the gh exit code so a 404
   body is never injected as repo conventions.
5. **worktree `.git`-file repo-root detection** — `_find_repository_root()`
   (`pr_agent/config_loader.py:64`) checked only `(cwd/".git").is_dir()`, so it failed
   inside git worktrees/submodules where `.git` is a file. Now accepts either.
   **Upstreamable**: one-line fix to a real bug hitting every worktree user.

## Upstream merge status (2026-09-04, upstream/main @ 216 commits)

Checked at the merge of `upstream/main` into `custom-upstream-2026-09`.

| # | Patch | Status after merge |
|---|---|---|
| 1 | stdout-sink dropped-suggestion recovery | Still applies. Lives entirely in `scripts/`, which upstream never touches. |
| 2 | out-of-hunk inline-comment drop handling | Still applies (wrapper side). |
| 3 | SIGPIPE-under-`pipefail` truncation fix | Still applies. `scripts/` only. |
| 4 | 404-as-fake-conventions guard | Still applies. `scripts/` only. |
| 5 | worktree `.git`-file repo-root detection | **Superseded upstream.** `config_loader.py` merged with no conflict; upstream's `_find_repository_root()` now accepts `.git` as a file. The fork no longer carries this. |
| 6 | scoped clean-tree check (see below) | Still applies. Merged cleanly, survives. |

Two conflicts in `local_git_provider.py` were resolved by taking UPSTREAM: it has
independently implemented the same binary/non-UTF-8 blob skip and the `b_path or a_path`
fallback for deletions, in a cleaner form. Those two fork deltas are now redundant.

`requirements.txt` and `requirements-dev.txt` were DELETED upstream; dependencies moved to
`pyproject.toml`. The deletion was accepted after confirming all six packages the fork bumped
for Dependabot (commit f32aef3f) are met or exceeded there: aiohttp 3.14.3, dynaconf 3.2.13,
GitPython 3.1.59 (higher than the fork's 3.1.57), PyJWT 2.13.0, ujson 5.13.0, pytest 9.0.3.

`pr_agent/algo/__init__.py` was taken from upstream wholesale. Upstream now GENERATES
provider-prefixed Claude ids from `_CLAUDE_MODEL_FAMILIES`, which already covers opus-4-8,
opus-5, sonnet-5, sonnet-4-6, opus-4-7 and fable-5, so the fork's hand-maintained model lists
are obsolete. Only the three `claude_cli/*` token entries were re-applied by hand, because the
Claude CLI aliases never pass through that generator.

`pr_agent/agent/pr_agent.py` was an add/add: the fork's `get_ai_handler()` (claude_cli routing)
and upstream's `_split_command()`/`prepare_command()` tokenizer. Both kept.

## Patch 6 - scoped clean-tree check (was undocumented until 2026-09-04)

`LocalGitProvider.__init__` upstream refuses to run when `repo.is_dirty()` - a WHOLE-TREE check.
The fork replaces it with a per-file check: only files actually under review must match HEAD.

`get_diff_files()` diffs commit-to-commit and never reads working-tree content, so an unrelated
dirty file cannot change the review. The upstream check therefore guards nothing while disabling
self-review outright in any checkout with unrelated pending work - which silently downgrades
those changes to bot-only review, a review GAP that looks like a passing workflow. This workspace
routinely has two sessions in one checkout, so it fired constantly.

`PRAGENT_STRICT_CLEAN_TREE=1` restores upstream behaviour. `/review-local` step 1 mirrors the
same scoping in the wrapper.

**This patch was carried for months without an entry here**, which is exactly the failure this
file exists to prevent: an undocumented patch is one a future merge deletes silently. It merged
cleanly this time by luck, not by review.

## Migration trigger (pre-committed)

The **next** bug that requires editing `pr_agent/config_loader.py` or
`pr_agent/git_providers/local_git_provider.py` → stop patching `LocalGitProvider`
and scope `--local` mode off it entirely.

**Why now-vs-then:** github/team-PR mode is where PR-Agent earns its keep (hunk math,
inline positioning, posting) — leave it untouched. Local mode uses almost none of
that: of the flow (diff HEAD vs target → inject conventions by domain → call Claude →
parse `code_suggestions` → must/should filter → ≤2-pass loop → write marker), only the
prompt-build + JSON-parse inside `PRCodeSuggestions` is PR-Agent-specific, and it's
reachable without `LocalGitProvider`.

**Migration sketch:** build the diff in the wrapper (`git diff` HEAD vs target →
per-file `FilePatchInfo`), wrap them in a `PullRequestMimic`-like object, and feed
`PRCodeSuggestions` directly with `publish_output=False`. This skips
`_find_repository_root` and `_prepare_repo` (and every bug that lives in them), and
removes the clean-tree/worktree coupling. The conventions injection, must/should
filter, ≤2-pass loop, and marker logic already live wrapper-side and carry over as-is.
