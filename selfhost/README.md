# self host work

this directory is where the hilbert-written compiler work goes. it is not the compiler used to build the current tree yet.

when it gets far enough, the useful comparison is:

```text
gm2 -> hilbert0
hilbert0 -> hilbert1
hilbert1 -> hilbert2
```

`hilbert1` and `hilbert2` should agree, otherwise something in the compiler is depending on its parent in a way it should not. the modula-2 stage stays under `compiler/` either way.
