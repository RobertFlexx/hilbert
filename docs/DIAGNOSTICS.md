# errors

compiler errors have numeric ids like `H1102` or `H1133`. wording can change without making tests/editors scrape english text forever.

roughly:

- `H1000` parser/lexer stuff
- `H1100` names, types, borrowing and unsafe use
- `H1200` lowering/codegen shapes the backend cannot represent
- `H2000` files, modules, linker/toolchain
- `H2100` command line
- `H2200` hilmake/project files
- `H3000` warnings
- `H9000` compiler/internal failures

an error can carry the source line, caret, note and a `help:` line. by default the compiler gives up after 50 because the 51st error after a missing token is usually not wisdom.

`hilbert --help` has the color, warning, quiet and error-limit switches.
