# c bindings

these are mostly thin declarations on purpose. they install beside the stdlib so `IMPORT Raylib;`, `IMPORT SQLite3;`, `IMPORT Curl;` and so on work from a normal hilbert install, no copying a binding into every project.

higher-level ownership wrappers and nicer error types belong in hilbert modules on top of these files, the raw binding should stay boring and recognizable if you have the c header open next to it.

`examples/bindings/` has one small program for every module here. see `examples/README.md` for what each program does and which native development library is needed to link it.

`Raylib.hil` follows raylib 6.0. file and audio callbacks use Hilbert procedure types. the trace-log callback stays out because C `va_list` is not a portable Hilbert type and guessing there would be worse than omitting one function.

`SDL3.hil` is for sdl 3.4.x. `SQLite3.hil` came from sqlite 3.46.1 with session/preupdate declarations enabled. `Curl.hil`, `LibPQ.hil` and `LibXML2.hil` are bigger generated surfaces and unknown layouts stay opaque instead of being guessed.

the zlib, zstd, lz4, bzip2, pcre2, expat, libarchive, libpng, openssl and `dl` files are smaller hand-kept subsets.

if you touch one of these, at least run:

```sh
python3 tools/binding_check.py
python3 tools/repo_check.py
```

for generated files, use the header version you actually meant to target and read the diff. regenerating a release binding from whatever happens to be in `/usr/include` is an easy way to accidentally change its abi without noticing.

raylib's normal desktop build polls input from `EndDrawing`. A raylib 6.0 build
made with `SUPPORT_CUSTOM_FRAME_CONTROL` does not; that application's frame loop
must call `SwapScreenBuffer`, `PollInputEvents` and perform its own timing. The
binding exposes those raw procedures and does not guess how the native library
was compiled. Do not add an extra poll to a normal loop that relies directly on
raylib's one-frame `IsKeyPressed` state, since a second poll can advance it.
