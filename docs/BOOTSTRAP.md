# bootstrap notes

hilbert starts from gnu modula-2 in pim mode. implementation modules are compiled with `gm2 -c`, then the program module is linked with the object files. do not pass every `.mod` file to one link command, gnu modula-2 will quite reasonably give more than one of them application scaffolding and you end up with duplicate mains.

```sh
./bootstrap/bootstrap.sh
```

that leaves `build/hilbert0`.

if/when the self-hosted compiler is far enough along, the useful sanity loop is still the old boring one:

```text
gm2 -> hilbert0
hilbert0 -> hilbert1
hilbert1 -> hilbert2
```

`hilbert1` and `hilbert2` should agree. stage 0 stays under `compiler/` either way.
