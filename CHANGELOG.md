# changelog

This file records changes that affect Hilbert users. Internal build iterations
are folded into the release where they belong.

## 1.0.0

Hilbert 1.0.0 establishes the first documented language and bytecode free native
toolchain release for x86-64 GNU/Linux.

### language

- Added modules with explicit exports, selective imports, aliases, optional
  definition modules, and implementation divisions.
- Added records, record extension, enums, ranges, distinct scalar types, finite
  sets, tagged variants, fixed arrays, and slices.
- Added generic types and procedures, including recursive generic records.
- Added typed noncapturing procedure values and compatible C callbacks.
- Added checked indexing, range conversions, preconditions, assertions, and
  deferred cleanup.
- Added tasks, parallel branches, native threads, and sequentially consistent
  integer atomics.
- Reserved unfinished syntax rather than accepting forms that cannot reach
  native code safely.

### compiler

- Implemented the source pipeline from lexer and recursive descent parser
  through semantic analysis, borrow checking, typed HIR, optimization,
  verification, ABI classification, and x86-64 assembly.
- Added stable diagnostic codes, source locations, warning controls, bounded
  error recovery, and terminal aware color output.
- Added separate compilation for imported modules and content based object
  cache invalidation.
- Fixed optimizer handling of mutable locals, aggregate liveness, indirect
  calls, slices, numeric conversions, and imported values.
- Added System V aggregate calls, C boolean values, varargs promotions, and
  representable callback signatures.
- Rejects ABI shapes the native backend cannot implement safely.

### memory and runtime

- Added a conservative nonmoving collector with registered task and native
  thread stacks.
- Kept managed references separate from raw addresses and manual allocation.
- Added exclusive variable parameter checks and diagnostics for obvious aliases
  and escaping stack addresses.
- Added strict runtime warnings, static analysis, sanitizer coverage, collector
  stress tests, terminal restoration tests, and runtime traps.

### library and bindings

- Added sixty four standard library modules covering text, files, paths,
  directories, processes, terminals, networking, time, buffers, collections,
  memory, threads, tasks, atomics, logging, and testing.
- Added sixteen first party C binding modules with a focused example for each
  supported library.
- Kept platform dependent POSIX record layouts inside the runtime adapter.

### tooling

- Added the hilmake project builder with checked dependency graphs, profiles,
  incremental builds, parallel assembly, install manifests, and safe cleaning.
- Added repository, compiler, runtime, standard library, binding, example,
  project, installation, and archive release checks.
- Added reproducible source archives and staged archive rebuild tests.

### known limits

- Native code generation targets x86-64 GNU/Linux and the System V AMD64 ABI.
- Procedure values do not capture lexical environments.
- Native freestanding output and AArch64 code generation are not implemented.
- Generic constraints, exceptions, postconditions, protected record machinery,
  parallel loops, and expression type tests remain reserved.
- External C libraries are not bundled with their Hilbert bindings.
