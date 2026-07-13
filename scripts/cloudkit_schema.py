#!/usr/bin/env python3
"""CloudKit schema guard for Dispatch's CloudKit-mirrored SwiftData store.

Why this exists
---------------
`NSPersistentCloudKitContainer` only CREATES a CloudKit record type / field the
first time a record that populates it is exported — and only in the DEVELOPMENT
environment (Production never auto-creates). So a new `@Model` field (or a whole
new synced model) that ships before its `CD_` field is deployed to Production
makes every export fail with `CKError.partialFailure` (code 2), silently
breaking cross-device sync. That is exactly what happened: `CD_PromptGroup` plus
~17 optional fields across `CD_Question` / `CD_Report` / `CD_Response` were never
deployed, so iPhone exports failed and Macs never received any data.

This tool derives the COMPLETE expected schema from `DispatchStore.allModels`
using the exact mapping SwiftData uses (validated field-for-field against
SwiftData's own auto-generated output — 53 fields, 0 mismatches), so drift is
caught mechanically instead of in a tester's diagnostics weeks later.

Commands
--------
  check              Verify CloudKit/schema.ckdb covers every model field with
                     the correct type. Hermetic (no CloudKit, no Xcode) — this
                     is the CI gate. Exit 1 on drift.
  generate           Regenerate the model record-type blocks in
                     CloudKit/schema.ckdb from the models. Run after changing a
                     synced @Model, commit the result, then DEPLOY it (see
                     docs/cloudkit-schema.md).
  verify-production  Compare the LIVE Production schema (via `xcrun cktool
                     export-schema`) against CloudKit/schema.ckdb — the deploy
                     gate. Needs a CloudKit management token on the machine.

Type mapping (SwiftData -> CloudKit), proven against the deployed schema:
  String/String?            -> STRING    QUERYABLE SEARCHABLE SORTABLE
  Int/Int?, Bool/Bool?      -> INT64     QUERYABLE SORTABLE
  Double/Double?            -> DOUBLE    QUERYABLE SORTABLE
  Date/Date?                -> TIMESTAMP QUERYABLE SORTABLE
  [T] / Codable value types -> BYTES     QUERYABLE SORTABLE
  to-one relationship       -> STRING    QUERYABLE SEARCHABLE SORTABLE
  to-many relationship      -> (no field; stored on the to-one inverse)
  every record type also gets CD_entityName STRING ... and the ___ system fields.
"""
from __future__ import annotations

import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(REPO, "Sources/DispatchKit/Models")
STORE_FILE = os.path.join(MODEL_DIR, "DispatchStore.swift")
SCHEMA_FILE = os.path.join(REPO, "CloudKit/schema.ckdb")

# (CloudKit type, index flags) for each SwiftData storage class.
STR = ("STRING", "QUERYABLE SEARCHABLE SORTABLE")
I64 = ("INT64", "QUERYABLE SORTABLE")
DBL = ("DOUBLE", "QUERYABLE SORTABLE")
TS = ("TIMESTAMP", "QUERYABLE SORTABLE")
BY = ("BYTES", "QUERYABLE SORTABLE")
SCALAR = {"String": STR, "Int": I64, "Double": DBL, "Bool": I64, "Date": TS}

SYSTEM_LINES = [
    ('"___createTime"', "TIMESTAMP"),
    ('"___createdBy"', "REFERENCE"),
    ('"___etag"', "STRING"),
    ('"___modTime"', "TIMESTAMP"),
    ('"___modifiedBy"', "REFERENCE"),
    ('"___recordID"', "REFERENCE"),
]
GRANT_LINES = [
    'GRANT WRITE TO "_creator"',
    'GRANT CREATE TO "_icloud"',
    'GRANT READ TO "_world"',
]


def _class_body(text: str, cls: str):
    """Return the brace-balanced body of `final class <cls>` (handles files that
    declare several models, e.g. Vocabulary.swift)."""
    m = re.search(r"final class " + cls + r"\b[^{]*\{", text)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(text) and depth:
        depth += 1 if text[i] == "{" else -1 if text[i] == "}" else 0
        i += 1
    return text[m.end():i - 1]


def _model_files():
    return {f: open(f).read() for f in glob.glob(MODEL_DIR + "/*.swift")}


def synced_models():
    """The model class names in DispatchStore.allModels (the authoritative list
    of CloudKit-mirrored types)."""
    text = open(STORE_FILE).read()
    m = re.search(r"allModels[^=]*=\s*\[(.*?)\]", text, re.DOTALL)
    if not m:
        sys.exit("error: could not find DispatchStore.allModels")
    return re.findall(r"(\w+)\.self", m.group(1))


def stored_properties(body: str):
    """[(name, swift_type)] for persisted stored properties — excludes computed
    vars (a `{` on the line) and @Transient."""
    out, lines = [], body.splitlines()
    for j, line in enumerate(lines):
        s = line.strip()
        prev = lines[j - 1].strip() if j else ""
        if s.startswith("@Transient") or prev.startswith("@Transient"):
            continue
        mm = re.match(r"(?:public |private )?(?:private\(set\) )?var (\w+)\s*:\s*([^={]+?)\s*(?:=|$)", s)
        if not mm or "{" in s:
            continue
        out.append((mm.group(1), mm.group(2).strip()))
    return out


def cd_field(swift_type: str, model_set: set):
    """Map a Swift property type to (CDTYPE, indexes), or None for a to-many
    relationship (which has no CloudKit field — the inverse to-one holds it)."""
    t = swift_type.rstrip("?").strip()
    if t.startswith("["):
        inner = t[1:-1].rstrip("?")
        return None if inner in model_set else BY  # to-many rel vs array attr
    if t in model_set:
        return STR  # to-one relationship -> stored as the related record id
    return SCALAR.get(t, BY)  # Codable value types fall through to BYTES


def expected_schema():
    """{CD_RecordType: {CD_field: (type, indexes)}} derived from the models."""
    files = _model_files()
    model_set = set(synced_models())
    out = {}
    for cls in synced_models():
        body = next((_class_body(t, cls) for t in files.values()
                     if re.search(r"final class " + cls + r"\b", t)), None)
        if body is None:
            sys.exit(f"error: model class {cls} (in allModels) not found under {MODEL_DIR}")
        fields = {"CD_entityName": STR}
        for name, typ in stored_properties(body):
            f = cd_field(typ, model_set)
            if f is not None:
                fields["CD_" + name] = f
        out["CD_" + cls] = fields
    return out


def parse_ckdb(path: str):
    """{RecordType: {field: (type, indexes)}} for a .ckdb schema file."""
    if not os.path.exists(path):
        sys.exit(f"error: schema file not found: {path}\n"
                 f"       run `python3 scripts/cloudkit_schema.py generate` to create it.")
    text = open(path).read()
    res = {}
    for m in re.finditer(r"RECORD TYPE (\w+) \((.*?)\);", text, re.DOTALL):
        d = {}
        for fm in re.finditer(r"(CD_\w+)\s+([A-Z0-9]+)((?: QUERYABLE| SEARCHABLE| SORTABLE)*),", m.group(2)):
            d[fm.group(1)] = (fm.group(2), fm.group(3).strip())
        res[m.group(1)] = d
    return res


def render_block(rectype: str, fields: dict) -> str:
    names = sorted(fields) + [n for n, _ in SYSTEM_LINES]
    width = max(len(n) for n in names)
    lines = [f"    RECORD TYPE {rectype} ("]
    for n in sorted(fields):
        ty, idx = fields[n]
        lines.append(f"        {n.ljust(width)} {ty} {idx},")
    for n, ty in SYSTEM_LINES:
        lines.append(f"        {n.ljust(width)} {ty},")
    for i, g in enumerate(GRANT_LINES):
        lines.append(f"        {g}" + ("," if i < len(GRANT_LINES) - 1 else ""))
    lines.append("    );")
    return "\n".join(lines)


# --- commands ---------------------------------------------------------------

def cmd_check() -> int:
    want = expected_schema()
    have = parse_ckdb(SCHEMA_FILE)
    problems = []
    for rectype, fields in want.items():
        got = have.get(rectype)
        if got is None:
            problems.append(f"{rectype}: MISSING entirely from CloudKit/schema.ckdb")
            continue
        for fname, (ty, idx) in fields.items():
            if fname not in got:
                problems.append(f"{rectype}.{fname}: missing ({ty}) — model field not in schema")
            elif got[fname] != (ty, idx):
                problems.append(f"{rectype}.{fname}: type {got[fname][0]} in schema, model expects {ty}")
    if problems:
        print("::error::CloudKit schema is behind the models — deploying these builds will break sync.")
        for p in problems:
            print("  - " + p)
        print("\nFix: `python3 scripts/cloudkit_schema.py generate`, commit CloudKit/schema.ckdb,")
        print("     then DEPLOY it (Development -> Production) — see docs/cloudkit-schema.md.")
        return 1
    total = sum(len(f) for f in want.values())
    print(f"CloudKit schema OK — {len(want)} record types, {total} model fields all present with correct types.")
    return 0


def cmd_generate() -> int:
    want = expected_schema()
    text = open(SCHEMA_FILE).read() if os.path.exists(SCHEMA_FILE) else _EMPTY_SCHEMA
    for rectype, fields in want.items():
        block = render_block(rectype, fields)
        text, n = re.subn(r"    RECORD TYPE " + rectype + r" \(.*?\);", block, text, count=1, flags=re.DOTALL)
        if n == 0:
            # Brand-new synced model (no block yet): insert before the first
            # public (non-CD_) record type so the CD_ types stay grouped, else
            # append at the end.
            pub = re.search(r"    RECORD TYPE (?!CD_)", text)
            if pub:
                text = text[:pub.start()] + block + "\n\n" + text[pub.start():]
            else:
                text = text.rstrip() + "\n\n" + block + "\n"
    os.makedirs(os.path.dirname(SCHEMA_FILE), exist_ok=True)
    open(SCHEMA_FILE, "w").write(text)
    print(f"wrote {os.path.relpath(SCHEMA_FILE, REPO)} ({len(want)} model record types regenerated)")
    return 0


def cmd_verify_production(argv) -> int:
    team = _flag(argv, "--team-id")
    container = _flag(argv, "--container-id")
    if not team or not container:
        sys.exit("verify-production needs --team-id and --container-id")
    try:
        out = subprocess.run(
            ["xcrun", "cktool", "export-schema", "--team-id", team,
             "--container-id", container, "--environment", "production"],
            capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        detail = getattr(e, "stderr", str(e))
        print(f"::error::could not read Production schema via cktool: {detail}")
        return 2
    prod = {}
    for m in re.finditer(r"RECORD TYPE (\w+) \((.*?)\);", out, re.DOTALL):
        prod[m.group(1)] = set(re.findall(r"\b(CD_\w+)\b", m.group(2)))
    committed = parse_ckdb(SCHEMA_FILE)
    behind = []
    for rectype, fields in committed.items():
        if not rectype.startswith("CD_"):
            continue
        for fname in fields:
            if fname not in prod.get(rectype, set()):
                behind.append(f"{rectype}.{fname}")
    if behind:
        print("::error::Production CloudKit schema is BEHIND CloudKit/schema.ckdb — deploy before shipping.")
        for b in behind:
            print("  - missing in Production: " + b)
        print("\nDeploy Development -> Production in the CloudKit Console (schema import is Development-only).")
        return 1
    print("Production CloudKit schema is up to date with CloudKit/schema.ckdb.")
    return 0


def _flag(argv, name):
    return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else None


_EMPTY_SCHEMA = "DEFINE SCHEMA\n\n    CREATE ROLE moderator;\n"


def main() -> int:
    argv = sys.argv[1:]
    cmd = argv[0] if argv else "check"
    if cmd == "check":
        return cmd_check()
    if cmd == "generate":
        return cmd_generate()
    if cmd == "verify-production":
        return cmd_verify_production(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
