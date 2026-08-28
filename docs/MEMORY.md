# memory

managed refs and raw memory are separate because mixing them implicitly is how ownership gets impossible to reason about.

`REF T` comes from the hilbert heap. `NEW(T)` gives you a zeroed object and the collector is non-moving, so a managed object's address stays put while foreign code is using it.

small/medium allocations use size classes from 16 bytes through 16 kib. large ones use page mappings. collection is conservative mark/sweep and the trigger moves with the live set, empty slabs can go back to the os but one spare per class is kept so a burst of allocations does not turn into mmap ping-pong.

`GC.AllocAtomic` is for payloads with no managed references. `GC.TryAlloc` and `GC.TryAllocAtomic` can fail and return that failure instead of killing the program. normal `NEW` retries around collection and reports a runtime failure if the heap still cannot grow.

## roots and threads

hilbert task stacks/registers, writable globals and managed payloads are scanned conservatively. threads made by the task runtime or `NativeThread.Create` register themselves before user code starts and unregister on return.

if a thread came from c and can hold hilbert refs, register it yourself:

```text
GC.RegisterThread();
...
GC.UnregisterThread();
```

if c is keeping the only copy of a managed pointer somewhere the collector cannot see, pin that location with `GC.AddRoot`/`GC.RemoveRoot`.

on linux x86-64 the runtime uses `SIGUSR2` while stopping registered threads. a foreign thread that registered with the gc cannot permanently block that signal.

## raw allocation

`ADDRESS` and `POINTER TO T` are not traced. `Memory` and `ManualMemory` provide alloc/realloc/copy/move/fill/compare/free calls and you own the lifetime yourself. `Memory.AllocAligned` uses power-of-two alignment suitable for native objects. `Arena.AllocateAligned` accounts for both padding and payload before advancing the bump pointer, so allocations cannot overlap; failed capacity preconditions stop rather than returning a partial block.

the runtime is linked only if something in the module graph actually needs it, plain manual-memory programs do not need to carry the collector around.

## other resources

the gc is not a file/socket/database finalizer. close those normally, `DEFER` is handy for it.
