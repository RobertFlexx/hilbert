#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
mods = list((root / "compiler").glob("*.mod"))
defs = {p.stem for p in (root / "compiler").glob("*.def")}
errors = []

generated_roots = {"build", "dist", ".git"}
for p in root.rglob("*"):
    relative = p.relative_to(root)
    if relative.parts and relative.parts[0] in generated_roots:
        continue
    if p.name == "__pycache__" and p.is_dir():
        errors.append(f"python cache directory in source tree: {relative}")
    elif p.is_file() and p.suffix in {".pyc", ".pyo", ".plist"}:
        errors.append(f"generated analysis/cache file in source tree: {relative}")

# Keep prose and comments in the project's ordinary voice.  This also catches
# pasted release copy before it becomes scattered through the tree.
text_roots = [
    root / "compiler", root / "buildsys", root / "runtime", root / "stdlib",
    root / "bindings", root / "examples", root / "tests", root / "tools",
    root / "docs", root / "bootstrap", root / "selfhost",
]
text_files = [
    root / "README.md", root / "CHANGELOG.md", root / "CONTRIBUTING.md",
    root / "Makefile", root / "install.sh", root / ".gitignore",
]
for folder in text_roots:
    text_files.extend(p for p in folder.rglob("*") if p.is_file())
for p in text_files:
    try:
        text = p.read_text()
    except UnicodeDecodeError:
        continue
    if chr(0x2014) in text:
        errors.append(f"em dash in {p.relative_to(root)}")

for p in root.glob("*.plist"):
    errors.append(f"stale analyzer output in repository root: {p.name}")

for p in mods:
    if p.stem == "hilbert":
        continue
    if p.stem not in defs:
        errors.append(f"missing definition module for {p.name}")

for p in (root / "compiler").glob("*.*"):
    text = p.read_text(errors="replace")
    if "\t" in text:
        errors.append(f"tab in {p.relative_to(root)}")

for folder in ("stdlib", "bindings"):
    for p in (root / folder).glob("*.hil"):
        txt = p.read_text(errors="replace")
        m = re.search(r"\bMODULE\s+([A-Za-z0-9_.]+)", txt)
        if not m:
            errors.append(f"no MODULE in {p.relative_to(root)}")
        elif f"END {m.group(1)}." not in txt:
            errors.append(f"bad module terminator in {p.relative_to(root)}")

example_files = sorted((root / "examples").rglob("*.hil"))
example_modules = {}
for p in example_files:
    txt = p.read_text(errors="replace")
    m = re.search(r"\bMODULE\s+([A-Za-z0-9_]+)", txt)
    if not m:
        errors.append(f"no MODULE in {p.relative_to(root)}")
        continue
    name = m.group(1)
    if f"END {name}." not in txt:
        errors.append(f"bad module terminator in {p.relative_to(root)}")
    if name in example_modules:
        errors.append(
            f"duplicate example module {name}: "
            f"{example_modules[name].relative_to(root)} and {p.relative_to(root)}"
        )
    example_modules[name] = p

# Bindings install into the normal module namespace.  A duplicate basename here
# would make IMPORT depend on search order, which is exactly the kind of stupid
# release bug that is hard to spot after packaging.
stdlib_names = {p.stem for p in (root / "stdlib").glob("*.hil")}
binding_names = {p.stem for p in (root / "bindings").glob("*.hil")}
for name in sorted(stdlib_names & binding_names):
    errors.append(f"stdlib/binding module namespace collision: {name}")

binding_example_imports = set()
for p in (root / "examples/bindings").glob("*.hil"):
    text = p.read_text(errors="replace")
    for match in re.finditer(r"\bIMPORT\s+([^;]+);", text):
        binding_example_imports.update(
            name.strip() for name in match.group(1).split(",") if name.strip()
        )
missing_binding_examples = sorted(binding_names - binding_example_imports)
if missing_binding_examples:
    errors.append(
        "first-party bindings without an example: " + ", ".join(missing_binding_examples)
    )

example_loc = sum(len(p.read_text(errors="replace").splitlines()) for p in example_files)
if len(example_files) < 32 or example_loc < 600:
    errors.append(
        f"example catalog is unexpectedly small: {len(example_files)} files, {example_loc} lines"
    )

required = {
    "compiler/BorrowCheck.mod": "EBorrowAlias",
    "compiler/Lower.mod": "hilbert_gc_alloc",
    "compiler/X64.mod": "hilbert_rt_task_start",
    "compiler/Driver.mod": "RuntimeNeeded",
    "runtime/hilbert_rt.c": "hilbert_gc_try_alloc",
    "stdlib/GC.hil": "MODULE GC",
    "stdlib/ManualMemory.hil": "MODULE ManualMemory",
    "buildsys/hilmake.mod": "MODULE hilmake",
    "docs/MEMORY.md": "non-moving",
    "docs/SAFETY.md": "borrow checker",
    "tests/runtime_gc_stress.c": "gc stress ok",
    "tests/compile-fail/borrow_alias.hil": "Pair(X, X)",
    "examples/README.md": "first-party binding examples",
    "stdlib/FileInfo.hil": "hilbert_rt_posix_stat",
    "docs/POSIX.md": "typed directory iteration",
    "tests/posix_stdlib.hil": "Process.Run",
}
for rel, needle in required.items():
    p = root / rel
    if not p.exists():
        errors.append(f"missing release component {rel}")
    elif needle not in p.read_text(errors="replace"):
        errors.append(f"{rel} is missing expected integration marker {needle!r}")

if "hilbert_rt_posix_dir_next" not in (root / "runtime/hilbert_rt.c").read_text(errors="replace"):
    errors.append("runtime is missing the POSIX directory adapter")

# The published grammar is part of the stable surface.  Every named symbol on
# a right-hand side must have a production, otherwise downstream tooling sees
# an incomplete sketch rather than the 1.0 grammar.
grammar_path = root / "docs/GRAMMAR.ebnf"
grammar = grammar_path.read_text(errors="replace")

def strip_ebnf_regions(text):
    # Wirth EBNF has no escape character, comments nest, and "? ... ?" or
    # string regions may hold quotes, brackets or comment markers of their
    # own.  Scan sequentially so one region can never swallow the next.
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if text.startswith("(*", i):
            depth = 1
            j = i + 2
            while j < n and depth:
                if text.startswith("(*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*)", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(" ")
            i = j
        elif ch == "?" or ch == '"' or ch == "'":
            j = text.find(ch, i + 1)
            j = n if j < 0 else j + 1
            out.append(" ")
            i = j
        else:
            out.append(ch)
            i += 1
    return "".join(out)

grammar_scan = strip_ebnf_regions(grammar)
defined_grammar = set(re.findall(r"(?m)^\s*([A-Z][A-Za-z0-9]*)\s*=", grammar_scan))
used_grammar = set(re.findall(r"\b[A-Z][A-Za-z0-9]*\b", grammar_scan))
undefined_grammar = sorted(used_grammar - defined_grammar)
if undefined_grammar:
    errors.append("undefined grammar productions: " + ", ".join(undefined_grammar))


# Keep the two memory worlds separate: managed/runtime users get the runtime,
# manual-only programs should not be forced to carry it.
driver = (root / "compiler/Driver.mod").read_text(errors="replace")
if "IF RuntimeNeeded AND NOT EnsureRuntime" not in driver:
    errors.append("runtime is not linked conditionally")
if "ScanRuntimeNeeds" not in driver:
    errors.append("driver does not scan module graphs for runtime requirements")

borrow = (root / "compiler/BorrowCheck.mod").read_text(errors="replace")
for needle in ("EBorrowAlias", "EEscapingBorrow", "EUnsafePointerAccess", "IsBorrowed"):
    if needle not in borrow:
        errors.append(f"borrow checker is missing {needle}")

# A release regression that once turned integer literals into zero must never return.
lower = (root / "compiler/Lower.mod").read_text(errors="replace")
x64 = (root / "compiler/X64.mod").read_text(errors="replace")
if "Assign(X.Text,N.Text)" not in lower:
    errors.append("integer literal spelling is not preserved into HIR")
if "ImmediateLiteral(X.Text" not in x64:
    errors.append("x86-64 backend is not normalizing source integer literals")


# GNU Modula-2 PIM is strict.  Keep a few easy-to-regress
# compatibility rules in the ordinary repository check so the bootstrap does
# not drift toward syntax accepted only by looser Modula-2 implementations.
for folder in (root / "compiler", root / "buildsys"):
    for p in folder.glob("*.mod"):
        text = p.read_text(errors="replace")
        # gm2 PIM does not allow selecting a record field directly from a
        # function result (Get(...).Field).  Store the result in a record first.
        if re.search(r"(?:[A-Za-z_]\w*\.)?[A-Za-z_]\w*\([^;()]*\)\.[A-Za-z_]\w*", text):
            errors.append(f"gm2-pim call-result field selector in {p.relative_to(root)}")

        imports = {}
        for m in re.finditer(r"FROM\s+(\w+)\s+IMPORT\s+([^;]+);", text, re.I | re.S):
            module = m.group(1)
            for name in (x.strip() for x in m.group(2).replace("\n", " ").split(",")):
                imports.setdefault(name, []).append(module)
        locals_ = set(re.findall(r"PROCEDURE\s+(?:\([^)]*\)\s*)?(\w+)", text, re.I))
        for name, modules in imports.items():
            if len(modules) > 1 or name in locals_:
                errors.append(f"gm2-pim imported-name clash {name} in {p.relative_to(root)}")



# Keep the bootstrap free of explicit FORWARD directives.  The declarations
# are ordered so the PIM source remains portable across strict Modula-2 compilers.
for folder in (root / "compiler", root / "buildsys"):
    for p in folder.glob("*.mod"):
        text = p.read_text(errors="replace")
        if re.search(r"\bFORWARD\s*;", text):
            errors.append(f"ISO-only FORWARD directive in PIM bootstrap: {p.relative_to(root)}")


# Type identifiers used as transfer functions are not general numeric casts in
# Modula-2.  Cross-width conversions in the bootstrap must use VAL(Type, value).
for folder in (root / "compiler", root / "buildsys"):
    for p in folder.glob("*.mod"):
        text = p.read_text(errors="replace")
        if re.search(r"\b(?:INTEGER|CARDINAL|LONGINT|LONGCARD)\s*\(", text):
            errors.append(f"numeric transfer-function cast instead of VAL in {p.relative_to(root)}")
        if re.search(r"\bS\.Debug\b", text):
            errors.append(f"stale Settings.Debug field in {p.relative_to(root)}")
        # AST operator tags live in a LONGINT slot.  Converting that slot to
        # an enumeration with a transfer function, or comparing it directly
        # with ORD() (CARDINAL in PIM), is rejected by strict gm2.  Always go
        # through Tokens.FromOrdinal / VAL and compare enum values to enum values.
        if re.search(r"\bTokenKind\s*\(\s*[^)]*IntValue", text):
            errors.append(f"TokenKind transfer cast from AST IntValue in {p.relative_to(root)}")
        if re.search(r"\bIntValue\b\s*(?:#|<=|>=|<|>|=)\s*ORD\s*\(", text) or \
           re.search(r"\bORD\s*\([^)]*\)\s*(?:#|<=|>=|<|>|=)\s*[^;\n]*\bIntValue\b", text):
            errors.append(f"mixed LONGINT/CARDINAL operator comparison in {p.relative_to(root)}")
        if re.search(r"\bIntValue\s*:=\s*ORD\s*\(", text):
            errors.append(f"implicit CARDINAL-to-LONGINT token ordinal assignment in {p.relative_to(root)}")

# Every unqualified stable diagnostic referenced by a compiler module must be
# imported from ErrorCodes (except ErrorCodes.mod itself).
error_def = (root / "compiler/ErrorCodes.def").read_text(errors="replace")
known_codes = set(re.findall(r"\b([EW][A-Za-z0-9_]+)\s*=", error_def))
error_impl = (root / "compiler/ErrorCodes.mod").read_text(errors="replace")
mapped_codes = set(re.findall(r"\|\s*([EW][A-Za-z0-9_]+)\s*:", error_impl))
unmapped_codes = sorted(known_codes - mapped_codes)
if unmapped_codes:
    errors.append("stable diagnostics without default messages: " + ", ".join(unmapped_codes))
for p in (root / "compiler").glob("*.mod"):
    if p.stem == "ErrorCodes":
        continue
    text = p.read_text(errors="replace")
    refs = set(re.findall(r"\b([EW][A-Z][A-Za-z0-9_]+)\b", text)) & known_codes
    imported = set()
    for m in re.finditer(r"FROM\s+ErrorCodes\s+IMPORT\s+([^;]+);", text, re.I | re.S):
        imported.update(x.strip() for x in m.group(1).replace("\n", " ").split(","))
    missing = sorted(refs - imported)
    if missing:
        errors.append(f"missing ErrorCodes imports in {p.relative_to(root)}: {', '.join(missing)}")

# GCC 16 checks public procedure headings more strictly than older gm2 builds:
# formal parameter identifiers in the implementation must agree with the
# definition module, not merely their types and modes.
def scan_proc_heads(text):
    out = {}
    i = 0
    while True:
        m = re.search(r"\bPROCEDURE\b", text[i:])
        if not m:
            break
        start = i + m.start()
        j = start + len("PROCEDURE")
        while j < len(text) and text[j].isspace():
            j += 1
        nm = re.match(r"[A-Za-z_]\w*", text[j:])
        if not nm:
            i = j + 1
            continue
        name = nm.group(0)
        j += len(name)
        while j < len(text) and text[j].isspace():
            j += 1
        params = ""
        if j < len(text) and text[j] == "(":
            depth = 0
            begin = j + 1
            while j < len(text):
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        params = text[begin:j]
                        j += 1
                        break
                j += 1
        out.setdefault(name, params)
        semi = text.find(";", j)
        i = len(text) if semi < 0 else semi + 1
    return out

def formal_names(params):
    names = []
    for group in params.split(";"):
        group = re.sub(r"^\s*(?:VAR|CONST)\s+", "", group.strip(), flags=re.I)
        if ":" not in group:
            continue
        left = group.split(":", 1)[0]
        names.extend(x.strip() for x in left.split(",") if x.strip())
    return names

for d in (root / "compiler").glob("*.def"):
    m = root / "compiler" / (d.stem + ".mod")
    if not m.exists():
        continue
    defsigs = scan_proc_heads(d.read_text(errors="replace"))
    modsigs = scan_proc_heads(m.read_text(errors="replace"))
    for name, dparams in defsigs.items():
        if name in modsigs and formal_names(dparams) != formal_names(modsigs[name]):
            errors.append(
                f"gm2-pim public formal-name mismatch {d.stem}.{name}: "
                f"{formal_names(dparams)} != {formal_names(modsigs[name])}"
            )

# GNU Modula-2 implementation modules must be compiled with -c before the
# program module is linked.  Passing every .mod to one gm2 link invocation
# generates multiple application scaffolds / main symbols.
makefile = (root / "Makefile").read_text(errors="replace")
if "$(BUILD)/%.o: %.mod" not in makefile or "-c $< -o $@" not in makefile:
    errors.append("Makefile does not separately compile Modula-2 implementation modules")
if re.search(r"compiler/hilbert\.mod\s+\$\(COMPILER_MODULES\)", makefile):
    errors.append("Makefile links raw implementation .mod files beside the hilbert program module")
if re.search(r"buildsys/hilmake\.mod\s+\$\(HILMAKE_MODULES\)", makefile):
    errors.append("Makefile links raw implementation .mod files beside the hilmake program module")


# Final executables use a static scaffold so the initialization/finalization
# order is explicit even though implementation modules are separately compiled.
if "-fscaffold-static" not in makefile or "-fno-scaffold-dynamic" not in makefile:
    errors.append("Makefile does not force a static GNU Modula-2 application scaffold")
if "install -m644 bindings/*.hil $(DESTDIR)$(PREFIX)/share/hilbert/stdlib/" not in makefile:
    errors.append("first-party bindings are not installed into the standard module namespace")
if "cp -a examples/. $(DESTDIR)$(PREFIX)/share/hilbert/examples/" not in makefile:
    errors.append("example catalog is not installed with the toolchain")
for launcher in ("tools/hilbert-launcher.sh", "tools/hilmake-launcher.sh"):
    text = (root / launcher).read_text(errors="replace")
    if "HILBERT_HOME" not in text or "libexec/hilbert" not in text:
        errors.append(f"relocatable launcher is missing toolchain-root wiring: {launcher}")
for rel in ("compiler/hilbert.mod", "buildsys/hilmake.mod"):
    text = (root / rel).read_text(errors="replace")
    if re.search(r"FROM\s+libc\s+IMPORT[^;]*\bexit\b", text, re.I | re.S):
        errors.append(f"program module bypasses gm2 finalization with libc.exit: {rel}")


# Keep the source tree boring in the useful sense.  An em dash has a habit of
# sneaking back in when docs get rewritten, and adjacent duplicate headings are
# almost always a botched edit in Modula-2 source.
text_suffixes = {".mod", ".def", ".hil", ".md", ".ebnf", ".py", ".sh", ".c", ".h"}
for p in root.rglob("*"):
    if not p.is_file():
        continue
    if p.name in {"Makefile", "Hilbertfile", ".gitignore"} or p.suffix in text_suffixes:
        text = p.read_text(errors="replace")
        if "\u2014" in text:
            errors.append(f"em dash in {p.relative_to(root)}")

for folder in (root / "compiler", root / "buildsys"):
    for p in folder.glob("*.mod"):
        lines = [line.strip() for line in p.read_text(errors="replace").splitlines()]
        for a, b in zip(lines, lines[1:]):
            if not a or a != b:
                continue
            if re.match(r"PROCEDURE\s+", a, re.I) or re.fullmatch(r"END\s+\w+;", a, re.I) or a.startswith("|"):
                errors.append(f"adjacent duplicate source line in {p.relative_to(root)}: {a}")

readme = (root / "README.md").read_text(errors="replace")
if not re.fullmatch(r"[a-z\s]+", readme):
    errors.append("README may contain only lowercase letters and whitespace")

if errors:
    print("\n".join(errors))
    sys.exit(1)

stdlib_count = len(list((root / "stdlib").glob("*.hil")))
binding_count = len(list((root / "bindings").glob("*.hil")))
print(f"ok: {len(mods)} compiler implementations, {len(defs)} interfaces, "
      f"{stdlib_count} stdlib modules, {binding_count} first-party binding modules, "
      f"{len(example_files)} examples ({example_loc} lines)")
