#!/usr/bin/env python3
"""Clean up Calibre tag taxonomy across libraries.

Usage:
  python3 scripts/calibre_tag_cleanup.py --dry   # report only
  python3 scripts/calibre_tag_cleanup.py --apply # modify databases

Edits tags + books_tags_link only. Stop calibre-web (and Calibre desktop)
before --apply. Back up metadata.db first — see repo history for the
backup suffix used at deploy time.
"""
import argparse
import re
import sqlite3
import sys
from pathlib import Path

SPAM_EXACT = {
    # scanner / pirate-scene artifacts
    "Team DDU", "Team[oR]", "EBC Converted", "Referex", "IT eBooks",
    "www.it-ebooks.info", "www.thenzbplace.com", "www.cro-wood.com",
    # encoding garbage / placeholders
    "ÿþ", "xxxxxxxx", "undefined", "-", "", "Other", "Unknown", "Topic",
    "True", "upload",
    # format noise, not subjects
    "book", "ebook", "Epub3",
    # publisher names used as tags (real publisher field exists)
    "Apress", "Springer", "Springer 2011", "Springer 2012", "Springer 2002",
    "Trafford Publishing", "The MIT Press", "Wiley-Blackwell", "Wiley-VCH",
    "Wiley-Interscience", "Pragmatic Bookshelf",
}

URL_RE = re.compile(r"www\.|http", re.I)
TEX_RE = re.compile(r"^TeX output")
BISAC_ONLY_RE = re.compile(r"^[A-Z]{3}\d{6}([;,]\s*[A-Z]{3}\d{6})*$")
BISAC_PREFIX_RE = re.compile(r"^([A-Z]{3})\d{6}\s+")

PAREN_SUFFIXES = [
    "(Computer Program Language)", "(Computer Programming Language)",
    "(Electronic Resource)", "(Computer File)", "(Computer Operating System)",
    "(Document Markup Language)", "(Computer Software)",
    "(Electronic Computers)", "(Computer Science)",
    "(Computer Network Protocol)", "(Computer Bus)",
    "(Computer Hardware Description Language)",
    "(Web Site Development Technology)", "(Computer Network)",
]

VARIANT_MAP = {
    "Self Help": "Self-Help",
    "Humour": "Humor",
    "Nonfiction": "Non-Fiction",
    "Thrillers": "Thriller",
    "Biographies": "Biography",
    "Sql": "SQL", "Php": "PHP", "Html": "HTML", "Uml": "UML", "Vba": "VBA",
    "Fiction - Science Fiction": "Science Fiction",
    "Science Fiction - General": "Science Fiction",
    "Fantasy Fiction": "Fantasy",
    "General Fiction": "Fiction",
    "Horror Fiction": "Horror",
    "soccer": "Soccer",
}

MAX_LEN = 60


def is_delete(name: str) -> bool:
    if name in SPAM_EXACT or name.strip() in SPAM_EXACT:
        return True
    if URL_RE.search(name) or TEX_RE.match(name):
        return True
    if len(name) > MAX_LEN:
        return True
    if BISAC_ONLY_RE.match(name.strip()):
        return True
    if "Â" in name or name.startswith("ÿ") or "”" in name or "“" in name:
        return True
    if name and all(not c.isascii() for c in name):
        return True
    return False


def strip_rules(name: str):
    """Return renamed target or None."""
    if name in VARIANT_MAP:
        return VARIANT_MAP[name]
    for suf in PAREN_SUFFIXES:
        if name.endswith(" " + suf):
            base = name[: -len(suf)].strip()
            if base:
                return base
    m = BISAC_PREFIX_RE.match(name)
    if m:
        rest = BISAC_PREFIX_RE.sub("", name).strip()
        if rest:
            return rest
    return None


def clean_db(path: Path, apply: bool, report):
    con = sqlite3.connect(str(path))
    con.row_factory = sqlite3.Row
    tags = {r["id"]: r["name"] for r in con.execute("SELECT id, name FROM tags")}
    counts = {
        r["tag"]: r["n"]
        for r in con.execute(
            "SELECT tag, COUNT(*) n FROM books_tags_link GROUP BY tag")
    }

    deletes, renames = {}, {}
    for tid, name in tags.items():
        if is_delete(name):
            deletes[tid] = name
            continue
        tgt = strip_rules(name)
        if tgt and tgt != name:
            renames[tid] = tgt

    # case-insensitive duplicates among survivors -> merge into most-used
    survivors = {t: n for t, n in tags.items() if t not in deletes}
    lower = {}
    for tid, name in survivors.items():
        lower.setdefault(name.lower(), []).append((tid, name))
    for group in lower.values():
        if len(group) > 1:
            best = max(group, key=lambda tn: counts.get(tn[0], 0))
            for tid, name in group:
                if tid != best[0] and tid not in renames:
                    renames[tid] = best[1]

    # resolve rename chains and drop renames onto deleted/identical targets
    def resolve(tid, seen=0):
        tgt = renames.get(tid)
        if tgt is None or seen > 5:
            return tgt
        match = next((t for t, n in tags.items() if n == tgt), None)
        if match in deletes:
            return None
        if match in renames:
            return resolve(match, seen + 1)
        return tgt

    final_renames = {}
    for tid in list(renames):
        tgt = resolve(tid)
        if tgt and tgt != tags[tid]:
            final_renames[tid] = tgt

    n_del_links = sum(counts.get(t, 0) for t in deletes)
    n_ren_links = sum(counts.get(t, 0) for t in final_renames)

    report.write(f"\n=== {path.parent.name} ===\n")
    report.write(f"tags before: {len(tags)}  "
                 f"deletions: {len(deletes)} ({n_del_links} links)  "
                 f"renames: {len(final_renames)} ({n_ren_links} links)\n")
    report.write("--- deleted tags ---\n")
    for tid in sorted(deletes, key=lambda t: -counts.get(t, 0)):
        report.write(f"  [{counts.get(tid, 0):4}] DEL {tags[tid]!r}\n")
    report.write("--- renamed/merged tags ---\n")
    for tid in sorted(final_renames, key=lambda t: -counts.get(t, 0)):
        report.write(f"  [{counts.get(tid, 0):4}] {tags[tid]!r} -> "
                     f"{final_renames[tid]!r}\n")

    if not apply:
        con.close()
        return len(tags), len(deletes), len(final_renames)

    cur = con.cursor()
    cur.execute("BEGIN")
    for tid, tgt in final_renames.items():
        row = cur.execute("SELECT id FROM tags WHERE name = ?", (tgt,)).fetchone()
        if row:
            dst = row[0]
        else:
            cur.execute("INSERT INTO tags (name) VALUES (?)", (tgt,))
            dst = cur.lastrowid
        cur.execute(
            "INSERT INTO books_tags_link (book, tag) "
            "SELECT b.book, ? FROM books_tags_link b WHERE b.tag = ? "
            "AND NOT EXISTS (SELECT 1 FROM books_tags_link x "
            " WHERE x.book = b.book AND x.tag = ?)", (dst, tid, dst))
        cur.execute("DELETE FROM books_tags_link WHERE tag = ?", (tid,))
        cur.execute("DELETE FROM tags WHERE id = ?", (tid,))
    for tid in deletes:
        cur.execute("DELETE FROM books_tags_link WHERE tag = ?", (tid,))
        cur.execute("DELETE FROM tags WHERE id = ?", (tid,))
    cur.execute("DELETE FROM tags WHERE id NOT IN "
                "(SELECT DISTINCT tag FROM books_tags_link)")
    orphaned = cur.rowcount
    con.commit()
    after = cur.execute("SELECT COUNT(*) FROM tags").fetchone()[0]
    con.close()
    report.write(f"applied. tags after: {after} (orphan rows removed: "
                 f"{orphaned})\n")
    return len(tags), len(deletes), len(final_renames)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["dry", "apply"], default="dry")
    ap.add_argument("--root", default="/mnt/backups/Books")
    ap.add_argument("--report", default="/tmp/tagfix-report.txt")
    args = ap.parse_args()

    report = open(args.report, "w")
    total = [0, 0, 0]
    for db in sorted(Path(args.root).glob("*/metadata.db")):
        stats = clean_db(db, args.mode == "apply", report)
        for i in range(3):
            total[i] += stats[i]
    report.write(f"\nTOTAL tags={total[0]} deletions={total[1]} "
                 f"renames={total[2]}\n")
    report.close()
    print(f"[{args.mode}] total tags={total[0]} deletions={total[1]} "
          f"renames={total[2]}  report: {args.report}")


if __name__ == "__main__":
    sys.exit(main())
