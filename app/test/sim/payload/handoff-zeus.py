#!/usr/bin/env python3
"""Simulated scripts/zeus.py of a Zeus workspace, for the EU handoff of the Zeus app (test scenario 6).

It answers `handoff pending|build|scan|release ... --json` with canned JSON. The file <state>/handoff-mode chooses the case:
none (no project needs a handoff), clean, findings, error (the build fails), pending-error (the pending check fails).
Each call is written to <state>/handoff-calls and, with the time order of the zeus sessions, to <state>/sessions.
"""
import json
import os
import sys
import time

state = os.environ["ZEUS_SIM_STATE"]
mode_file = os.path.join(state, "handoff-mode")
mode = open(mode_file).read().strip() if os.path.exists(mode_file) else "none"
args = sys.argv[1:]
workspace = "-"
if args[:1] == ["--workspace"]:
    workspace, args = args[1], args[2:]
with open(os.path.join(state, "handoff-calls"), "a") as log:
    log.write(" ".join(args) + f" cwd={os.getcwd()} workspace={workspace} claude={os.environ.get('CLAUDECODE', '-')}"
              f" session={os.environ.get('ZEUS_SESSION_ID', '-')} blind={os.environ.get('ZEUS_BLIND_MODE', '-')}\n")
with open(os.path.join(state, "sessions"), "a") as log:
    log.write(f"{os.getpid()} handoff {' '.join(args[:2])}\n")


STEPS = [("collect", "Collecting EU work"), ("strip", "Removing row values"), ("aggregate", "Aggregating to structure"),
         ("scan", "Scanning for sensitive values"), ("review", "Writing the review page")]


def progress(steps):
    # As scripts/zeus.py: one {"stage", "label"} line on stderr when each step starts.
    for key, label in steps:
        print(json.dumps({"stage": key, "label": label}), file=sys.stderr, flush=True)
        time.sleep(0.05)


def answer(value, code=0):
    print(json.dumps(value))
    sys.exit(code)


if args[:1] != ["handoff"] or "--json" not in args:
    answer({"error": "unknown command", "fix": "simulated zeus.py knows only handoff ... --json"}, 2)
command = args[1]
if command == "pending":
    if mode == "pending-error":
        answer({"error": "The project records cannot be read.", "fix": "Run zeus doctor."}, 1)
    needs = mode != "none"
    answer({"projects": [
        {"project_id": "solvias", "name": "Solvias", "eu_work": {"first_at": "2026-11-13T09:00:00Z", "last_at": "2026-11-13T15:40:00Z"},
         "released_at": None, "needs_handoff": needs},
        {"project_id": "vicat", "name": "Vicat", "eu_work": None, "released_at": "2026-11-10T10:00:00Z", "needs_handoff": False},
    ]})
findings = [] if mode == "clean" else [
    {"kind": "email", "where": "sql/transformations/vendor.sql:14", "preview": "j***@***.com"},
    {"kind": "long-number", "where": "work/view-ap/spec.json:/filters/2", "preview": "4*** (10 characters)"},
]


def result(steps):
    return {
        "project_id": args[2], "ok": not findings, "hash": "a" * 64, "findings": findings,
        "summary": {"knowledge_models": 1, "tables": 14, "columns": 212, "object_types": 6, "event_types": 9, "perspectives": 0,
                    "transformations": 11, "artifacts": 4, "verdicts": 3, "tasks": 2, "open_tasks": 1, "decisions": 2, "omitted": 0,
                    "scan_findings": len(findings)},
        # As scripts/handoff.py (machine): {"id", "label", "status"}; findings block the review step.
        "stages": [{"id": key, "label": label, "status": "done"} if key != "review" or not findings else
                   {"id": key, "label": f"Blocked: {len(findings)} finding(s) to resolve", "status": "blocked"} for key, label in steps],
        "draft": os.path.join(os.getcwd(), "clients", args[2], "handoff", "draft.json"),
        "review_page": os.path.join(os.getcwd(), "clients", args[2], "handoff", "review.html"),
        "built_at": "2026-11-13T16:00:00Z", "omitted": [],
    }


if command == "build":
    # ZEUS_SIM_HANDOFF_DELAY: the build takes that long (s), for a screenshot of the step while it runs.
    progress(STEPS[:1])
    time.sleep(float(os.environ.get("ZEUS_SIM_HANDOFF_DELAY") or 0))
    if mode == "error":
        answer({"error": "The data profile of Solvias is from an older Zeus.", "fix": "Run `zeus profile solvias` in the EU window, then switch again."}, 1)
    progress(STEPS[1:])
    answer(result(STEPS))
if command == "scan":
    progress(STEPS[3:])
    answer(result(STEPS[3:]))
if command == "release":
    if len(args) < 4 or args[3] != "a" * 64:
        answer({"error": "The handoff hash does not match.", "fix": "Open the review page again.", "released": False}, 4)
    answer({"released": True, "project_id": args[2], "path": f"clients/{args[2]}/handoff/released.json", "hash": args[3], "at": "2026-11-13T16:01:00Z"})
answer({"error": f"unknown handoff command {command}"}, 2)
