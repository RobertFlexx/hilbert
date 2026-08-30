# Hilbert is built as a normal Modula-2 program.  Keep the build boring. (for maintainers)
GM2 ?= gm2
PREFIX ?= /usr/local
DESTDIR ?=
BUILD := build
DIST := dist
DIST_NAME := hilbert-$(shell cat VERSION)
SOURCE_DATE_EPOCH ?= 0
M2FLAGS ?= -fpim -O2 -Wall
M2INCLUDES := -Icompiler -Ibuildsys
M2LINKFLAGS ?= -fscaffold-static -fno-scaffold-dynamic

COMPILER_MODULES := \
 compiler/HStrings.mod \
 compiler/ErrorCodes.mod \
 compiler/Diagnostics.mod \
 compiler/Target.mod \
 compiler/Options.mod \
 compiler/Source.mod \
 compiler/Tokens.mod \
 compiler/Lexer.mod \
 compiler/AST.mod \
 compiler/Parser.mod \
 compiler/Divisions.mod \
 compiler/Symbols.mod \
 compiler/Types.mod \
 compiler/Layout.mod \
 compiler/Signatures.mod \
 compiler/Interfaces.mod \
 compiler/Methods.mod \
 compiler/Generics.mod \
 compiler/GenericProcedures.mod \
 compiler/Semantics.mod \
 compiler/BorrowCheck.mod \
 compiler/HIR.mod \
 compiler/ABI.mod \
 compiler/Lower.mod \
 compiler/Optimize.mod \
 compiler/Verify.mod \
 compiler/Asm.mod \
 compiler/X64.mod \
 compiler/Driver.mod

HILMAKE_MODULES := \
 compiler/HStrings.mod \
 compiler/ErrorCodes.mod \
 compiler/Diagnostics.mod \
 buildsys/Project.mod

COMPILER_OBJECTS := $(patsubst %.mod,$(BUILD)/%.o,$(COMPILER_MODULES))
HILMAKE_OBJECTS := $(patsubst %.mod,$(BUILD)/%.o,$(HILMAKE_MODULES))
M2_DEFINITIONS := $(wildcard compiler/*.def buildsys/*.def)

.PHONY: all compiler hilmake check terminal-guard-test runtime-test runtime-analyze runtime-sanitize runtime-sanitize-strict compiler-test stdlib-native-test cache-test cli-test hilmake-test example-test benchmark test smoke install install-check uninstall clean dist dist-check version

all: compiler hilmake

compiler: $(BUILD)/hilbert
hilmake: $(BUILD)/hilmake

$(BUILD):
	mkdir -p $(BUILD)

# NOTE TO MAINTAINERS BELOW
# GNU Modula-2 is not C: every implementation module passed to a link
# invocation without -c is treated as a program unit and may contribute a
# scaffold/main. Do not "simplify" this into gm2 *.mod; that shit is how we
# ended up debugging duplicate mains in the first place.  Compile implementation modules separately, then let the
# one real program module own the application scaffold at final link time.
# gm2 does not emit dependency files for imported definition modules here.
# A .def edit is uncommon, and rebuilding these small bootstrap modules is a
# much better trade than linking objects compiled against two different enum
# or record layouts.
$(BUILD)/%.o: %.mod $(M2_DEFINITIONS)
	@mkdir -p $(dir $@)
	$(GM2) $(M2FLAGS) $(M2INCLUDES) -c $< -o $@

$(BUILD)/hilbert: compiler/hilbert.mod $(COMPILER_OBJECTS) | $(BUILD)
	$(GM2) $(M2FLAGS) $(M2INCLUDES) $(M2LINKFLAGS) compiler/hilbert.mod $(COMPILER_OBJECTS) -o $@

$(BUILD)/hilmake: buildsys/hilmake.mod $(HILMAKE_OBJECTS) | $(BUILD)
	$(GM2) $(M2FLAGS) $(M2INCLUDES) $(M2LINKFLAGS) buildsys/hilmake.mod $(HILMAKE_OBJECTS) -o $@

check:
	python3 tools/repo_check.py
	python3 tools/binding_check.py
	$(MAKE) terminal-guard-test
	$(MAKE) runtime-test

terminal-guard-test:
	tools/terminal_guard_tests.sh

runtime-test: $(BUILD)
	$(CC) -std=c11 -O2 -pthread -Wall -Wextra -Werror tests/runtime_gc.c runtime/hilbert_rt.c -o $(BUILD)/runtime-gc-test
	$(BUILD)/runtime-gc-test
	$(CC) -std=c11 -O2 -pthread -Wall -Wextra -Werror tests/runtime_gc_stress.c runtime/hilbert_rt.c -o $(BUILD)/runtime-gc-stress
	$(BUILD)/runtime-gc-stress

runtime-analyze:
	CC="$(CC)" tools/runtime_analyze.sh

runtime-sanitize: $(BUILD)
	CC="$(CC)" tools/runtime_sanitize.sh

runtime-sanitize-strict: $(BUILD)
	CC="$(CC)" REQUIRE_SANITIZERS=1 tools/runtime_sanitize.sh

compiler-test: all
	HILBERT=$(BUILD)/hilbert tools/compiler_tests.sh

stdlib-native-test: all
	HILBERT=$(BUILD)/hilbert tools/stdlib_native_tests.sh

cache-test: all
	HILBERT=$(BUILD)/hilbert tools/cache_tests.sh

cli-test: all
	HILBERT=$(BUILD)/hilbert HILMAKE=$(BUILD)/hilmake tools/cli_tests.sh

hilmake-test: all
	HILMAKE=$(BUILD)/hilmake tools/hilmake_tests.sh

example-test: all
	HILBERT=$(BUILD)/hilbert tools/example_tests.sh

benchmark: all
	python3 tools/benchmark.py

smoke: all
	$(BUILD)/hilbert check tests/smoke.hil
	$(BUILD)/hilbert build examples/hello.hil -o $(BUILD)/hello
	$(BUILD)/hello

test: check cli-test hilmake-test example-test smoke compiler-test cache-test stdlib-native-test

install: all
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/libexec/hilbert
	install -m755 $(BUILD)/hilbert $(DESTDIR)$(PREFIX)/libexec/hilbert/hilbert
	install -m755 $(BUILD)/hilmake $(DESTDIR)$(PREFIX)/libexec/hilbert/hilmake
	install -m755 tools/hilbert-launcher.sh $(DESTDIR)$(PREFIX)/bin/hilbert
	install -m755 tools/hilmake-launcher.sh $(DESTDIR)$(PREFIX)/bin/hilmake
	install -d $(DESTDIR)$(PREFIX)/share/hilbert/stdlib $(DESTDIR)$(PREFIX)/share/hilbert/bindings $(DESTDIR)$(PREFIX)/share/hilbert/docs $(DESTDIR)$(PREFIX)/share/hilbert/runtime $(DESTDIR)$(PREFIX)/share/hilbert/examples
	cp -a stdlib/. $(DESTDIR)$(PREFIX)/share/hilbert/stdlib/
	# First-party bindings are ordinary importable modules after installation.
	install -m644 bindings/*.hil $(DESTDIR)$(PREFIX)/share/hilbert/stdlib/
	# Keep the source catalog too; this is handy when checking a raw ABI binding.
	cp -a bindings/. $(DESTDIR)$(PREFIX)/share/hilbert/bindings/
	cp -a docs/. $(DESTDIR)$(PREFIX)/share/hilbert/docs/
	cp -a runtime/. $(DESTDIR)$(PREFIX)/share/hilbert/runtime/
	cp -a examples/. $(DESTDIR)$(PREFIX)/share/hilbert/examples/
	install -m644 README.md LICENSE CHANGELOG.md $(DESTDIR)$(PREFIX)/share/hilbert/

install-check: all
	rm -rf $(BUILD)/install-root
	$(MAKE) install DESTDIR="$(CURDIR)/$(BUILD)/install-root" PREFIX=/usr
	tools/install_tests.sh $(BUILD)/install-root

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/hilbert $(DESTDIR)$(PREFIX)/bin/hilmake
	rm -rf $(DESTDIR)$(PREFIX)/libexec/hilbert $(DESTDIR)$(PREFIX)/share/hilbert

clean:
	rm -rf $(BUILD) .hilbert-cache *.o *.s compiler/*.o compiler/*.s buildsys/*.o buildsys/*.s tools/__pycache__ tests/__pycache__ core core.*

dist: release-check
	mkdir -p $(DIST)
	tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@$(SOURCE_DATE_EPOCH)' \
		--exclude='./$(BUILD)' --exclude='./$(DIST)' --exclude='./.git' \
		--exclude='*/__pycache__' \
		--exclude='*.pyc' --exclude='*.pyo' --exclude='*.plist' \
		--transform='s,^\.$$,$(DIST_NAME),' --transform='s,^\./,$(DIST_NAME)/,' \
		-I 'gzip -n' -cf $(DIST)/$(DIST_NAME).tar.gz .
	sha256sum $(DIST)/$(DIST_NAME).tar.gz > $(DIST)/$(DIST_NAME).tar.gz.sha256
	@printf '%s\n' 'release archive: $(DIST)/$(DIST_NAME).tar.gz'

dist-check: dist
	tools/archive_tests.sh $(DIST)/$(DIST_NAME).tar.gz

version:
	@printf '%s\n' 'Hilbert 1.0.0'

.PHONY: help install-user release-check bootstrap

help:
	@printf '%s\n' 'Hilbert build targets:'
	@printf '%s\n' '  all              build hilbert and hilmake'
	@printf '%s\n' '  check            repository + runtime checks'
	@printf '%s\n' '  cli-test         compiler/builder CLI smoke test'
	@printf '%s\n' '  hilmake-test     build, run, clean, and safety-test a project'
	@printf '%s\n' '  example-test     check every example and run stdlib-only examples'
	@printf '%s\n' '  benchmark        measure compiler, hilmake, native code, GC and threads'
	@printf '%s\n' '  smoke            compile and run a tiny Hilbert program'
	@printf '%s\n' '  compiler-test    language, optimizer, trap, and compile-fail tests'
	@printf '%s\n' '  stdlib-native-test native-link every standard-library module'
	@printf '%s\n' '  cache-test       verify root/module incremental cache separation'
	@printf '%s\n' '  runtime-sanitize run GC tests under ASan/UBSan'
	@printf '%s\n' '  runtime-analyze  strict C warnings and available static analyzers'
	@printf '%s\n' '  runtime-sanitize-strict require ASan/UBSan support and run it'
	@printf '%s\n' '  release-check    run the normal public release gates'
	@printf '%s\n' '  install-check    stage and verify the install layout'
	@printf '%s\n' '  dist-check       build and execute the packaged source archive'
	@printf '%s\n' '  install-user     install below ~/.local'
	@printf '%s\n' '  bootstrap        build build/hilbert0 from GNU Modula-2'

install-user: all
	$(MAKE) install PREFIX="$(HOME)/.local"

.PHONY: release-check-strict

release-check: check runtime-analyze runtime-sanitize cli-test hilmake-test example-test smoke compiler-test cache-test stdlib-native-test install-check
	@printf '%s\n' 'release gate: ok'

release-check-strict: release-check
	CC="$(CC)" REQUIRE_SANITIZERS=1 REQUIRE_LEAK_SANITIZER=1 tools/runtime_sanitize.sh
	@printf '%s\n' 'strict release gate: ok'

bootstrap: compiler
	cp $(BUILD)/hilbert $(BUILD)/hilbert0
	@printf '%s\n' 'built $(BUILD)/hilbert0'
