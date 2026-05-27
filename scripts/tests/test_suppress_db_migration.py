from __future__ import annotations

import sqlite3
from pathlib import Path

from scripts.lib.suppress_db import connect


OLD_SCHEMA = """
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


def create_v1_db(path: Path) -> None:
    with sqlite3.connect(path) as conn:
        conn.executescript(OLD_SCHEMA)
        conn.execute(
            """
            INSERT INTO suggestions (
              repo, file_path, rule_id, fingerprint, category, one_sentence,
              status, source_pr, source_comment_url
            )
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?)
            """,
            (
                "8Fleet-LA/service-fleet",
                "app/main.py",
                "fp-1",
                "summary",
                "line issue",
                "rejected",
                "https://github.com/org/repo/pull/1",
                "https://github.com/org/repo/pull/1#discussion_r1",
            ),
        )
        conn.commit()


def test_connect_auto_migrates_v1_to_v2(tmp_path: Path, monkeypatch) -> None:
    db_path = tmp_path / "suppress-v1.db"
    create_v1_db(db_path)
    monkeypatch.setenv("SUPPRESS_DB_PATH", str(db_path))

    with connect() as conn:
        user_version = conn.execute("PRAGMA user_version").fetchone()[0]
        assert user_version == 2
        columns = [row[1] for row in conn.execute("PRAGMA table_info(suggestions)").fetchall()]
        assert "reviewer" in columns
        existing_rows = conn.execute("SELECT reviewer FROM suggestions").fetchall()
        assert existing_rows == [("pr-agent",)]

    with connect() as conn:
        user_version = conn.execute("PRAGMA user_version").fetchone()[0]
        assert user_version == 2
        existing_rows = conn.execute("SELECT reviewer FROM suggestions").fetchall()
        assert existing_rows == [("pr-agent",)]
