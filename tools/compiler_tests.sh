#!/bin/sh
set -eu

HILBERT=${HILBERT:-./build/hilbert}

fail_with() {
    file=$1
    code=$2
    out=$(mktemp)
    trap 'rm -f "$out"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if "$HILBERT" check "$file" -I tests >"$out" 2>&1; then
        echo "expected $file to fail" >&2
        cat "$out" >&2
        exit 1
    fi
    if ! grep -q "H$code" "$out"; then
        echo "$file failed, but not with H$code" >&2
        cat "$out" >&2
        exit 1
    fi
    rm -f "$out"
    trap - EXIT HUP INT TERM
}

warn_with() {
    file=$1
    code=$2
    out=$(mktemp)
    trap 'rm -f "$out"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! "$HILBERT" check "$file" --no-color >"$out" 2>&1; then
        echo "$file should compile with a warning" >&2
        cat "$out" >&2
        exit 1
    fi
    if ! grep -q "warning\[H$code\]" "$out"; then
        echo "$file did not produce warning H$code" >&2
        cat "$out" >&2
        exit 1
    fi
    if "$HILBERT" check "$file" --no-color -Werror >"$out" 2>&1; then
        echo "$file should fail under -Werror" >&2
        cat "$out" >&2
        exit 1
    fi
    if ! grep -q "warning\[H$code\]" "$out"; then
        echo "$file failed under -Werror without warning H$code" >&2
        cat "$out" >&2
        exit 1
    fi
    rm -f "$out"
    trap - EXIT HUP INT TERM
}

"$HILBERT" check tests/smoke.hil
"$HILBERT" check tests/borrow_disjoint_fields.hil
"$HILBERT" check tests/borrow_module_fields.hil -I tests

run_case() {
    src=$1
    name=$2
    shift 2
    bin=$(mktemp)
    out=$(mktemp)
    rm -f "$bin"
    if ! "$HILBERT" build "$src" -I tests -o "$bin" >"$out" 2>&1; then
        echo "compiler test $name failed during compilation" >&2
        cat "$out" >&2
        rm -f "$bin" "$out"
        exit 1
    fi
    if ! "$bin" "$@"; then
        echo "compiler test $name failed during execution" >&2
        rm -f "$bin" "$out"
        exit 1
    fi
    rm -f "$bin" "$out"
}

run_case tests/case_global.hil case-global
run_case tests/import_values.hil import-values
run_case tests/enum_case.hil enum-case
run_case tests/numeric_conversion.hil numeric-conversion
run_case tests/generic_record.hil generic-record
run_case tests/generic_recursive_record.hil generic-recursive-record
run_case tests/const_types.hil const-types
run_case tests/for_step.hil for-step
run_case tests/slice_from_array.hil slice-from-array
run_case tests/recursive_record.hil recursive-record
run_case tests/atomic_basic.hil atomic-basic
run_case tests/control_flow.hil control-flow
run_case tests/abi_calls.hil abi-calls
run_case tests/slice_value.hil slice-value
run_case tests/tasks_parallel.hil tasks-parallel
run_case tests/task_join_status.hil task-join-status
run_case tests/native_thread_callback.hil native-thread-callback
run_case tests/native_sync.hil native-sync
run_case tests/stdlib_integration.hil stdlib-integration
run_case tests/posix_stdlib.hil posix-stdlib
run_case tests/arguments.hil arguments alpha beta
run_case tests/narrow_var.hil narrow-var
run_case tests/real_exponent.hil real-exponent
run_case tests/import_selective.hil import-selective
run_case tests/import_alias.hil import-alias
run_case tests/procedure_values.hil procedure-values
run_case tests/finite_sets.hil finite-sets
run_case tests/variant_records.hil variant-records
run_case tests/definition_modules.hil definition-modules
run_case tests/generic_procedures.hil generic-procedures
run_case tests/generic_procedures_imported.hil generic-procedures-imported
run_case tests/unicode_character.hil unicode-character
run_case tests/arena_alignment.hil arena-alignment
run_case tests/arithmetic_semantics.hil arithmetic-semantics
run_case tests/default_initialization.hil default-initialization
run_case tests/optional_result.hil optional-result
run_case tests/stdlib_generics.hil stdlib-generics
run_case tests/division_basic.hil division-basic
run_case tests/division_import.hil division-import
run_case tests/division_generic.hil division-generic
run_case tests/division_generic_import.hil division-generic-import
run_case tests/division_platform.hil division-platform
run_case tests/division_inactive_import.hil division-inactive-import

for profile in debug release size; do
    profile_bin=$(mktemp)
    rm -f "$profile_bin"
    "$HILBERT" build tests/division_profile_select.hil --profile "$profile" -o "$profile_bin" --quiet
    "$profile_bin"
    rm -f "$profile_bin"
done

"$HILBERT" check tests/division_runtime_select.hil --runtime hosted --profile release --no-color
"$HILBERT" check tests/division_runtime_select.hil --runtime freestanding --profile release --no-color
"$HILBERT" check stdlib/Platform.hil --target aarch64-linux-gnu --profile release --runtime hosted --no-color
"$HILBERT" check stdlib/Platform.hil --target aarch64-linux-gnu --profile release --runtime freestanding --no-color

loop_dir=$(mktemp -d)
trap 'rm -rf "$loop_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for opt in O1 O2 O3 Os; do
    loop_bin="$loop_dir/optimizer-loop-$opt"
    "$HILBERT" build tests/optimizer_loop.hil -I tests "-$opt" -o "$loop_bin" >/dev/null
    python3 - "$loop_bin" <<'PYRUN'
import subprocess
import sys

try:
    subprocess.run([sys.argv[1]], check=True, timeout=5)
except subprocess.TimeoutExpired:
    raise SystemExit("optimized loop did not terminate")
PYRUN
done
rm -rf "$loop_dir"
trap - EXIT HUP INT TERM

# Multi-eightbyte values have optimizer-sensitive liveness and ABI paths.
slice_dir=$(mktemp -d)
trap 'rm -rf "$slice_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for opt in O0 O1 O2 O3 Os; do
    slice_bin="$slice_dir/slice-value-$opt"
    "$HILBERT" build tests/slice_value.hil -I tests "-$opt" -o "$slice_bin" >/dev/null
    "$slice_bin"
done
rm -rf "$slice_dir"
trap - EXIT HUP INT TERM

# These paths exercise control flow, aggregate copies and the language features
# whose lowering creates less ordinary HIR.  Every supported optimization level
# gets the same executable semantics check.
order_dir=$(mktemp -d)
trap 'rm -rf "$order_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for opt in O0 O1 O2 O3 Os; do
    for case_name in evaluation_order arithmetic_semantics default_initialization for_shadow aggregate_partial_copy \
        finite_sets variant_records procedure_values generic_procedures \
        generic_procedures_imported optional_result stdlib_generics definition_modules division_basic division_import division_generic division_generic_import; do
        case_bin="$order_dir/$case_name-$opt"
        "$HILBERT" build "tests/$case_name.hil" -I tests "-$opt" -o "$case_bin" >/dev/null
        "$case_bin"
    done
done
rm -rf "$order_dir"
trap - EXIT HUP INT TERM

bool_dir=$(mktemp -d)
trap 'rm -rf "$bool_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$bool_dir/bool.c" <<'CBOOL'
#include <stdbool.h>
bool hilbert_test_true(void) { return true; }
bool hilbert_test_false(void) { return false; }
bool hilbert_test_not(bool value) { return !value; }
CBOOL
${CC:-cc} -O2 -fPIC -c "$bool_dir/bool.c" -o "$bool_dir/bool.o"
${AR:-ar} rcs "$bool_dir/libhilbert_test_bool.a" "$bool_dir/bool.o"
"$HILBERT" build tests/foreign_bool.hil -L "$bool_dir" -o "$bool_dir/foreign-bool" >/dev/null
"$bool_dir/foreign-bool"
rm -rf "$bool_dir"
trap - EXIT HUP INT TERM

callback_dir=$(mktemp -d)
trap 'rm -rf "$callback_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$callback_dir/callback.c" <<'CCALLBACK'
#include <stdint.h>
typedef int64_t (*hilbert_binary)(int64_t, int64_t);
int64_t hilbert_test_call_callback(hilbert_binary callback, int64_t left, int64_t right) {
    return callback(left, right);
}
int64_t hilbert_test_subtract(int64_t left, int64_t right) { return left - right; }
CCALLBACK
${CC:-cc} -O2 -fPIC -c "$callback_dir/callback.c" -o "$callback_dir/callback.o"
${AR:-ar} rcs "$callback_dir/libhilbert_test_callback.a" "$callback_dir/callback.o"
"$HILBERT" build tests/c_callback.hil -L "$callback_dir" -lhilbert_test_callback -o "$callback_dir/c-callback" >/dev/null
"$callback_dir/c-callback"
rm -rf "$callback_dir"
trap - EXIT HUP INT TERM

varargs_dir=$(mktemp -d)
trap 'rm -rf "$varargs_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$varargs_dir/varargs.c" <<'CVARARGS'
#include <stdarg.h>
#include <stdint.h>
int32_t hilbert_test_varargs(int32_t marker, ...) {
    va_list values;
    int boolean_value, character_value, byte_value;
    double real_value;
    uint64_t wide_value;
    va_start(values, marker);
    boolean_value = va_arg(values, int);
    character_value = va_arg(values, int);
    byte_value = va_arg(values, int);
    real_value = va_arg(values, double);
    wide_value = va_arg(values, uint64_t);
    va_end(values);
    return marker == 77 && boolean_value == 1 && character_value == 65 &&
           byte_value == 250 && real_value == 1.5 && wide_value == UINT64_MAX;
}
CVARARGS
${CC:-cc} -O2 -fPIC -c "$varargs_dir/varargs.c" -o "$varargs_dir/varargs.o"
${AR:-ar} rcs "$varargs_dir/libhilbert_test_varargs.a" "$varargs_dir/varargs.o"
"$HILBERT" build tests/c_varargs.hil -L "$varargs_dir" -lhilbert_test_varargs -o "$varargs_dir/c-varargs" >/dev/null
"$varargs_dir/c-varargs"
rm -rf "$varargs_dir"
trap - EXIT HUP INT TERM

struct_dir=$(mktemp -d)
trap 'rm -rf "$struct_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$struct_dir/struct_abi.c" <<'CSTRUCTABI'
#include <stdbool.h>
#include <stdint.h>

struct real_pair { double x, y; };
struct mixed { int64_t code; double value; };
struct nested_reals { double values[2]; };

double hilbert_test_sum_real_pair(struct real_pair pair) {
    return pair.x + pair.y;
}

struct mixed hilbert_test_make_mixed(int64_t code, double value) {
    struct mixed result = {code, value};
    return result;
}

bool hilbert_test_check_nested(struct nested_reals value) {
    return value.values[0] + value.values[1] == 42.0;
}
CSTRUCTABI
${CC:-cc} -O2 -fPIC -c "$struct_dir/struct_abi.c" -o "$struct_dir/struct_abi.o"
${AR:-ar} rcs "$struct_dir/libhilbert_test_struct_abi.a" "$struct_dir/struct_abi.o"
"$HILBERT" build tests/c_struct_abi.hil -L "$struct_dir" -lhilbert_test_struct_abi -o "$struct_dir/c-struct-abi" >/dev/null
"$struct_dir/c-struct-abi"
rm -rf "$struct_dir"
trap - EXIT HUP INT TERM

fail_with tests/compile-fail/borrow_alias.hil 1133
fail_with tests/compile-fail/borrow_parent_field.hil 1133

reserved_out=$(mktemp)
if "$HILBERT" check tests/compile-fail/reserved_identifier_recovery.hil --no-color >"$reserved_out" 2>&1; then
    echo 'reserved identifier unexpectedly compiled' >&2
    rm -f "$reserved_out"
    exit 1
fi
grep -F 'error[H1002]: reserved word BY cannot be used as an identifier' "$reserved_out" >/dev/null
test "$(grep -c 'error\[H' "$reserved_out")" -eq 1
rm -f "$reserved_out"
fail_with tests/compile-fail/raw_pointer_safe.hil 1135
fail_with tests/compile-fail/escaping_address.hil 1134
fail_with tests/compile-fail/escaping_address_indirect.hil 1134
fail_with tests/compile-fail/escaping_address_global.hil 1134
fail_with tests/compile-fail/raw_to_managed.hil 1136
fail_with tests/compile-fail/reserved_post.hil 1137
fail_with tests/compile-fail/non_constant_const.hil 1138
fail_with tests/compile-fail/division_private.hil 1102
fail_with tests/compile-fail/division_duplicate_active.hil 1101
fail_with tests/compile-fail/division_inactive_syntax.hil 1002
fail_with tests/compile-fail/division_bad_condition.hil 1139
fail_with tests/compile-fail/division_end_mismatch.hil 1140
fail_with tests/compile-fail/division_initialization.hil 1137
fail_with tests/compile-fail/reserved_parallel_for.hil 1137
fail_with tests/compile-fail/missing_return.hil 1112
fail_with tests/compile-fail/exit_outside_loop.hil 1202
fail_with tests/compile-fail/array_without_count.hil 1001
fail_with tests/compile-fail/task_params.hil 1137
fail_with tests/compile-fail/recursive_value.hil 1124
fail_with tests/compile-fail/private_field.hil 1137
fail_with tests/compile-fail/for_zero_step.hil 1203
fail_with tests/compile-fail/for_undeclared_control.hil 1203
fail_with tests/compile-fail/case_runtime_label.hil 1131
fail_with tests/compile-fail/set_base_too_large.hil 1131
fail_with tests/compile-fail/set_element_out_of_range.hil 1122
fail_with tests/compile-fail/variant_duplicate_label.hil 1101
fail_with tests/compile-fail/definition_private_field.hil 1106
fail_with tests/compile-fail/definition_signature_mismatch.hil 1131
fail_with tests/compile-fail/generic_invalid_operation.hil 1120
fail_with tests/compile-fail/duplicate_module_import.hil 1101
fail_with tests/compile-fail/reserved_variant.hil 1137
fail_with tests/compile-fail/reserved_protected.hil 1137
fail_with tests/compile-fail/reserved_constraint.hil 1137
fail_with tests/compile-fail/reserved_with.hil 1137
fail_with tests/compile-fail/atomic_real.hil 1131
fail_with tests/compile-fail/atomic_order_argument.hil 1108
fail_with tests/compile-fail/enum_arithmetic.hil 1120
fail_with tests/compile-fail/distinct_record.hil 1131
fail_with tests/compile-fail/implicit_integer_address.hil 1110
fail_with tests/compile-fail/implicit_integer_char.hil 1110
fail_with tests/compile-fail/procedure_end_mismatch.hil 1017
fail_with tests/compile-fail/module_end_mismatch.hil 1008
fail_with tests/compile-fail/module_end_missing.hil 1002
fail_with tests/compile-fail/duplicate_record_field.hil 1101
fail_with tests/compile-fail/duplicate_enum_member.hil 1101
fail_with tests/compile-fail/duplicate_parameter.hil 1101
fail_with tests/compile-fail/duplicate_case_label.hil 1101
fail_with tests/compile-fail/character_literal_width.hil 1003
fail_with tests/compile-fail/selective_import_collision.hil 1101
fail_with tests/compile-fail/module_alias_collision.hil 1101
fail_with tests/compile-fail/selective_import_private.hil 1105
fail_with tests/compile-fail/selective_import_wildcard.hil 1002
fail_with tests/compile-fail/procedure_value_mismatch.hil 1110
fail_with tests/compile-fail/implicit_integer_narrowing.hil 1110
fail_with tests/compile-fail/integer_literal_overflow.hil 1006
fail_with tests/compile-fail/range_base_overflow.hil 1122
warn_with tests/warning_unreachable.hil 3006

run_runtime_fail() {
    file=$1
    name=$2
    bin=$(mktemp)
    out=$(mktemp)
    rm -f "$bin"
    if ! "$HILBERT" build "$file" -I tests -o "$bin" >"$out" 2>&1; then
        echo "runtime-fail test $name did not compile" >&2
        cat "$out" >&2
        rm -f "$bin" "$out"
        exit 1
    fi
    if ! python3 - "$bin" <<'PYRUNFAIL'
import resource
import subprocess
import sys

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
result = subprocess.run([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
raise SystemExit(0 if result.returncode != 0 else 1)
PYRUNFAIL
    then
        echo "runtime-fail test $name unexpectedly succeeded" >&2
        rm -f "$bin" "$out"
        exit 1
    fi
    rm -f "$bin" "$out"
}

run_runtime_fail tests/runtime-fail/bounds.hil bounds
run_runtime_fail tests/runtime-fail/range.hil range
run_runtime_fail tests/runtime-fail/set_element.hil set-element
run_runtime_fail tests/runtime-fail/variant_field.hil variant-field
run_runtime_fail tests/runtime-fail/shift_count.hil shift-count
run_runtime_fail tests/runtime-fail/range_before_narrowing.hil range-before-narrowing
run_runtime_fail tests/runtime-fail/float_to_integer_overflow.hil float-to-integer-overflow
run_runtime_fail tests/runtime-fail/float_to_integer_nan.hil float-to-integer-nan
run_runtime_fail tests/runtime-fail/float_to_unsigned_negative.hil float-to-unsigned-negative
run_runtime_fail tests/runtime-fail/division_by_zero.hil division-by-zero
run_runtime_fail tests/runtime-fail/signed_division_overflow.hil signed-division-overflow

# Shipped source should at least make it through the front end.  This caught a
# couple of embarrassing cases where the library used syntax 1.0 had reserved.
for file in stdlib/*.hil bindings/*.hil; do
    if ! "$HILBERT" check "$file" -I stdlib -I bindings >"$out" 2>&1; then
        echo "shipped source check failed: $file" >&2
        cat "$out" >&2
        rm -f "$out"
        exit 1
    fi
done
example_list=$(mktemp)
find examples -type f -name '*.hil' -print | sort >"$example_list"
while IFS= read -r file; do
    if ! "$HILBERT" check "$file" -I stdlib -I bindings >"$out" 2>&1; then
        echo "example source check failed: $file" >&2
        cat "$out" >&2; rm -f "$out" "$example_list"
        exit 1
    fi
done <"$example_list"
rm -f "$out" "$example_list"


token_dir=$(mktemp -d)
python3 - "$token_dir/too_long.hil" <<'PYTOKEN'
from pathlib import Path
import sys
name = 'A' * 1100
Path(sys.argv[1]).write_text(f'MODULE TokenLimit;\nVAR {name}: INTEGER;\nEND TokenLimit.\n')
PYTOKEN
if "$HILBERT" check "$token_dir/too_long.hil" --no-color >"$token_dir/out" 2>&1; then
    echo 'compiler accepted a silently truncated source token' >&2
    rm -rf "$token_dir"
    exit 1
fi
grep -F 'H1018' "$token_dir/out" >/dev/null
rm -rf "$token_dir"

echo "compiler tests ok"
