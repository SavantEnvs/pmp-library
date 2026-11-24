#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Upstream's googletest suite (tests/*.cpp: I/O round-trips, algorithms, mesh topology), built by
# mayhem/build.sh in build/tests. It runs from its own dir, where CMake copied data/.
RUNNER_DIR="$SRC/build/tests/tests"
RUNNER="$RUNNER_DIR/gtest_runner"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing — mayhem/build.sh did not build the suite" >&2
  emit_ctrf "googletest" 0 1 0
  exit 1
fi
LOG="$(mktemp)"
( cd "$RUNNER_DIR" && "$RUNNER" --gtest_brief=1 ) >"$LOG" 2>&1
rc=$?
tail -n 30 "$LOG"
total=$(sed -n 's/^\[==========\] \([0-9]\+\) tests\? from .* ran\..*/\1/p' "$LOG" | tail -1)
passed=$(sed -n 's/^\[  PASSED  \] \([0-9]\+\) tests\?.*/\1/p' "$LOG" | tail -1)
skipped=$(sed -n 's/^\[  SKIPPED \] \([0-9]\+\) tests\?.*/\1/p' "$LOG" | tail -1)
rm -f "$LOG"
total=${total:-0}; passed=${passed:-0}; skipped=${skipped:-0}
failed=$(( total - passed - skipped ))
# No summary (runner killed or neutered) or a non-zero exit with nothing failed counts as a failure.
if [ "$total" -eq 0 ] || { [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; }; then failed=$(( failed + 1 )); fi
emit_ctrf "googletest" "$passed" "$failed" "$skipped"
