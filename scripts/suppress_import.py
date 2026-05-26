#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib.fingerprint import fingerprint
from scripts.lib.suppress_db import insert, list_rows, set_status


SUGGESTION_BLOCK = re.compile(r"```suggestion[^\n]*\n(.*?)```", re.DOTALL)
PR_URL_RE = re.compile(r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/pull/(?P<number>\d+)(?:/.*)?$")
REJECTED_MARKERS = (
    "not a bug",
    "by design",
    "intentional",
    "this is correct",
    "mock",
    "won't fix",
    "wontfix",
    "false positive",
    "as designed",
    "working as intended",
)
ACCEPTED_MARKERS = ("good catch", "fixed", "thanks", "applied", "done")
STATUS_PRIORITY = {"pending": 0, "unclear": 1, "accepted": 2, "rejected": 3}


def parse_pr_url(pr_url: str) -> tuple[str, str, str, int]:
    match = PR_URL_RE.match(pr_url)
    if not match:
        raise SystemExit(f"Unsupported PR URL: {pr_url}")
    owner = match.group("owner")
    repo = match.group("repo")
    number = int(match.group("number"))
    return owner, repo, f"{owner}/{repo}", number


def gh_api(path: str) -> Any:
    proc = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or f"gh api failed for {path}")
    return json.loads(proc.stdout)


def gh_login() -> str:
    return str(gh_api("user")["login"])


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


def classify_reply(body: str) -> str:
    lowered = body.lower()
    if any(marker in lowered for marker in REJECTED_MARKERS):
        return "rejected"
    if any(marker in lowered for marker in ACCEPTED_MARKERS):
        return "accepted"
    return "unclear"


def upsert_status(
    repo: str,
    file_path: str,
    suggestion_fp: str,
    one_sentence: str,
    status: str,
    pr_url: str,
    comment_url: str | None,
) -> str:
    existing = list_rows(repo=repo, limit=1000)
    for row in existing:
        if row["file_path"] == file_path and row["fingerprint"] == suggestion_fp:
            if STATUS_PRIORITY[status] > STATUS_PRIORITY[row["status"]]:
                set_status(row["id"], status, decided_by="import")
                return status
            return row["status"]

    insert(
        repo,
        file_path,
        suggestion_fp,
        one_sentence,
        source_pr=pr_url,
        source_comment_url=comment_url,
        status=status,
    )
    return status


def run_import(pr_url: str) -> int:
    owner, repo_name, repo, number = parse_pr_url(pr_url)
    login = gh_login()
    comments = gh_api(f"repos/{owner}/{repo_name}/pulls/{number}/comments")
    replies_by_parent: dict[int, list[dict[str, Any]]] = {}
    for comment in comments:
        parent_id = comment.get("in_reply_to_id")
        if parent_id is not None:
            replies_by_parent.setdefault(parent_id, []).append(comment)

    imported = 0
    rejected = 0
    accepted = 0
    unclear = 0

    for comment in comments:
        if comment.get("in_reply_to_id") is not None:
            continue
        if comment.get("user", {}).get("login") != login:
            continue

        existing_code, improved_code = extract_codes(comment)
        suggestion_fp = fingerprint(existing_code, improved_code)
        file_path = comment.get("path") or ""
        if not file_path:
            continue

        replies = replies_by_parent.get(comment["id"], [])
        status = "pending"
        for reply in replies:
            reply_status = classify_reply(reply.get("body") or "")
            if STATUS_PRIORITY[reply_status] > STATUS_PRIORITY[status]:
                status = reply_status

        final_status = upsert_status(
            repo,
            file_path,
            suggestion_fp,
            first_non_empty_line(comment.get("body") or ""),
            status,
            pr_url,
            comment.get("html_url"),
        )
        imported += 1
        if final_status == "rejected":
            rejected += 1
        elif final_status == "accepted":
            accepted += 1
        elif final_status == "unclear":
            unclear += 1

    print(f"imported: {imported} comments, {rejected} rejected, {accepted} accepted, {unclear} unclear")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pr-url", required=True)
    args = parser.parse_args()
    return run_import(args.pr_url)


if __name__ == "__main__":
    raise SystemExit(main())
