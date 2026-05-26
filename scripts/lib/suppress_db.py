"""SQLite helpers for review suggestion suppression state."""
from __future__ import annotations

import os
import sqlite3
from pathlib import Path
from typing import Optional


DEFAULT_DB_PATH = Path("~/.claude/cache/pr-review/suppress.db").expanduser()
FALLBACK_DB_PATH = Path("/tmp/pr-review-suppress.db")


def _db_path() -> Path:
    override = os.environ.get("SUPPRESS_DB_PATH")
    return Path(override).expanduser() if override else DEFAULT_DB_PATH


def connect() -> sqlite3.Connection:
    path = _db_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(path)
    except PermissionError:
        if os.environ.get("SUPPRESS_DB_PATH"):
            raise
        FALLBACK_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(FALLBACK_DB_PATH)
    conn.execute("PRAGMA foreign_keys=ON")
    user_version = conn.execute("PRAGMA user_version").fetchone()[0]
    if user_version == 0:
        conn.executescript(
            """
            CREATE TABLE suggestions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              repo TEXT NOT NULL,
              file_path TEXT NOT NULL,
              rule_id TEXT,
              fingerprint TEXT NOT NULL,
              category TEXT,
              one_sentence TEXT NOT NULL,
              status TEXT NOT NULL CHECK (status IN ('pending','rejected','accepted','unclear')),
              decided_by TEXT,
              decided_at TEXT,
              source_pr TEXT,
              source_comment_url TEXT,
              reason TEXT,
              created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX idx_lookup ON suggestions (repo, file_path, fingerprint, status);
            CREATE INDEX idx_repo_status ON suggestions (repo, status);
            PRAGMA user_version=1;
            """
        )
        conn.commit()
    return conn


def insert(
    repo: str,
    file_path: str,
    fingerprint: str,
    one_sentence: str,
    *,
    category: Optional[str] = None,
    source_pr: Optional[str] = None,
    source_comment_url: Optional[str] = None,
    status: str = "pending",
) -> int:
    with connect() as conn:
        cur = conn.execute(
            """
            INSERT INTO suggestions (
              repo, file_path, rule_id, fingerprint, category, one_sentence,
              status, source_pr, source_comment_url
            )
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?)
            """,
            (repo, file_path, fingerprint, category, one_sentence, status, source_pr, source_comment_url),
        )
        conn.commit()
        return int(cur.lastrowid)


def find_rejected(repo: str, file_path: str, fingerprint: str) -> Optional[sqlite3.Row]:
    with connect() as conn:
        conn.row_factory = sqlite3.Row
        return conn.execute(
            """
            SELECT *
            FROM suggestions
            WHERE repo = ? AND file_path = ? AND fingerprint = ? AND status = 'rejected'
            ORDER BY id DESC
            LIMIT 1
            """,
            (repo, file_path, fingerprint),
        ).fetchone()


def set_status(row_id: int, status: str, *, decided_by: Optional[str] = None, reason: Optional[str] = None) -> None:
    with connect() as conn:
        conn.execute(
            """
            UPDATE suggestions
            SET status = ?, decided_by = ?, decided_at = CURRENT_TIMESTAMP, reason = ?
            WHERE id = ?
            """,
            (status, decided_by, reason, row_id),
        )
        conn.commit()


def list_rows(repo: Optional[str] = None, status: Optional[str] = None, limit: int = 200) -> list[sqlite3.Row]:
    where = []
    params: list[object] = []
    if repo:
        where.append("repo = ?")
        params.append(repo)
    if status:
        where.append("status = ?")
        params.append(status)

    query = "SELECT * FROM suggestions"
    if where:
        query += " WHERE " + " AND ".join(where)
    query += " ORDER BY created_at DESC, id DESC LIMIT ?"
    params.append(limit)

    with connect() as conn:
        conn.row_factory = sqlite3.Row
        return list(conn.execute(query, params).fetchall())


def purge_older_than(days: int, status: Optional[str] = None) -> int:
    target_status = status or "pending"
    params: list[object] = [f"-{days} days", target_status]
    query = (
        "UPDATE suggestions SET status = 'unclear', decided_at = CURRENT_TIMESTAMP "
        "WHERE created_at < datetime('now', ?) AND status = ?"
    )
    with connect() as conn:
        cur = conn.execute(query, params)
        conn.commit()
        return cur.rowcount


def expire_pending_to_unclear(days: int = 90) -> int:
    return purge_older_than(days, status="pending")
