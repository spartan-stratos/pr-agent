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
