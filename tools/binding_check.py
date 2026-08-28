#!/usr/bin/env python3
"""Cheap ABI hygiene checks for Hilbert's first-party C bindings.

This does not pretend to replace compiling against the real C headers.  It catches
repo-level mistakes that are otherwise embarrassingly easy to ship: duplicate
exports, private foreign procedures, stale raylib 5.x spellings, and malformed
module endings.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
bindings = root / "bindings"
errors: list[str] = []

export_re = re.compile(r"^EXPORT\s+(.+?);", re.M)
proc_re = re.compile(r'\b(?:FOREIGN\s+"C"\s+)?PROCEDURE\s+(\w+)')
module_re = re.compile(r"\bMODULE\s+([A-Za-z_]\w*)\s*;")

for path in sorted(bindings.glob("*.hil")):
    text = path.read_text(errors="replace")
    module = module_re.search(text)
    if not module:
        errors.append(f"{path.name}: missing MODULE header")
        continue
    name = module.group(1)
    if not re.search(rf"\bEND\s+{re.escape(name)}\s*\.\s*$", text):
        errors.append(f"{path.name}: malformed END {name}.")

    exports: list[str] = []
    for match in export_re.finditer(text):
        exports.extend(x.strip() for x in match.group(1).split(",") if x.strip())
    dupes = sorted({x for x in exports if exports.count(x) > 1})
    if dupes:
        errors.append(f"{path.name}: duplicate exports: {', '.join(dupes)}")

    procedures = proc_re.findall(text)
    hidden = sorted(set(procedures) - set(exports))
    if hidden:
        errors.append(f"{path.name}: procedures not exported: {', '.join(hidden)}")

# raylib is pinned to 6.0.  These are small sentinel checks for
# API changes that previously slipped through while the file still said "6.0".
raylib = (bindings / "Raylib.hil").read_text(errors="replace")
required_raylib = (
    "FOREIGN \"C\" PROCEDURE LoadRandomSequence(Count: CARDINAL32; Min, Max: INTEGER32): POINTER TO INTEGER32;",
    "FOREIGN \"C\" PROCEDURE DecodeDataBase64(Text: CSTRING; OutputSize: POINTER TO INTEGER32): POINTER TO BYTE;",
    "FOREIGN \"C\" PROCEDURE DrawCircleGradient(Center: Vector2; Radius: REAL32; Inner, Outer: Color);",
    "FOREIGN \"C\" PROCEDURE ColorToInt(Value: Color): INTEGER32;",
    "FOREIGN \"C\" PROCEDURE ComputeSHA256(Data: POINTER TO BYTE; DataSize: INTEGER32): POINTER TO CARDINAL32;",
    "FOREIGN \"C\" PROCEDURE DrawLineDashed(StartPos, EndPos: Vector2; DashSize, SpaceSize: INTEGER32; ColorData: Color);",
    "FOREIGN \"C\" PROCEDURE UploadMesh(MeshData: POINTER TO Mesh; Dynamic: BOOLEAN);",
)
for signature in required_raylib:
    if signature not in raylib:
        errors.append(f"Raylib.hil: missing raylib 6.0 sentinel: {signature}")
for stale in ("LoadImageSvg", "DrawCircleGradient(CenterX", "LoadRandomSequence(Count: CARDINAL32; Min, Max: CARDINAL32)"):
    if stale in raylib:
        errors.append(f"Raylib.hil: stale pre-6.0 API spelling/signature: {stale}")

if errors:
    print("\n".join(errors))
    sys.exit(1)

foreign_count = len(re.findall(r'\bFOREIGN\s+"C"\s+PROCEDURE\s+', raylib))
print(f"ok: {len(list(bindings.glob('*.hil')))} bindings checked; Raylib exposes {foreign_count} C procedures plus Hilbert helpers")
