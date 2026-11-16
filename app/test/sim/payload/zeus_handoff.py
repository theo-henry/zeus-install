"""Simulated `scripts/zeus.py` of the EU workspace: only the handoff commands of the Zeus app contract (I2).

The real commands are in the private zeus repo (scripts/handoff.py, scripts/handoff_scan.py, references/eu-mode.md).
This fixture keeps their contract: the arguments, one JSON object per answer, the exit codes (0 ok, 2 user error,
3 findings, 4 internal error), the handover folders, the manifest, and the finding fields. Its scan finds e-mail
addresses (blocking), the known value ACME, and numbers with three or more digits. Each call is logged in
$ZEUS_SIM_STATE/handoff.log with the environment that matters (the app runs it outside Claude).
"""
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

ID = re.compile(r"\d{8}T\d{6}Z-[0-9a-f]{6}")


def out(value, code=0):
    print(json.dumps(value, indent=2))
    sys.exit(code)


def error(message, code=2):
    out({"status": "error", "error": message}, code)


def log(args):
    state = os.environ.get("ZEUS_SIM_STATE")
    if state:
        with open(Path(state) / "handoff.log", "a", encoding="utf-8") as handle:
            keep = {k: os.environ.get(k) for k in ("ZEUS_MODE", "ZEUS_EU_PROFILE", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CONFIG_DIR")}
            handle.write(json.dumps({"args": args, "cwd": os.getcwd(), "env": keep}) + "\n")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def handoffs(root, project):
    folder = root / "clients" / project / "handoff"
    return sorted(x for x in folder.iterdir() if x.is_dir() and ID.fullmatch(x.name)) if folder.is_dir() else []


def artifacts(text):
    section = re.search(r"^## Artifacts\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return [m.group(1) for m in re.finditer(r"^\s*-\s+`?([^\s`]+)`?", section.group(1) if section else "", re.M)]


def scan_text(rel, text):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for kind, pattern, blocking in (("email", r"[\w.+-]+@[\w-]+\.[a-z]{2,}", True), ("known-value", r"ACME", False),
                                        ("number", r"(?<![\w.])\d{3,}(?![\w])", False)):
            for match in re.finditer(pattern, line):
                excerpt = line[:match.start()] + f"[{kind}]" + line[match.end():]
                found.append({"file": rel, "line": number, "col": match.start() + 1, "kind": kind,
                              "excerpt_masked": excerpt[:120], "blocking": blocking})
    return found


def main():
    args = sys.argv[1:]
    log(args)
    root = Path.cwd()
    if args[:1] == ["--workspace"]:
        root, args = Path(args[1]), args[2:]
    if args[:1] != ["handoff"] or "--json" not in args:
        error("simulated zeus.py: only handoff ... --json")
    args = [x for x in args[1:] if x != "--json"]
    if root.resolve() != (Path.home() / "Code" / "zeus-eu").resolve():
        error("handoff summary, build, scan, and pending run only in the EU workspace (references/eu-mode.md).")
    command = args[0]
    if command == "pending":
        projects = []
        for path in sorted((root / "clients").glob("*/project.json")):
            found = handoffs(root, path.parent.name)
            projects.append({"project": path.parent.name, "last_eu_activity_at": "2026-11-16T10:00:00+00:00",
                             "has_open_handoff": bool(found) and (found[-1] / "summary.md").is_file()
                             and not (found[-1] / "released.json").exists()})
        out({"projects": projects})
    if command == "build":
        project = args[1]
        found = [x for x in handoffs(root, project) if (x / "summary.md").is_file()]
        if not found or (found[-1] / "released.json").exists():
            error(f"Project {project} has no handover summary.")
        folder = found[-1]
        files = folder / "files"
        if files.exists():
            shutil.rmtree(files)
        entries = [{"path": "summary.md", "sha256": sha(folder / "summary.md"), "bytes": (folder / "summary.md").stat().st_size}]
        skipped = []
        for rel in artifacts((folder / "summary.md").read_text(encoding="utf-8")):
            source = root / "clients" / project / rel
            if rel.startswith("out/") or source.suffix in (".csv", ".xlsx"):
                skipped.append({"path": rel, "reason": "this file type can hold rows"})
                continue
            if not source.is_file():
                skipped.append({"path": rel, "reason": "no such file"})
                continue
            target = files / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            entries.append({"path": f"files/{rel}", "sha256": sha(target), "bytes": target.stat().st_size})
        (folder / "manifest.json").write_text(json.dumps({"schema": 1, "id": folder.name, "project": project, "files": entries,
                                                          "skipped": skipped}, indent=2), encoding="utf-8")
        out({"id": folder.name, "project": project, "dir": str(folder), "files": entries, "summary_path": "summary.md",
             "skipped": skipped})
    if command == "scan":
        handover = args[1]
        folders = [x for x in (root / "clients").glob(f"*/handoff/{handover}") if x.is_dir()]
        if not ID.fullmatch(handover) or not folders:
            error(f"No handover {handover} in this workspace.")
        folder = folders[0]
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        findings = []
        for entry in manifest["files"]:
            path = folder / entry["path"]
            if sha(path) != entry["sha256"]:
                findings.append({"file": entry["path"], "line": 0, "col": 0, "kind": "changed-after-build", "excerpt_masked": "",
                                 "blocking": True})
            findings += scan_text(entry["path"], path.read_text(encoding="utf-8"))
        out({"id": handover, "project": folder.parent.parent.name, "clean": not findings, "findings": findings,
             "note": "The scan finds values that EU Zeus commands showed and common data patterns (simulated)."},
            3 if findings else 0)
    error(f"simulated zeus.py: unknown handoff command {command}")


if __name__ == "__main__":
    main()
