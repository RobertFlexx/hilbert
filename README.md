hilbert

hilbert is a small systems programming language in the wirth tradition

its closest relatives are modula two modula three oberon and component pascal
it keeps their preference for modules records procedures static types and a
compact grammar while making its own choices about memory generics tasks and
native code

technically spiritually modula four is the running joke and not a standards
claim

status

the current release implements the language described in this source tree from
parsing and type checking through native machine code

the supported target is sixty four bit x eighty six linux using the system v
amd calling convention

the compiler is bootstrapped with gnu modula two and emits native assembly
the runtime is written in c and the standard library is written in hilbert

language

hilbert has explicit module exports optional definition modules selective
imports implementation divisions records extension enums ranges finite sets
tagged variants arrays slices generic types generic procedures and typed
procedure values

managed references use a tracing nonmoving collector
raw pointers and addresses remain separate and require unsafe code
exclusive variable parameters are checked for obvious aliases and escaped
stack addresses

the language also provides deferred cleanup small tasks parallel branches
integer atomics and a direct c interface with callbacks

build

you need gnu modula two a c compiler make an assembler and a linker

run make to build the compiler and project builder

run make test for the compiler runtime standard library examples command line
tools and project builder

the makefile also provides stricter release archive sanitizer and installation
checks for release maintainers

using hilbert

the build produces the hilbert compiler and the hilmake project builder

the examples directory starts with a small hello program and continues with
focused programs for language features the standard library posix support and
the supplied c bindings

hilmake reads a small declarative project file and uses the compiler module
graph for checking building running installation and incremental rebuilds

library

the standard library covers text files paths directories processes terminals
networking time random values buffers collections arenas manual memory managed
memory tasks threads atomics logging testing and common data structures

the bindings directory contains straightforward interfaces for several common
c libraries without bundling those libraries

documentation

the docs directory contains the language guide grammar compiler notes memory
and safety model project builder reference posix guide diagnostics bootstrap
notes and release checklist

the examples directory and each major subsystem also include short local notes
where they are useful

contributing

small focused changes with tests are welcome

compiler changes should pass the full test suite and changes to public syntax
or native behavior should include a focused regression

license

hilbert is released under the mit license
