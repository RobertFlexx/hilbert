# POSIX and operating-system modules

Hilbert applications should not need private C source merely to walk a
directory, inspect a file, buffer output, or launch a child process. The
first-party modules provide typed directory iteration, portable file metadata,
buffered I/O, path construction, glob matching, text files, numeric conversion,
and subprocess execution while keeping resource ownership and application policy
in Hilbert.

The 1.0 native platform remains x86-64 GNU/Linux. Most public operations here
map directly to POSIX; GNU-only values such as `Glob.CaseFold` are identified
as extensions. Platform-dependent C layouts are not part of the Hilbert API.

## Directory iteration

`Directory.Next` returns a typed, borrowed entry:

```text
VAR Dir: Directory.Directory;
    Item: Directory.Entry;
    Status: INTEGER32;

Dir := Directory.Open(".");
DEFER Directory.Close(Dir);
Status := Directory.Next(Dir, Item);
WHILE Status = Directory.EntryAvailable DO
    IO.WriteLn(Item.Name);
    Status := Directory.Next(Dir, Item)
END;
ASSERT Status # Directory.ReadError
```

`Item.Name` remains valid until the next read on that same directory handle.
Copy it when it must outlive the iteration step. `Next` omits `.` and `..`;
`NextRaw` exposes the POSIX stream exactly. Entry kinds come from `dirent` and
may be `Unknown` on filesystems that do not provide type metadata.

## File metadata

`FileInfo.Stat` follows the final symbolic link and `FileInfo.LinkStat` does
not. The `At` forms operate relative to an open directory and avoid rebuilding
or reparsing the parent path.

```text
VAR Info: FileInfo.Info;
IF FileInfo.LinkStat("cache/item", Info) THEN
    IF FileInfo.IsLink(Info) THEN ... END;
    IO.WriteInt(INTEGER(Info.Size))
END
```

The stable `Info` record contains device/inode identity, size, modification
time, mode, link count, user/group IDs, kind, and convenience flags for empty
regular files and executable files. Directory emptiness is queried explicitly
with `DirectoryEmpty` or `DirectoryEmptyAt` because it requires opening the
directory.

## Paths and strings

`Path.Builder` is reusable unmanaged storage. `Assign`, `Append`, and `Join`
grow it as needed and keep a trailing NUL for C and POSIX calls.

```text
VAR Child: Path.Builder;
Path.Init(Child, 256);
DEFER Path.Dispose(Child);
ASSERT Path.Join(Child, Parent, Item.Name);
Visit(Path.Value(Child))
```

`Path.BaseName` and `Path.Extension` return borrowed views into their input.
`CStrings.At` performs explicit C-string pointer advancement, while the
case-insensitive comparison/search helpers use predictable ASCII folding.

## Files and buffered output

`Files` exposes standard descriptors, general open flags, full read/write
loops that retry `EINTR`, seeking, truncation, syncing, and descriptor access.
`BufferedIO.Writer` batches small writes and reports sticky failure:

```text
BufferedIO.Init(Output, Files.Handle(Files.StandardOutput), 65536);
DEFER BufferedIO.Dispose(Output);
ASSERT BufferedIO.WriteLine(Output, "hello");
ASSERT BufferedIO.Flush(Output)
```

Use `--print0`-style output with `WriteByte(Output, BYTE(0))`; the writer is
binary-safe.

`TextFile.Reader` wraps POSIX `getline`. Returned lines are borrowed until the
next call and have trailing CR/LF bytes removed.

## Processes and terminals

`Process.Spawn`/`Wait` and `Process.Run` use `posix_spawnp` and an argument
slice, without invoking a shell. `SpawnRaw`/`RunRaw` accept a pointer and count
for dynamically sized argument vectors. `Process.Execute` remains available
for the explicitly shell-interpreted `system(3)` behavior.

`Terminal.SupportsColor` combines `isatty`, `NO_COLOR`, and `TERM=dumb`.
`Terminal.UseColor` applies the standard auto/always/never policy.

## Boundary and portability

`struct dirent` and `struct stat` vary between libc implementations. A small
toolchain-owned section of `runtime/hilbert_rt.c` translates those layouts to
fixed-width Hilbert values. It also supplies `posix_spawnp` argument
termination. This is analogous to a platform module in Modula or Oberon:
application logic stays in Hilbert, and each operating-system ABI is
implemented once rather than copied into every project.

Foreign declarations beginning with `hilbert_rt_` make the compiler link the
runtime automatically. Unused runtime sections are discarded by the native
linker.
