#!/usr/bin/env bash
# mayhem/build.sh — build pmp-library's fuzz harnesses (sanitized) and its gtest suite (normal flags).
# Runs in the commit image as `mayhem` in /mayhem; idempotent and offline (all deps vendored in external/).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export CC CXX
cd "$SRC"

COMMON_OPTS=(-DPMP_BUILD_EXAMPLES=OFF -DPMP_BUILD_VIEWERS=OFF -DPMP_BUILD_DOCS=OFF
             -DPMP_INSTALL=OFF -DBUILD_SHARED_LIBS=OFF -DPMP_STRICT_COMPILATION=OFF
             -DCMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON)

# 1) The library itself, instrumented. Build type "Fuzz" (no per-config flags) keeps upstream's
#    assert()s active — they are not hidden with -DNDEBUG — and uses only our flags.
#    build/ is gitignored upstream, so `git clean -ffdX` removes it. -fsanitize=fuzzer-no-link gives
#    the library SanCov edges (SANITIZER_FLAGS carries none); it is added unconditionally.
COV_FLAGS="-fsanitize=fuzzer-no-link"
# One UBSan check relaxed: `null`. read_pmp (and other I/O paths) pass `&vec[0]` of an EMPTY
# property vector to fread() with a count of 0 — a reference bound to nullptr inside libstdc++'s
# operator[] that nothing dereferences. It fires on every .pmp input with a zero element count,
# including the 1-byte probe libFuzzer runs at startup, so the target could not run at all.
# Real null dereferences still fault under ASan (SEGV); every other UBSan check stays halting.
UB_RELAX=""; [ -n "$SANITIZER_FLAGS" ] && UB_RELAX="-fno-sanitize=null"   # must follow $SANITIZER_FLAGS
cmake -S . -B build/fuzz "${COMMON_OPTS[@]}" -DPMP_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Fuzz \
      -DCMAKE_C_FLAGS="-O1 $COV_FLAGS $SANITIZER_FLAGS $UB_RELAX $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="-O1 $COV_FLAGS $SANITIZER_FLAGS $UB_RELAX $DEBUG_FLAGS"
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target pmp

LIBS=("$SRC/build/fuzz/libpmp.a")
for l in "$SRC"/build/fuzz/libpredicates.a "$SRC"/build/fuzz/external/predicates/libpredicates.a; do
  [ -f "$l" ] && LIBS+=("$l")
done
INC=(-I"$SRC/src" -I"$SRC/external/eigen-5.0.1")
CXXF=(-std=c++20 -O1 $COV_FLAGS $SANITIZER_FLAGS $UB_RELAX $DEBUG_FLAGS "${INC[@]}")

# 2) Harnesses: libFuzzer binary + run-once standalone reproducer, each with the LSan-off hook.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/fuzz/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/fuzz/standalone_main.o
build_harness() { # <name> <source> [extra cxx flags...]
  local name="$1" src="$2"; shift 2
  $CXX "${CXXF[@]}" "$@" -c "$src" -o "build/fuzz/$name.o"
  $CXX "${CXXF[@]}" $LIB_FUZZING_ENGINE "build/fuzz/$name.o" build/fuzz/lsan_off.o "${LIBS[@]}" -o "/mayhem/$name"
  $CXX "${CXXF[@]}" build/fuzz/standalone_main.o "build/fuzz/$name.o" build/fuzz/lsan_off.o "${LIBS[@]}" -o "/mayhem/$name-standalone"
}
for fmt in off obj stl; do
  build_harness "fuzz_read_$fmt" "$SRC/mayhem/harnesses/fuzz_read.cpp" "-DFUZZ_EXT=\".$fmt\""
done
build_harness fuzz_read_pmp "$SRC/mayhem/harnesses/fuzz_read.cpp" '-DFUZZ_EXT=".pmp"' -DFUZZ_PMP_HEADER
build_harness fuzz_algorithms "$SRC/mayhem/harnesses/fuzz_algorithms.cpp"

# 3) Upstream's gtest suite with the project's normal (Release) flags; mayhem/test.sh runs it.
cmake -S . -B build/tests "${COMMON_OPTS[@]}" -DPMP_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS" --target gtest_runner
