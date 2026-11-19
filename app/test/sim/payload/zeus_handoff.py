"""Simulated `scripts/zeus.py` of the shared workspace: only the commands of the Zeus app contract that the app runs.

The real commands are in the private zeus repo (scripts/handoff.py, scripts/handoff_scan.py, scripts/eu_mode.py,
references/eu-mode.md, "App contract"). This fixture keeps their contract: the arguments, one JSON object per answer, the
exit codes (0 ok, 2 user error, 3 findings, 4 internal error), the handover folders, the manifest, and the finding fields
(with `length` and `group`). The app builds, scans, and masks in its own folder (`--dir <folder>`, the handover's own
folder, made with mode 700); the EU vault (~/.zeus/eu/vault/<project>/handoff/<id>/) keeps the summary that EU Zeus
wrote. The scan finds e-mail addresses (mask only), the known value ACME, and numbers with three or more digits;
`masked-<kind>-<n>` with n from 1 to 99 is not a finding. Each call is logged in $ZEUS_SIM_STATE/handoff.log with the script path, the import path, and the environment
that matters (the app runs it outside Claude, in the workspace ~/Code/zeus that EU and Standard share).

Test switches in $ZEUS_SIM_STATE: `scan-project` makes the scan answer name that project (a forged answer);
`mask-fails` makes the next mask fail after it masked the first group.
"""
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

ID = re.compile(r"\d{8}T\d{6}Z-[0-9a-f]{6}")
PLACEHOLDER = re.compile(r"masked-[a-z-]+-[1-9][0-9]?(?![0-9])|masked-[1-9][0-9]?(?![0-9])")
PATTERNS = (("email", r"[\w.+-]+@[\w-]+\.[a-z]{2,}"), ("known-value", r"ACME"), ("number", r"(?<![\w.-])\d{3,}(?![\w])"))
FILE_KINDS = ("missing-file", "changed-after-build")


def out(value, code=0):
    print(json.dumps(value, indent=2))
    sys.exit(code)


def error(message, code=2):
    out({"status": "error", "error": message}, code)


def state(name):
    folder = os.environ.get("ZEUS_SIM_STATE")
    return Path(folder) / name if folder else None


def log(args):
    path = state("handoff.log")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            keep = {k: os.environ.get(k) for k in ("ZEUS_MODE", "ZEUS_EU_PROFILE", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CONFIG_DIR", "CLAUDECODE")}
            handle.write(json.dumps({"args": args, "cwd": os.getcwd(), "script": os.path.realpath(__file__),
                                     "path": [os.path.realpath(x) for x in sys.path if x], "env": keep}) + "\n")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2), encoding="utf-8")


def handoffs(project):
    folder = Path.home() / ".zeus" / "eu" / "vault" / project / "handoff"
    return sorted(x for x in folder.iterdir() if x.is_dir() and ID.fullmatch(x.name)) if folder.is_dir() else []


def artifacts(text):
    section = re.search(r"^## Artifacts\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return [m.group(1) for m in re.finditer(r"^\s*-\s+`?([^\s`]+)`?", section.group(1) if section else "", re.M)]


def group(kind, value):
    return "g" + sha(f"sim\0{kind}\0{value.casefold()}".encode())[:15]


def spans(text):
    hidden = [m.span() for m in PLACEHOLDER.finditer(text)]
    found = []
    for kind, pattern in PATTERNS:
        for match in re.finditer(pattern, text):
            if not any(a <= match.start() < b for a, b in hidden):
                found.append((match.start(), match.end(), kind))
    return sorted(found)


def finding(rel, line, text, hit):
    start, end, kind = hit
    return {"file": rel, "line": line, "col": start + 1, "length": end - start, "kind": kind,
            "excerpt_masked": (text[:start] + f"[{kind}]" + text[end:])[:120], "blocking": kind == "email",
            "group": group(kind, text[start:end])}


def file_finding(rel, kind):
    return {"file": rel, "line": 0, "col": 0, "length": 0, "kind": kind, "excerpt_masked": "", "blocking": True, "group": group(kind, rel)}


def scan_folder(folder, manifest):
    found = []
    for entry in manifest["files"]:
        rel = entry["path"]
        path = folder / rel
        if not path.is_file():
            found.append(file_finding(rel, "missing-file"))
            continue
        data = path.read_bytes()
        if sha(data) != entry["sha256"]:
            found.append(file_finding(rel, "changed-after-build"))
        name = rel.removeprefix("files/")
        found += [finding(rel, 0, name, hit) for hit in spans(name)]
        for number, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
            found += [finding(rel, number, line, hit) for hit in spans(line)]
    return found


def app_folder(root, raw, create):
    """The --dir of the app: the handover's own folder, never in the workspace."""
    folder = Path(raw)
    if not folder.is_absolute() or ".." in folder.parts:
        error("--dir must be an absolute folder path without '..'.")
    if folder.resolve() == root.resolve() or root.resolve() in folder.resolve().parents:
        error(f"--dir {folder} is inside or holds {root}, which EU Claude can write.")
    if create:
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    if folder.is_symlink() or not folder.is_dir():
        error(f"--dir {folder} does not exist. Run handoff build with --dir first.")
    if folder.stat().st_mode & 0o022:
        error(f"--dir {folder} must belong to this user and be writable by this user only (mode 700).")
    return folder


def apply_masks(folder, files, masks):
    """Replace each masked value in the files and file names. Returns the new manifest entries."""
    entries = []
    for entry in files:
        rel = entry["path"]
        path = folder / rel
        data = path.read_text(encoding="utf-8")
        name = rel
        for mark in masks:
            data = data.replace(mark["value"], f"masked-{mark['kind']}-{mark['number']}")
            name = name.replace(mark["value"], f"masked-{mark['number']}")
        new = folder / name
        if new != path:
            path.unlink()
        new.parent.mkdir(parents=True, exist_ok=True)
        new.write_text(data, encoding="utf-8")
        entries.append({"path": name, "sha256": sha(new.read_bytes()), "bytes": new.stat().st_size})
    return entries


def build(root, project, folder):
    found = [x for x in handoffs(project) if (x / "summary.md").is_file()]
    if not found or (found[-1] / "released.json").exists():
        error(f"Project {project} has no handover summary. In the EU session, run handoff summary {project} first.")
    handover = found[-1].name
    held = folder / "manifest.json"
    if held.is_file() and (json.loads(held.read_text(encoding="utf-8")).get("id"), json.loads(held.read_text(encoding="utf-8")).get("project")) != (handover, project):
        error(f"--dir {folder} holds another handover. Use a new folder for handover {handover} of {project}.")
    manifest_path, source, masks_path = folder / "manifest.json", folder / "summary.source.md", folder / ".sim-masks.json"
    previous = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {}
    masks = json.loads(masks_path.read_text(encoding="utf-8")) if masks_path.is_file() else []
    built = next((x["sha256"] for x in previous.get("files", []) if x["path"] == "summary.md"), None)
    if not (folder / "summary.md").is_file():
        shutil.copyfile(found[-1] / "summary.md", source)
    elif built and sha((folder / "summary.md").read_bytes()) != built:
        shutil.copyfile(folder / "summary.md", source)  # the user edited the summary in the app
    elif not source.is_file():
        shutil.copyfile(folder / "summary.md", source)
    shutil.copyfile(source, folder / "summary.md")
    files = folder / "files"
    if files.exists():
        shutil.rmtree(files)
    entries = [{"path": "summary.md", "sha256": sha((folder / "summary.md").read_bytes()), "bytes": (folder / "summary.md").stat().st_size}]
    skipped = []
    for rel in artifacts((folder / "summary.md").read_text(encoding="utf-8")):
        origin = root / "clients" / project / rel
        if rel.startswith("out/") or origin.suffix in (".csv", ".xlsx"):
            skipped.append({"path": rel, "reason": "this file type can hold rows"})
            continue
        if origin.is_symlink() or not origin.is_file():
            skipped.append({"path": rel, "reason": "no such file"})
            continue
        target = files / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, target)
        entries.append({"path": f"files/{rel}", "sha256": sha(target.read_bytes()), "bytes": target.stat().st_size})
    if masks:
        entries = apply_masks(folder, entries, masks)
    manifest = {"schema": 1, "id": handover, "project": project, "files": entries, "skipped": skipped}
    if masks:
        manifest["masked"] = [{k: m[k] for k in ("group", "kind", "number")} | {"places": 1} for m in masks]
    write_json(manifest_path, manifest)
    out({"id": handover, "project": project, "dir": str(folder), "files": entries, "summary_path": "summary.md", "skipped": skipped})


def built_folder(folder, project, handover):
    if not ID.fullmatch(handover) or not (folder / "manifest.json").is_file():
        error(f"Handover {handover} is not built. Run handoff build {project} --dir first.")
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("id") != handover or manifest.get("project") != project:
        error(f"The manifest of handover {handover} is not the one that handoff build {project} wrote.")
    return folder, manifest


def scan(base, project, handover):
    folder, manifest = built_folder(base, project, handover)
    findings = scan_folder(folder, manifest)
    forged = state("scan-project")
    answered = forged.read_text().strip() if forged and forged.is_file() else project
    out({"id": handover, "project": answered, "clean": not findings, "findings": findings,
         "note": "The scan finds values that EU Zeus commands showed and common data patterns (simulated)."}, 3 if findings else 0)


def mask(base, project, handover, groups):
    folder, manifest = built_folder(base, project, handover)
    findings = scan_folder(folder, manifest)
    if any(x["kind"] in FILE_KINDS for x in findings):
        error("These handover files changed or are missing since the build. Run handoff build again.")
    masks_path = folder / ".sim-masks.json"
    masks = json.loads(masks_path.read_text(encoding="utf-8")) if masks_path.is_file() else []
    fails = state("mask-fails")
    for index, name in enumerate(groups):
        hit = next((x for x in findings if x["group"] == name), None)
        if not hit:
            error(f"No finding of handover {handover} is in group {name}. Scan again and pass a group that the scan printed.")
        if fails and fails.is_file() and index == 1:
            fails.unlink()
            error("simulated failure in the middle of a mask", 4)
        if hit["line"]:
            text = (folder / hit["file"]).read_text(encoding="utf-8").splitlines()[hit["line"] - 1]
        else:
            text = hit["file"].removeprefix("files/")
        value = text[hit["col"] - 1:hit["col"] - 1 + hit["length"]]
        masks.append({"group": name, "kind": hit["kind"], "number": len(masks) + 1, "value": value})
        entries = apply_masks(folder, manifest["files"], masks[-1:])
        manifest["files"] = entries
        manifest["masked"] = [{k: m[k] for k in ("group", "kind", "number")} | {"places": 1} for m in masks]
        write_json(masks_path, masks)
        write_json(folder / "manifest.json", manifest)
        findings = scan_folder(folder, manifest)
    out({"id": handover, "project": project, "files": manifest["files"],
         "masked": [{k: m[k] for k in ("group", "kind", "number")} | {"places": 1} for m in masks if m["group"] in groups]})


def eu_access(project, value):
    path = Path.home() / ".zeus" / "eu" / "data-access" / f"{project}.json"
    if value is None:
        record = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None
        out({"project": project, "enabled": bool(record and record["enabled"]), "by": record and record["by"], "at": record and record["at"]})
    if os.environ.get("CLAUDECODE") == "1" or os.environ.get("CLAUDE_CODE_CHILD_SESSION") == "1":
        error("Only the user turns EU data access on or off, with the EU data access switch in the Zeus app.")
    old = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"schema": 1, "project": project, "enabled": value == "on", "by": os.environ.get("USER", "sim"),
              "at": datetime.now(timezone.utc).isoformat()}
    write_json(path, record)
    out({"project": project, "enabled": record["enabled"], "by": record["by"], "at": record["at"],
         "changed": not old or old["enabled"] != record["enabled"]})


def main():
    args = sys.argv[1:]
    log(args)
    root = Path.cwd()
    if args[:1] == ["--workspace"]:
        root, args = Path(args[1]), args[2:]
    if "--json" not in args:
        error("simulated zeus.py: only ... --json")
    args = [x for x in args if x != "--json"]
    if root.resolve() != (Path.home() / "Code" / "zeus").resolve():
        error("These commands run only in the Zeus workspace ~/Code/zeus (references/eu-mode.md).")
    base = None
    if "--dir" in args:
        index = args.index("--dir")
        base = app_folder(root, args[index + 1], create="build" in args)
        args = args[:index] + args[index + 2:]
    groups = []
    while "--group" in args:
        index = args.index("--group")
        groups.append(args[index + 1])
        args = args[:index] + args[index + 2:]
    if args[:1] == ["eu-access"] and len(args) in (2, 3):
        if not (root / "clients" / args[1] / "project.json").is_file():
            error(f"No project {args[1]} in this workspace.")
        eu_access(args[1], args[2] if len(args) == 3 else None)
    if args[:1] != ["handoff"] or len(args) < 2:
        error("simulated zeus.py: only handoff and eu-access")
    command = args[1]
    if command == "pending":
        projects = []
        for path in sorted((root / "clients").glob("*/project.json")):
            found = handoffs(path.parent.name)
            activity = (root / "clients" / path.parent.name / "work").is_dir()
            projects.append({"project": path.parent.name, "last_eu_activity_at": "2026-11-16T10:00:00+00:00" if activity else None,
                             "has_open_handoff": bool(found) and (found[-1] / "summary.md").is_file()
                             and not (found[-1] / "released.json").exists()})
        out({"projects": projects})
    if base is None:
        error(f"handoff {command} needs --dir, the handover folder of the app.")
    if command == "build" and len(args) == 3:
        build(root, args[2], base)
    if command == "scan" and len(args) == 4:
        scan(base, args[2], args[3])
    if command == "mask" and len(args) == 4 and groups:
        mask(base, args[2], args[3], groups)
    error(f"simulated zeus.py: unknown handoff command {' '.join(args[1:])}")


if __name__ == "__main__":
    main()
