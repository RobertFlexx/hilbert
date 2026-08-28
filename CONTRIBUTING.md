# contributing

Hilbert has a small bootstrap and a deliberately compact language surface. The
best changes are focused, tested, and easy to explain from source behavior down
to generated code.

## before sending a change

Build the compiler and run the normal release gate:

```sh
make -j4
make release-check
```

Release maintainers should also run the strict sanitizer gate on a host where
LeakSanitizer is available:

```sh
make release-check-strict
```

For a binding only change, these checks provide a useful quick pass before the
full suite:

```sh
python3 tools/binding_check.py
python3 tools/repo_check.py
```

## compiler work

The stage zero compiler is GNU Modula-2 in PIM mode. Keep the bootstrap within
that dialect and compile implementation modules separately, as the Makefile
does.

Add a focused regression for changes to parsing, typing, borrowing, lowering,
optimization, calling conventions, or diagnostics. A construct is not complete
until every required compiler stage either implements it or rejects it with a
useful error.

Wrong native code is worse than a missing feature. Reject unsupported ABI or
runtime shapes instead of guessing.

## library and documentation work

Most library behavior belongs in Hilbert source unless it needs direct runtime
or compiler support. Raw bindings should remain close to their C interfaces;
safer ownership wrappers can be built above them.

Comments should explain decisions, invariants, and surprising constraints.
Avoid narrating code that is already clear. Documentation should describe the
current implementation and call unfinished work unfinished.
