# stage 0

stage 0 is gnu modula-2. `bootstrap.sh` builds the normal compiler and copies it to `build/hilbert0`, mostly so fixed-point/self-host experiments have a name that does not get confused with the compiler you just built.

```sh
./bootstrap/bootstrap.sh
```

the modula-2 compiler is staying in the tree even once the hilbert-written one gets farther along. having a small independent way back in is useful and deleting it just to say "self hosted" would be silly.
