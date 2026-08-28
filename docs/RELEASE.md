# releasing hilbert

Hilbert releases are built from the exact source tree that will be archived.
An earlier successful run does not cover later edits.

## supported scope

- Host and generated target: x86-64 GNU/Linux
- Native ABI: System V AMD64
- Bootstrap compiler: GNU Modula-2 in PIM mode
- Runtime: C11 with pthreads
- Installed tools: `hilbert` and `hilmake`
- Installed data: standard library, bindings, examples, documentation, and
  runtime source

This scope is intentionally narrow. Other targets should be documented only
after their compiler and runtime paths pass the same release gates.

## release gates

Start from a clean source tree:

```sh
make -j4
make release-check
make release-check-strict
make dist
make dist-check
```

The normal release gate checks:

- repository structure, grammar references, and binding declarations
- strict C compilation, collector tests, stress tests, and available static
  analyzers
- address and undefined behavior sanitizers when the host supports them
- compiler and hilmake command line behavior
- every checked in example at the frontend
- native build and execution for language and standard library examples
- language, optimizer, ABI, callback, trap, and compile failure regressions
- dependency cache behavior in different module build orders
- isolated native links for every standard library module
- project graph, build, run, rebuild, clean, install, and uninstall behavior
- a staged installation used from outside the source tree

The strict gate requires address, undefined behavior, and leak sanitizers. Some
ptrace based sandboxes prevent LeakSanitizer from starting, so run this gate on
an ordinary release host.

Binding examples that open windows or depend on third party development
libraries are checked by the frontend in the normal gate. Before publishing a
binding release, run its native example on a suitable host with the documented
library version.

## source archive

`make dist` creates a versioned source archive and checksum under `dist/`.
Generated output, earlier archives, version control metadata, Python caches, and
analyzer output are excluded. Archive order, ownership, timestamps, and gzip
metadata are normalized.

`make dist-check` extracts the archive, checks its structure, rebuilds the
bootstrap, and compiles and runs an example without using the working tree.

## current boundaries

The native backend is x86-64 only. AArch64 is recognized by the frontend but has
no code generator. Captured closures and awkward by value aggregate signatures
are not implemented. Callers should use variable parameters, managed
references, or pointers when a direct aggregate ABI shape is unsupported.

Native freestanding output remains unavailable until the project has a real
startup path, linker profile, and runtime for that environment. The
Hilbert-written self host is also future work; the Modula-2 bootstrap remains
the compiler used for this release.

First party C bindings describe external libraries but do not distribute those
libraries. Applications must provide compatible native dependencies.
