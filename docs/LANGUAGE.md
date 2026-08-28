# the hilbert language

Hilbert belongs to the ALGOL, Pascal and Modula branch of the family tree. The
surface owes the most to Modula-2, with ideas from Modula-3, Oberon and
Component Pascal. It is an independent language, not a source-compatible
Modula dialect and not an official successor to any of them.

Keywords are normally written in uppercase. Assignment is `:=`, equality is
`=`, inequality is `#`, and a module ends with `END Name.`. The complete grammar
is in `GRAMMAR.ebnf`.

## source text

Identifiers begin with an ASCII letter or underscore and continue with ASCII
letters, decimal digits or underscores. Identifiers and keywords are case
sensitive. Keywords use their uppercase spellings.

`//` starts a line comment. `(* ... *)` comments nest. Integer literals may be
decimal or use `0x`, `0b` and `0o`; underscores between digits are ignored.
Real literals have a decimal point and may have an `e` or `E` exponent.

Strings use double quotes. Character literals use single quotes and contain
one Unicode scalar value. `\n`, `\r`, `\t`, `\e`, quote, backslash and
four-digit `\u` escapes are recognized. `CHAR` holds a Unicode scalar, while
`BYTE` is an eight-bit unsigned value.

## modules and names

A normal module declares its public names with `EXPORT`:

```hilbert
MODULE NetServer;
IMPORT IO, Net;
EXPORT Server, Listen;

...
END NetServer.
```

An ordinary import introduces a module name and qualified selection is the
default:

```hilbert
IMPORT Math;
X := Math.Sin(A);
```

An alias uses the assignment spelling already present in the language:

```hilbert
IMPORT FS := FileSystem;
FS.Remove("old.tmp");
```

Selective imports follow Modula-2 and introduce only the named exported
members:

```hilbert
FROM Math IMPORT Sin, Cos;
X := Sin(A) + Cos(A);
```

There are no wildcard imports. Two imports may not introduce the same local
name, and an import may not collide with another declaration in its scope.

The driver rejects import cycles. Imported modules initialize before the
importing module, in dependency order. Each module initializer has a
thread-safe three-state guard, so concurrent attempts either perform the
initialization once or wait for it to finish.

### divisions

A `DIVISION` is a named implementation partition inside one module. It is not
importable, linked, initialized or named at runtime. The containing module
remains the compilation unit.

```hilbert
MODULE Console;

EXPORT Write;

DIVISION hosted WHEN HOSTED;
EXPORT Write;
FROM LibC IMPORT puts;

PROCEDURE Write(S: CSTRING);
BEGIN
    puts(S)
END Write;

END hosted;

END Console.
```

Declarations are private to their division unless named by its `EXPORT` list.
That list exposes a name only to the containing module. The module's own
`EXPORT` list still decides what importers can see. Active divisions and the
module share one object-file symbol namespace, so two active declarations may
not use the same implementation name.

`WHEN` accepts only compiler-known, side-effect-free conditions: `TARGET` and
`ARCH` queries, `HOSTED`, `FREESTANDING`, `DEBUG`, `RELEASE`, `SIZE`, boolean
literals, and `AND`, `OR`, `NOT` composition. The current target names include
`linux`; current architecture names are `x86_64` and `aarch64`. Inactive
divisions are still lexed and parsed, so broken target code does not quietly
rot, but they do not contribute imports, symbols, runtime needs or generated
code.

Divisions contain declarations only. There is one module initialization
sequence and one module initialization guard. Large modules and alternate
platform implementations are the useful cases. Tiny modules generally do not
need another heading.

In short, a module describes program architecture and a division describes
implementation architecture.

### definition modules

Definition modules are optional. A file named `Stack.def.hil` pairs with
`Stack.hil` in the same directory:

```hilbert
DEFINITION MODULE Stack;

TYPE Stack;
PROCEDURE Push(VAR S: Stack; X: INTEGER);
PROCEDURE Pop(VAR S: Stack): INTEGER;

END Stack.
```

Everything declared by the definition module is public. `TYPE Stack;` is an
opaque type. Importers know its identity but not its fields or representation.
The implementation supplies the representation and must match every public
constant, type and procedure signature. A module without a definition file
continues to use explicit `EXPORT` normally.

## declarations and scope

`CONST`, `TYPE`, `SUBTYPE`, `VAR`, procedures and tasks are declared before a
module or procedure body. Blocks introduce lexical scopes. A name is visible
after its declaration and may not be declared twice in one scope.

A `CONST` initializer is a side-effect-free constant expression. Literals,
earlier constants, enum members, finite-set literals, arithmetic on constants,
explicit constant conversions, `SIZEOF` and `ALIGNOF` are allowed. Procedure
calls, allocation, mutable variables and address-taking are not constant
expressions.

Storage declared with `VAR` is zero initialized before an explicit initializer
runs. Initializers run in declaration order.

## scalar types

The fixed-width integer types are `INTEGER8`, `INTEGER16`, `INTEGER32`,
`INTEGER64`, `CARDINAL8`, `CARDINAL16`, `CARDINAL32` and `CARDINAL64`.
`INTEGER`, `CARDINAL` and `SIZE` have the native target width. `BYTE` is an
eight-bit unsigned data value. Other scalar types include `BOOLEAN`, `CHAR`,
`ADDRESS`, `REAL32`, `REAL64`, `STRING` and `CSTRING`.

An alias keeps the identity of its target. `DISTINCT` creates a new nominal
scalar type:

```hilbert
TYPE
    Distance = REAL64;
    UserId = DISTINCT CARDINAL64;
```

Crossing a distinct-type boundary requires an explicit conversion.

Enums are ordinal nominal types:

```hilbert
TYPE State = (Idle, Running, Done);
```

Enum members are constants of the enum type. They are valid in `CASE`, ranges
and finite sets, but an enum is not silently treated as a general integer.

## arithmetic and conversions

Integer addition, subtraction, multiplication and unary negation use two's
complement modulo arithmetic at the width of the result type. This applies to
both signed and unsigned values. There is no optimizer-only signed-overflow
rule.

`DIV` truncates toward zero. `MOD` satisfies
`A = (A DIV B) * B + (A MOD B)`, and a nonzero remainder has the sign of `A`.
Division by zero traps. Dividing the minimum signed value by `-1` also traps
because the result is not representable.

`SHL` shifts left, and `SHR` is arithmetic for signed values and logical for
unsigned values. A negative shift count or a count greater than or equal to the
left operand's bit width traps.

Fitting integer constants adopt the type of the other integer operand. This
makes `Count32 + 1` an `INTEGER32` expression without making dynamic narrowing
implicit. Dynamic integer conversions are implicit only when every value of
the source type fits the destination. A constant may enter a narrower type when
its value fits. Other narrowing is explicit.

Explicit integer narrowing keeps the low destination-width bits. Widening
preserves signedness and value. Integer-to-floating conversion uses the target
machine's IEEE conversion. Floating-to-integer conversion truncates toward zero
and traps for NaN, infinity or a value outside the destination domain.

`/` is floating-point division. Hilbert currently uses the target's IEEE
`REAL32` and `REAL64` operations and does not enable floating-point exception
traps by default.

## ranges

A range has an ordinal base and constant inclusive bounds:

```hilbert
TYPE Port = CARDINAL RANGE 0 .. 65535;
```

The bounds must fit the base type. A constant outside the range is rejected at
compile time. A dynamic value is checked before any narrowing conversion when
it enters range storage, a parameter, a return value or an initializer. Failure
traps. Range values retain the size and machine class of their base type.

## arrays and slices

An array owns a fixed number of elements:

```hilbert
TYPE Line = ARRAY 80 OF CHAR;
```

Its count is a positive integer constant. A `SLICE OF T` is a borrowed pair of
data pointer and length. Passing a compatible fixed array to a slice parameter
constructs the view automatically. Array and slice indexes are bounds checked.
Raw pointer indexing has no hidden length and therefore has no bounds check.

## records

Fields are laid out in declaration order with natural alignment. A record
extension places its base record first and requires a record base:

```hilbert
TYPE
    Entity = RECORD X, Y: REAL64; END;
    Player = RECORD(Entity) Health: INTEGER32; END;
```

A record may refer to itself through `REF` or `POINTER TO`. Direct by-value
recursion is rejected because it has no finite layout.

Receiver procedures attach operations without adding a class hierarchy:

```hilbert
PROCEDURE (VAR P: Player) Damage(N: INTEGER32);
BEGIN
    P.Health := P.Health - N
END Damage;
```

### variant records

A tagged variant record keeps common fields followed by overlapping arm
storage:

```hilbert
TYPE
    ValueKind = (IntValue, RealValue, TextValue);
    Value = RECORD
        CASE Kind: ValueKind OF
            IntValue: I: INTEGER;
        | RealValue: R: REAL64;
        | TextValue: S: CSTRING;
        END
    END;
```

The tag is a normal common field. Reading or writing an arm field while its tag
does not select that arm traps. Changing the tag does not run a constructor or
clear the overlapping payload. Ordinary zero initialization sets a zero-valued
enum tag, which selects its first member. Layout uses the largest arm and is
deterministic.

## finite sets

`SET OF T` is a finite bitset over `BOOLEAN`, an enum, or a range whose ordinal
domain fits bits 0 through 63:

```hilbert
TYPE
    Permission = (Read, Write, Execute);
    Permissions = SET OF Permission;

P := {Read, Write};
IF Execute IN P THEN ... END;
```

`+` is union, `*` is intersection and `-` is difference. Equality and
inequality compare the bitsets. Constructing or testing an element outside the
set's domain traps. This feature is not a dynamic hash set; larger collections
belong in library modules.

## generic types and procedures

Generic records and other data types use square brackets:

```hilbert
TYPE
    Box[T] = RECORD Value: T; END;
    Node[T] = RECORD Value: T; Next: REF Node[T]; END;
```

Instantiations are canonical. Repeated uses of `Box[INTEGER]` have one nominal
identity. Nested and recursive instantiations use the same rule.

Generic procedures use the same small notation:

```hilbert
PROCEDURE Max[T](A, B: T): T;
BEGIN
    IF A > B THEN RETURN A ELSE RETURN B END
END Max;
```

Calls currently state their type arguments explicitly, such as
`Max[INTEGER](A, B)`. Operations are checked when the procedure is instantiated.
There is no trait, typeclass or general constraint language. Invalid operations
produce an error in the instantiation rather than creating a second language
for constraints.

## procedure values

A procedure type describes its full parameter, `VAR`, result and variadic ABI
shape:

```hilbert
TYPE Comparator = PROCEDURE(A, B: INTEGER): INTEGER;
VAR Compare: Comparator;
```

Named non-capturing Hilbert procedures may be stored in variables, passed as
parameters, placed in records and called indirectly when their signatures
match. Hilbert has no captured closure model in 1.0.

An ABI-compatible procedure value may be passed to a C function-pointer
parameter. This is the callback model used by first-party native APIs. The
compiler emits a real indirect call and uses the same ABI classification and
coercion path as direct calls.

## procedure control flow

A value-returning procedure must return on every reachable ordinary path.
Falling off the end is a compile-time error, and the backend still emits a
defensive trap for an impossible surviving fallthrough.

`VAR` parameters require mutable addressable storage. Constants and temporary
values do not qualify. The borrow checker rejects obvious aliases between
exclusive `VAR` arguments and rejects safe escapes of local stack addresses.

`PRE` and `ASSERT` require `BOOLEAN` and trap when false. `POST` remains
reserved because result and old-value semantics have not been added.

`DEFER Statement` records a cleanup for the current lexical block. Cleanups run
in reverse declaration order on normal block exit, `RETURN` and `EXIT`.

## evaluation order

Evaluation is left to right. This includes binary operands, procedure
arguments, initializers, fixed and variadic C arguments, and nested compound
expressions. An assignment evaluates the destination designator, including its
indexes and dereferences, before evaluating the right side.

`AND` and `OR` are guaranteed left-to-right short-circuit operators when their
operands are boolean. `A AND B` does not evaluate `B` when `A` is false, and
`A OR B` does not evaluate `B` when `A` is true. The same spellings perform
bitwise operations on integer operands.

## statements

Hilbert has `IF`, `CASE`, `WHILE`, `REPEAT`, `LOOP`, counted `FOR`, `FOR IN`,
`EXIT` and `RETURN`. `CASE` labels are ordinal constants and duplicate values
are rejected.

A counted loop uses an already declared mutable integer control variable:

```hilbert
VAR I: INTEGER32;
FOR I := 0 TO 9 BY 1 DO ... END;
```

The start, inclusive end and optional step are evaluated once. The step may be
negative and may not be zero. The control variable is incremented after each
executed body, so after normal completion it contains the first value beyond
the inclusive bound. An empty loop leaves it at the start value.

`FOR Item IN Values` introduces a block-local item with the array or slice
element type.

## tasks, threads and atomics

A `TASK` is a zero-argument task body. `START Worker` creates a native thread
and returns an opaque handle; `AWAIT` joins it. Task threads register with the
collector before Hilbert code runs. Reusing an invalid or already joined handle
fails deterministically. `Tasks.TryJoin` provides a status-returning form.

`PARALLEL BEGIN A() AND B() END` starts its zero-argument branches and joins all
of them. There is no concurrency syntax beyond these small forms.

`ATOMIC[T]` accepts one, two, four or eight byte integer types. `Load`, `Store`,
`FetchAdd` and `CompareExchange` are sequentially consistent. There are no
memory-order parameters that the backend ignores.

`NativeThread` exposes typed non-capturing thread entry procedures, joins,
detach, native mutexes and condition variables. Threads made through this
module also register with the collector.

Hilbert does not make ordinary variables race-free. Conflicting unsynchronized
access from multiple threads is a program error.

## managed and raw memory

`REF T` is a managed, non-moving reference allocated by `NEW(T)`. The collector
traces registered thread stacks, writable globals and managed payloads. Managed
objects may contain cycles.

`POINTER TO T` is a raw typed pointer. `ADDRESS` is an untyped machine address.
Raw dereference and indexing require `UNSAFE BEGIN ... END`. Raw memory is not
traced and must be managed explicitly through `Memory`, `ManualMemory`, arenas
or an operating-system interface.

Bad raw access may cause an ordinary hardware or operating-system fault. The
language does not wrap such faults in a pretend exception. Converting a raw
address to a managed reference is explicit and unsafe.

## c ffi

```hilbert
FOREIGN "C" LIBRARY "m";
FOREIGN "C" PROCEDURE puts(S: CSTRING): INTEGER32;
```

`EXTERNAL NAME` changes the linked symbol. A declaration marked `VARARGS`
checks its fixed arguments and applies C default promotions to later arguments:
`REAL32` becomes `REAL64`, boolean and sub-32-bit integer values become
`INTEGER32`.

The supported native ABI is SysV AMD64 on x86-64 GNU/Linux. Fixed-width Hilbert
integers map to C integers of the same width. C `_Bool` maps to `BOOLEAN`.
`CSTRING` maps to a NUL-terminated `char *`. Compatible records up to 16 bytes
are classified recursively into integer and SSE eightbytes, including nested
arrays. Larger by-value aggregates use a memory ABI shape that the current
backend rejects; use `VAR`, `REF` or a pointer instead.

An incorrect foreign declaration is unsafe even when the call syntax type
checks. Hilbert cannot verify a third-party header at link time.

## hosted and lower-level programs

The stable complete target is hosted x86-64 GNU/Linux. Runtime sections are
linked only when the module graph uses managed allocation, tasks or a
`hilbert_rt_` entry point, and the linker discards unused sections. Programs
using only raw memory do not automatically pull in the collector.

`--runtime freestanding` selects and checks freestanding divisions, including
under the AArch64 front end. A native build with that runtime is rejected
because 1.0 does not yet have a freestanding startup ABI or bare-metal linker
profile. `emit-asm` and `emit-obj` remain available for hosted custom-link work.
No libc, no OS and interrupt startup remain target work, not aliases for
ordinary Linux compilation.

## reserved syntax and undefined behavior

The lexer recognizes some words from experiments that are not public features.
Generic constraints, `POST`, language exceptions, `PROTECTED` and private
record machinery, `WITH`, `ABSTRACT`, `PARALLEL FOR` and expression `IS` are
reserved and produce a front-end diagnostic.

Undefined behavior is kept at explicit unsafe boundaries: invalid raw pointer
use, a mismatched foreign declaration, violating a native API's lifetime rules,
and data races on non-atomic storage. Checked indexes, ranges, variants, shifts,
division and ordinary integer overflow have defined behavior above.
