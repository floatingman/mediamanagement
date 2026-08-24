#!/usr/bin/env python3
"""Apply fetched subject tags to Calibre libraries.

Reads appdata/calibre-web/config/tagfix/results.jsonl produced by
fetch_tags.py. For every book with fetched tags: add those tags and drop
'generic filler' tags (General / Electronic Books / Non-Fiction / Fiction)
now that real subjects exist. Works around the CIFS byte-range-lock wedge
by editing local copies and atomically renaming them back into place.

Run with calibre-web STOPPED:
  docker compose stop calibre-web
  python3 scripts/calibre_tag_apply_fetched.py
  docker compose up -d calibre-web
"""
import json
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

ROOT = Path("/mnt/backups/Books")
RESULTS = Path("appdata/calibre-web/config/tagfix/results.jsonl")
GENERIC = {"General", "Electronic Books", "Non-Fiction", "Fiction"}


def apply_lib(lib, entries):
    src = ROOT / lib / "metadata.db"
    tmp = Path(tempfile.mkdtemp(prefix="tagapply-")) / "metadata.db"
    shutil.copy2(src, tmp)
    con = sqlite3.connect(str(tmp))
    cur = con.cursor()
    changed = 0
    for book_id, tag_lists in entries.items():
        new_tags = sorted({t for lst in tag_lists for t in lst if t})
        if not new_tags:
            continue
        cur.execute("BEGIN")
        existing = {r[0] for r in cur.execute(
            "SELECT t.name FROM books_tags_link l JOIN tags t ON t.id = l.tag "
            "WHERE l.book = ?", (book_id,))}
        specific = existing - GENERIC
        for name in new_tags:
            if name in existing:
                continue
            row = cur.execute("SELECT id FROM tags WHERE name = ?",
                              (name,)).fetchone()
            tid = row[0] if row else cur.execute(
                "INSERT INTO tags (name) VALUES (?)", (name,)).lastrowid
            cur.execute("INSERT INTO books_tags_link (book, tag) VALUES (?, ?)",
                        (book_id, tid))
        # book now has real subjects -> drop filler tags
        if specific or new_tags:
            for name in existing & GENERIC:
                cur.execute(
                    "DELETE FROM books_tags_link WHERE book = ? AND tag = "
                    "(SELECT id FROM tags WHERE name = ?)", (book_id, name))
        con.commit()
        changed += 1
    cur.execute("DELETE FROM tags WHERE id NOT IN "
                "(SELECT DISTINCT tag FROM books_tags_link)")
    con.commit()
    ic = con.execute("PRAGMA integrity_check").fetchone()[0]
    con.close()
    if ic != "ok":
        print(f"{lib}: INTEGRITY FAIL ({ic}) — not applied")
        shutil.rmtree(tmp.parent)
        return 0
    staging = str(src) + ".tagapply-new"
    shutil.copy2(tmp, staging)
    Path(staging).rename(src)
    shutil.rmtree(tmp.parent)
    print(f"{lib}: applied to {changed} books (integrity ok)")
    return changed


def main():
    by_lib = defaultdict(lambda: defaultdict(list))
    n_ok = 0
    for line in RESULTS.read_text().splitlines():
        r = json.loads(line)
        if r.get("ok") and r.get("tags"):
            by_lib[r["lib"]][r["id"]].append(r["tags"])
            n_ok += 1
    print(f"results with tags: {n_ok} books across {len(by_lib)} libraries")
    total = 0
    for lib, entries in sorted(by_lib.items()):
        total += apply_lib(lib, entries)
    print(f"TOTAL books updated: {total}")


if __name__ == "__main__":
    sys.exit(main())
