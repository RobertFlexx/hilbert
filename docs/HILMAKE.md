# hilmake

`hilmake` is project glue around the compiler's real module graph. A
Hilbertfile describes inputs and build policy, it does not contain loops,
functions, templates or arbitrary commands.

```text
PROJECT Editor;

IDENTIFICATION
  NAME "pine"
  VERSION "1.0.0"
  DESCRIPTION "small text editor"
  AUTHOR "example author"
  LICENSE "MIT"
END

ROOT "src/Main.hil";
OUTPUT "build/pine";
BUILD_DIR "build/.hilbert";
PROFILE RELEASE;
TARGET "x86_64-linux-gnu";
RUNTIME HOSTED;
MODULE_PATH "src";
LIBRARY pthread;
INSTALL_DIR "bin";
INCREMENTAL TRUE;
KEEP_TEMPS FALSE;
STRIP FALSE;
STATIC FALSE;
END Editor;
```

The identification block is optional, as is every field inside it. It is
metadata for `info`, installation and later package tooling. It does not create
Hilbert constants or otherwise change the program.

`MODULE_PATH`, `LIBRARY_PATH` and `LIBRARY` may be repeated. The remaining
boolean setting is `WARNINGS_AS_ERRORS`.

## commands

```text
hilmake build
hilmake run -- --fullscreen
hilmake check
hilmake clean
hilmake rebuild
hilmake install --prefix ~/.local
hilmake uninstall --prefix ~/.local
hilmake info
hilmake targets
hilmake graph
hilmake graph --dot
hilmake explain
hilmake show
```

No arguments prints help. `build` is the documented action once an action is
given. `show` prints all resolved build settings, while `info` is the shorter
project and release view. Unknown commands have a bounded spelling suggestion
instead of falling into the project parser.

`run` builds first and then replaces hilmake with the output using `execv`.
There is no helper shell between the terminal and the program. Arguments after
`--`, ctrl-c, ordinary terminal input and the child exit status therefore
behave as they do for direct execution.

`install` currently installs the executable under `PREFIX/INSTALL_DIR` and
writes a project manifest under `PREFIX/share/hilmake`. `uninstall` reads that manifest and refuses
paths outside the selected prefix. It never searches the prefix or guesses
what belongs to the project.

## profiles, targets and runtime selection

The three standard profiles are small aliases:

- `debug`: `-O0 -g`
- `release`: `-O3`
- `size`: `-Os`

Use `--profile`, `--target` and `--runtime` to override the Hilbertfile for one
command. Those values are passed to the compiler, which selects active
`DIVISION` declarations. A freestanding runtime can be checked, but native
freestanding linking is rejected until the backend has a real startup and
linker profile.

## output and incremental builds

A normal build prints the project, target, profile and runtime, followed by
the modules that actually compile and the final link result. A true no-op says
the output is up to date. `-q` keeps successful commands quiet. `-v` prints
copy-pastable compiler, assembler and linker commands. `-vv` or `--trace` also
shows cache explanations and parallel batch details. `NO_COLOR` and
`--no-color` disable color; `--color auto|always|never` is the explicit form.

Object names include the compiler cache generation, module role, target,
profile, runtime, optimization and debug settings. A sidecar fingerprint covers
the module source, optional definition module and direct imported sources. This
catches content changes even when a timestamp is restored. The final link has
an exact-command stamp, so changed libraries, paths, objects or link modes do
not reuse the wrong executable.

`hilmake explain` or `hilmake build --explain` reports why a module had no
usable object. `graph` asks the compiler for the checked, active dependency
graph. Plain text needs no extra tool; `--dot` only emits DOT and does not make
Graphviz a build dependency.

The frontend and generic-instantiation graph remain dependency ordered. `-j2`
through `-j8` parallelizes independent native assembly after typed module code
has been emitted. Each job has a separate error log, so parallel failures stay
readable. This is a useful speedup without making the stateful bootstrap
frontend pretend it is safely process-isolated.

`clean` accepts only relative build/output paths without `..`, rejects a build
directory containing the entry source, removes the build directory recursively
and treats the output as a file. `rebuild` uses the same checks before building
again. Paths and command arguments are single-quote escaped, including spaces
and apostrophes.
