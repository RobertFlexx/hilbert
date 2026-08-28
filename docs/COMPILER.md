# compiler guts

there is not a giant framework hiding in here, it is a pile of fairly normal modula-2 passes:

```text
source -> lexer -> parser -> ast -> semantics -> borrow checker
       -> typed hir -> optimizer -> verifier -> x86-64 -> assembler/linker
```

`Source`, `Lexer` and `Parser` do what their names say. parsing is hand-written recursive descent.

`Symbols`, `Types`, `Layout`, `Signatures`, `Interfaces` and `Methods` are the shared type/name bookkeeping. `Divisions` evaluates the small target/profile condition language. `Semantics` resolves names, gives active divisions child scopes, promotes their explicit implementation exports, checks types/calls/assignments and publishes module interfaces. Active division declarations are flattened only after checking so the existing lowering pipeline still sees one compilation unit. `BorrowCheck` is the small `VAR`/raw-pointer pass. `Generics` owns canonical generic type instances and `GenericProcedures` specializes procedure bodies before their ordinary semantic pass.

`Lower` turns checked ast into hir, inserting bounds/range work, indirect calls, short-circuit branches and cleanup while it goes. sets use integer bit operations and variants use their ordinary deterministic record layout, so neither needs a magic backend-only representation. `Optimize` does conservative folding, branch cleanup and dead-value work without treating mutable value slots as SSA. `Verify` rejects malformed HIR before `ABI` classifies SysV values and `X64` emits assembly. `Driver` owns implementation/definition pairing, imports, object reuse, runtime selection and the final toolchain commands.

most compiler structures use integer ids into arenas. they are cheap to allocate and the whole lot can be dropped when a module compile is done, which has been simpler than trying to keep a complicated persistent object graph alive.

## runtime

programs that use managed references, tasks or another runtime entry point link `runtime/hilbert_rt.c`. manual-memory-only programs do not need to drag the gc in.

the collector is non-moving and conservative. during a stop-the-world pass it avoids libc allocation, and stacks made by the hilbert task trampoline are registered before user code runs.

## object reuse

imports compile to their own object files. the cache filename includes generation `v31`, module role, target, profile, runtime selection, optimization and debug settings. reuse compares a cached content fingerprint for the implementation, optional definition file and direct imported source/interface files. changing contents without changing a timestamp still rebuilds. runtime objects use generation `v4` and their own content fingerprint.

the semantic and generic-instantiation graph stays dependency ordered. with `--jobs` greater than one, emitted module assembly is assembled in bounded parallel batches. each job writes a separate log, so a failed assembler does not smear several diagnostics across the terminal.

the final link has a separate stamp containing the exact linker command. a build skips linking only when every module object was reused, the command still matches, the output has not been replaced since the stamp, and it is newer than every input object. changing target, optimization, static/strip mode, library paths or libraries invalidates the stamp. this cuts the small benchmark project's warm `hilmake` build from a forced-link median around 27 ms to about 7 ms on the development machine; use `tools/benchmark.py` for a same-machine comparison instead of treating that number as universal.

there is no compiler daemon. startup is cheap enough that i would rather keep `hilbert build foo.hil` as a plain command for now.
