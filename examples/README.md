# hilbert examples

the examples are intentionally small enough to read in one sitting. there are many of them so the combined set shows the language and shipped libraries doing real work without turning one showcase program into a framework.

from the repository root:

```sh
./build/hilbert build examples/small/slices.hil -o build/slices
./build/slices
```

an installed compiler uses the same command with `hilbert` instead of `./build/hilbert`. `make example-test` checks every example and native-builds/runs everything that depends only on the shipped standard library.

## language and standard library

| example | point of the example |
| --- | --- |
| `hello.hil` | modules, imports, a procedure, `PRE`, output |
| `types.hil` | distinct/range types and record extension |
| `parallel.hil` | parallel branches and an atomic counter |
| `small/control_flow.hil` | `FOR`, `WHILE`, `REPEAT`, `CASE`, assertions |
| `small/records_and_methods.hil` | records, extension and receiver procedures |
| `small/generic_records.hil` | generic records, `Option` and `Result` |
| `small/generic_algorithms.hil` | imported generic procedures and record swapping |
| `small/finite_sets.hil` | finite-set literals, membership and bitset operations |
| `small/variant_records.hil` | tagged variant storage and arm selection |
| `small/procedure_values.hil` | typed procedure values and indirect calls |
| `small/division_selection.hil` | private implementation divisions and target/runtime selection |
| `small/slices.hil` | fixed-array to slice conversion and `FOR IN` |
| `small/defer_cleanup.hil` | lexical `DEFER`, including early return |
| `small/enums_and_case.hil` | enum values and exhaustive-looking `CASE` |
| `small/ranges_and_distinct.hil` | checked ranges and nominal scalar types |
| `small/tasks_and_atomics.hil` | `TASK`, `START`, `AWAIT`, `PARALLEL`, atomics |
| `small/strings_and_utf8.hil` | string queries, UTF-8 validation and ASCII |
| `small/random_numbers.hil` | deterministic generator and unbiased ranges |
| `small/math_table.hil` | real conversions and the math module |
| `small/bits_and_endian.hil` | bit operations, alignment and byte swapping |
| `small/arena_allocator.hil` | scoped arena allocation and cleanup |
| `small/growing_buffer.hil` | a manually managed growable byte buffer |
| `small/managed_list.hil` | generic linked nodes allocated with `NEW` |
| `small/foreign_puts.hil` | a direct C ABI declaration |
| `small/command_line.hil` | program name and command-line arguments |
| `small/preconditions.hil` | procedure preconditions |
| `small/posix_directory.hil` | typed directory iteration and borrowed entries |
| `small/file_metadata.hil` | stable `stat` metadata through `FileInfo` |
| `small/buffered_output.hil` | binary-safe buffered descriptor output |
| `small/subprocess_run.hil` | argument-vector subprocess execution without a shell wrapper |
| `small/text_file_lines.hil` | line-oriented text input and scoped cleanup |

## first-party binding examples

the files under `examples/bindings/` cover every first-party binding. `hilbert check` needs no external library because it stops after the front end. `hilbert build` invokes the native linker, so install the development package for the library you choose.

```sh
./build/hilbert check examples/bindings/sqlite_memory.hil
./build/hilbert build examples/bindings/sqlite_memory.hil -o build/sqlite-memory
./build/sqlite-memory
```

| example | native library | what it does |
| --- | --- | --- |
| `bzip2_version.hil` | `bz2` | prints the linked bzip2 version |
| `curl_version.hil` | `curl` | reads libcurl's version string |
| `dynamic_loader.hil` | `dl` | opens libm and looks up `cos` |
| `expat_parse.hil` | `expat` | parses a small XML document from memory |
| `lz4_version.hil` | `lz4` | reports version and compression bound |
| `libarchive_version.hil` | `archive` | reports the libarchive version |
| `libpng_version.hil` | `png` | reports libpng's numeric version |
| `libpq_version.hil` | `pq` | reports client version and thread safety |
| `libxml2_memory.hil` | `xml2` | parses and frees an in-memory XML document |
| `openssl_version.hil` | `ssl`, `crypto` | prints OpenSSL text and numeric versions |
| `pcre2_match.hil` | `pcre2-8` | compiles and matches a regular expression |
| `raylib_callbacks.hil` | `raylib` | installs typed file and audio callbacks |
| `raylib_window.hil` | `raylib` | interactive drawing and close/input loop |
| `sdl3_window.hil` | `SDL3` | creates a resizable window briefly |
| `sqlite_memory.hil` | `sqlite3` | prepares and evaluates `SELECT 6 * 7` |
| `zlib_version.hil` | `z` | reports version and compression bound |
| `zstd_version.hil` | `zstd` | reports version and compression-level range |

the graphical examples deliberately do not hide their event loops behind a wrapper. the database, parser and regular-expression examples show the `UNSAFE` blocks needed when C writes through pointers. that boundary is part of the lesson: the raw bindings remain recognizable, while higher-level ownership wrappers can be written in Hilbert on top.
