# PR-Agent Review Console — MVP Design

Status: approved design (2026-05-22). Implementation pending (build in a fresh session).

## 1. Purpose

A local, standalone web UI that centralizes PR code-review operations on top of PR-Agent,
driven by the local Claude Code CLI handler (Max subscription, no API key). It makes the
review/improve workflow visual and safe: browse PRs, run a review, **preview the result**,
then explicitly publish it to the PR.

## 2. Goals (MVP) / Non-goals

**Goals**
- Browse a configured set of repos and their open PRs; also accept a pasted PR URL.
- Run `review` (summary) and `improve` (inline committable suggestions) on a PR.
- Preview-first: every run produces a preview; **publishing to GitHub is a separate explicit action**.
- Persist run history (SQLite) with status and results.
- Reuse existing review behavior (Claude CLI handler, conventions injection, comment-style
  instructions) — do not reimplement it.

**Non-goals (deferred)**
- `describe` / `ask` / other commands.
- Conventions editor UI (edit `~/.config/pr-agent/conventions.md` by hand for now).
- Scheduling / monitoring dashboards.
- Multi-user / auth / remote deployment (see §10, team-deploy epic).

## 3. Architecture

```
React + TS + Vite SPA  ──REST/JSON──▶  FastAPI backend (127.0.0.1)
                                          ├─ orchestrates the review CLI as SUBPROCESS
                                          │    (scripts/review-local.sh, extended)
                                          ├─ SQLite — run history + cached preview payloads
                                          └─ CredentialProvider → gh token, model
   subprocess ▶ claude CLI (Max subscription)  +  GitHub API
```

### 3.1 Why subprocess, not in-process (load-bearing)
`pr_agent` configuration (dynaconf) is a **process-wide singleton**; every run does
`get_settings().set(...)`. Importing pr_agent into the FastAPI process would make concurrent
runs against different repos/models race on global state. The backend therefore shells out to
the existing wrapper (proven path), one OS process per run. The import-time saving of going
in-process (~1-2s) is negligible against a 30-60s claude call.

## 4. Preview → Publish replay (the core differentiator)

The wrapper today **re-runs** the model on publish; outputs drift between preview and post
(observed: an inline suggestion differed from its preview). The console MUST avoid this:

- **Preview** generates and **caches structured output**, makes NO change to the PR:
  - `review`  → cache the rendered review **markdown** string.
  - `improve` → run with `commitable_code_suggestions=false` and cache the **`code_suggestions`
    JSON** (structured cards), NOT the rendered HTML `artifact`.
- **Publish** posts the **cached** payload with NO second claude call:
  - `review`  → `git_provider.publish_comment(cached_markdown)`.
  - `improve` → `git_provider.publish_code_suggestions(cached_suggestions)`
    (the method PR-Agent already uses at publish time).

### 4.1 Required wrapper changes (scripts/review-local.sh + a small helper)
- **`--json` preview mode**: emit structured output to stdout —
  `review` → `{ "command":"review", "markdown": "..." }`;
  `improve` → `{ "command":"improve", "code_suggestions": [...] }`.
- **Bug fix**: do not force `PR_CODE_SUGGESTIONS__COMMITABLE_CODE_SUGGESTIONS=true` in preview.
  Preview = `false` (structured JSON cards). Only the post path uses the committable flow.
- **`publish` path**: a subprocess entry that takes a cached payload (file/stdin) + pr_url and
  posts it via `publish_comment` / `publish_code_suggestions` — no model call. Keeps publishing
  out of the FastAPI process (no dynaconf race) and avoids reimplementing wrapper logic in Python.

## 5. Backend API (FastAPI)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/repos` | configured repo list (+ their metadata) |
| GET | `/api/repos/{owner}/{repo}/pulls` | open PRs (gh API) |
| POST | `/api/runs` | body `{pr_url, command}` → start a **preview** run (async), returns `{run_id}` |
| GET | `/api/runs/{id}` | run status + parsed result |
| POST | `/api/runs/{id}/publish` | publish the cached preview to the PR |
| POST | `/api/runs/{id}/cancel` | SIGTERM the run's subprocess |
| GET | `/api/runs` | run history |
| GET | `/api/health` | claude-authed? gh-authed? venv present? |

- **Single uvicorn worker** for MVP (in-memory run registry + SQLite). State this explicitly.
- Run lifecycle status enum: `queued | running | success | empty | failed | cancelled`
  (`empty` = "no suggestions found", distinct from `failed`).
- Track subprocess PID per run for cancellation.

## 6. Data model (SQLite)

`runs(id, pr_url, owner, repo, pr_number, command, status, created_at, finished_at,
       result_json TEXT, published_at, published_comment_url, error TEXT)`

`result_json` holds the cached preview payload used for replay on publish.

## 7. Frontend (React + TS + Vite)

Three views:
1. **Browser** — left: configured repos; main: open PRs; top: paste-PR-URL box.
2. **PR detail** — run controls (`review` | `improve`, model picker), live status, **preview pane**
   (rendered markdown for review; suggestion cards with unified diffs for improve), **Post to PR**
   button (+ Cancel while running).
3. **History** — past runs with status, PR link, published link.

State via react-query. Follow workspace TS conventions (strict, DDD-ish module layout).

## 8. Failure catalog (surface, don't crash)
- claude not authenticated / `claude` missing → `503` + remediation copy.
- gh not authenticated / token lacks scope → `503` + remediation.
- invalid / unparseable PR URL → `422`.
- GitHub rate-limited → backoff, run status `failed` with reason.
- claude timeout (handler already enforces) → run status `failed`, surface cleanly.
- improve with no suggestions → status `empty` (not an error).

## 9. Security (MVP)
- Bind FastAPI to `127.0.0.1` only (never `0.0.0.0`).
- CORS allow-list = the Vite dev origin only.
- Publish is the only mutating endpoint; localhost binding is sufficient for MVP.

## 10. Team-deploy seam (explicitly deferred — real epic, not a one-liner)
A `CredentialProvider` abstraction resolves the GitHub token + model. MVP implementation reads
`gh auth token` + config. A future multi-user deployment is a full epic requiring: OAuth login,
per-user encrypted secret storage, per-user concurrency limits, an audit log of who published
what, and CSRF/bearer auth on mutating endpoints. The seam exists; the epic is out of scope here.

## 11. File layout
```
review-console/
  backend/        # FastAPI app, run registry, SQLite, subprocess orchestration, tests (pytest)
  frontend/       # React+TS+Vite SPA, tests (vitest)
  README.md       # run instructions
scripts/review-local.sh   # extended: --json preview mode, commitable fix, publish path
```

## 12. Testing
- Backend: pytest — mock the subprocess run + GitHub API; cover the preview→publish replay
  (publish uses cached payload, asserts NO second model invocation), status transitions,
  the failure catalog.
- Frontend: vitest — preview rendering (review markdown + improve cards), post/cancel controls.

## 13. MVP cut list (explicitly out)
describe/ask, conventions editor, scheduling/monitoring, multi-user/auth, full repo search.

## 14. Open questions for implementation
- Exact JSON shape of `code_suggestions` to cache (capture from a real `improve` run).
- Whether `publish_code_suggestions` needs the original diff/line context re-fetched at publish
  time, or the cached payload is self-sufficient (verify against PR-Agent's git provider).
