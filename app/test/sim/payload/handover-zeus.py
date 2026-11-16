#!/usr/bin/env python3
"""A simulated scripts/zeus.py of the EU workspace: only `handoff pending|build|scan|mask --json`, as zeus references/eu-mode.md describes.

The handover of project pilot has one SQL file with a quoted literal in two places (one group) and an e-mail address (a blocking group).
Masking replaces each place with [masked <kind> #<n>], as the real `handoff mask` does, and like it refuses a group that it no longer
finds and a released handover. Each call is recorded in $ZEUS_SIM_STATE/handover-calls.
With $ZEUS_SIM_STATE/handover-fail-scan present, the next scan fails once (the file is removed).
"""
import hashlib
import json
import os
import sys
from pathlib import Path

args = [a for a in sys.argv[1:] if a != "--json"]
workspace = Path(args[args.index("--workspace") + 1])
args = args[args.index("handoff") + 1:]
state = Path(os.environ.get("ZEUS_SIM_STATE", "/tmp"))
with open(state / "handover-calls", "a") as log:
    log.write(" ".join(args) + "\n")

HANDOVER = "20261116T100000Z-abc123"
folder = workspace / "clients/pilot/handoff" / HANDOVER
SQL = "files/work/overview/query.sql"
PLACES = {"gliteral0000001": ("quoted-literal", "'0000412'", False), "gemail000000002": ("email", "jane@example.com", True)}


def files():
    out = []
    for rel in ("summary.md", SQL):
        data = (folder / rel).read_bytes()
        out.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
    return out


def answer(value, code=0):
    print(json.dumps(value, indent=2))
    sys.exit(code)


command = args[0]
if command == "pending":
    released = (folder / "released.json").exists()
    answer({"projects": [{"project": "pilot", "last_eu_activity_at": "2026-11-16T09:59:00.123456+00:00", "has_open_handoff": not released}]})
if command == "build":
    (folder / "files/work/overview").mkdir(parents=True, exist_ok=True)
    (folder / "summary.md").write_text("# Handover summary\n\n## Goal\n\nOrder overview.\n\n## Findings\n\n- VBAK.VBELN is unique.\n")
    (folder / SQL).write_text("SELECT * FROM vbak WHERE kunnr = '0000412'\n-- ask jane@example.com\nAND land = '0000412'\n")
    answer({"id": HANDOVER, "dir": str(folder), "files": files(), "summary_path": "summary.md",
            "skipped": [{"path": "out/rows.csv", "reason": "files in out/ never cross"}]})
if command == "scan":
    if (state / "handover-fail-scan").exists():
        (state / "handover-fail-scan").unlink()
        answer({"status": "error", "error": "simulated scan failure"}, 4)
    text = (folder / SQL).read_text()
    findings = []
    for number, line in enumerate(text.splitlines(), 1):
        for group, (kind, value, blocking) in PLACES.items():
            if value in line:
                findings.append({"file": SQL, "line": number, "col": line.index(value) + 1, "length": len(value), "kind": kind,
                                 "excerpt_masked": line.replace(value, f"[{kind}]"), "blocking": blocking, "group": group})
    answer({"id": HANDOVER, "clean": not findings, "findings": findings, "note": "simulated"}, 3 if findings else 0)
if command == "mask":
    groups = [args[i + 1] for i, a in enumerate(args) if a == "--group"]
    if (folder / "released.json").exists():
        answer({"status": "error", "error": f"Handover {HANDOVER} is released."}, 2)
    text = (folder / SQL).read_text()
    for group in groups:
        if group not in PLACES or PLACES[group][1] not in text:
            answer({"status": "error", "error": f"No finding of handover {HANDOVER} in group {group}."}, 2)
    for number, group in enumerate(groups, 1):
        kind, value, _ = PLACES[group]
        text = text.replace(value, f"[masked {kind} #{number}]")
    (folder / SQL).write_text(text)
    answer({"id": HANDOVER, "project": "pilot", "files": files(), "masked": [{"group": g, "kind": PLACES[g][0], "number": n, "places": 1}
                                                                            for n, g in enumerate(groups, 1)]})
answer({"status": "error", "error": f"unknown command {command}"}, 2)
