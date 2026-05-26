#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib.fingerprint import fingerprint
from scripts.lib.suppress_db import find_rejected, insert, list_rows, purge_older_than, set_status


SUGGESTION_BLOCK = re.compile(r"```suggestion[^\n]*\n(.*?)```", re.DOTALL)
PR_URL_RE = re.compile(r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/pull/(?P<number>\d+)(?:/.*)?$")


def parse_pr_url(pr_url: str) -> tuple[str, str, str, int]:
    match = PR_URL_RE.match(pr_url)
    if not match:
        raise SystemExit(f"Unsupported PR URL: {pr_url}")
    owner = match.group("owner")
    repo = match.group("repo")
    number = int(match.group("number"))
    return owner, repo, f"{owner}/{repo}", number


def gh_api(path: str, *, method: str = "GET") -> Any:
    cmd = ["gh", "api"]
    if method != "GET":
        cmd.extend(["-X", method])
    cmd.append(path)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or f"gh api failed for {path}")
    if method == "DELETE":
        return None
    return json.loads(proc.stdout)


def gh_login() -> str:
    return str(gh_api("user")["login"])


def parse_timestamp(raw: str) -> datetime:
    return datetime.fromisoformat(raw.replace("Z", "+00:00"))


def extract_codes(comment: dict[str, Any]) -> tuple[str, str]:
    body = comment.get("body") or ""
    match = SUGGESTION_BLOCK.search(body)
    improved_code = match.group(1).strip("\n") if match else ""
    existing_code = (comment.get("diff_hunk") or "").strip("\n")
    return existing_code, improved_code


def first_non_empty_line(body: str) -> str:
    for line in body.splitlines():
        cleaned = line.strip()
        if cleaned:
            return cleaned[:120]
    return "(empty comment)"


def post_improve(pr_url: str) -> int:
    owner, repo_name, repo, number = parse_pr_url(pr_url)
    login = gh_login()
    comments = gh_api(f"repos/{owner}/{repo_name}/pulls/{number}/comments")
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=10)
    recorded = 0
    suppressed = 0

    for comment in comments:
        if comment.get("user", {}).get("login") != login:
            continue
        created_at = comment.get("created_at")
        if not created_at or parse_timestamp(created_at) < cutoff:
            continue

        existing_code, improved_code = extract_codes(comment)
        suggestion_fp = fingerprint(existing_code, improved_code)
        file_path = comment.get("path") or ""
        if not file_path:
            continue

        if find_rejected(repo, file_path, suggestion_fp):
            gh_api(f"repos/{owner}/{repo_name}/pulls/comments/{comment['id']}", method="DELETE")
            suppressed += 1
            print(
                f"suppress: deleted comment {comment['id']} for {file_path} due to prior rejection",
                file=sys.stderr,
            )
            continue

        insert(
            repo,
            file_path,
            suggestion_fp,
            first_non_empty_line(comment.get("body") or ""),
            source_pr=pr_url,
            source_comment_url=comment.get("html_url"),
            status="pending",
        )
        recorded += 1

    print(f"suppress: recorded {recorded} pending, suppressed {suppressed} prior-rejected", file=sys.stderr)
    return 0


def handle_list(args: argparse.Namespace) -> int:
    rows = list_rows(repo=args.repo, status=args.status, limit=args.limit)
    print(json.dumps([dict(row) for row in rows], indent=2))
    return 0


def handle_reject(args: argparse.Namespace) -> int:
    set_status(args.id, "rejected", decided_by="manual", reason=args.reason)
    return 0


def handle_accept(args: argparse.Namespace) -> int:
    set_status(args.id, "accepted", decided_by="manual")
    return 0


def handle_purge(args: argparse.Namespace) -> int:
    changed = purge_older_than(args.older_than)
    print(changed)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--repo")
    list_parser.add_argument("--status")
    list_parser.add_argument("--limit", type=int, default=200)
    list_parser.set_defaults(func=handle_list)

    reject_parser = sub.add_parser("reject")
    reject_parser.add_argument("id", type=int)
    reject_parser.add_argument("--reason")
    reject_parser.set_defaults(func=handle_reject)

    accept_parser = sub.add_parser("accept")
    accept_parser.add_argument("id", type=int)
    accept_parser.set_defaults(func=handle_accept)

    purge_parser = sub.add_parser("purge")
    purge_parser.add_argument("--older-than", type=int, default=180)
    purge_parser.set_defaults(func=handle_purge)

    post_improve_parser = sub.add_parser("post-improve")
    post_improve_parser.add_argument("--pr-url", required=True)
    post_improve_parser.set_defaults(func=lambda args: post_improve(args.pr_url))

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
