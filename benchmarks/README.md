# benchmarks

`tools/benchmark.py` measures the compiler, native output and a few runtime
paths without claiming that one development machine represents the world.

```sh
make -j4
python3 tools/benchmark.py --rounds 7
python3 tools/benchmark.py --rounds 7 --json > before.json
```

Run the same command before and after a compiler change, on an otherwise idle
machine, and keep both raw outputs with the change being measured. The script
reports compiler startup, cold small and multi-module builds, O0/O3 assembly
emission, a cached-object forced relink, a true no-op and partial `hilmake`
build, including a real dependency content edit, native workload time, a native thread/condition round trip, GC stress
time and executable sizes. The forced-relink row is the direct baseline for
the link-stamp optimization on the same run and machine.

Compile and link timings are combined because that is the latency a user sees.
The assembly measurements stop before assembly and linking, but still include
the front end, lowering, optimization and code generation. They are not passed
off as isolated optimizer timings.
