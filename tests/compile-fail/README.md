# compile-fail cases

these are tiny programs that are supposed to be wrong. `tools/compiler_tests.sh` is the useful index because it records the diagnostic code each file is expected to hit, keeping a second giant list here just gets stale.

there are cases for borrowing/raw pointers, missing returns, bad loops and case labels, reserved 1.0 syntax, invalid atomics, enum arithmetic and a few type-layout mistakes. if a compiler change makes one of them compile, make sure you meant to do that before changing the expected result.
