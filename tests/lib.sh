# shellcheck shell=bash
# Tiny assertion helpers shared by the test scripts. Source, do not run.
PASSED=0 FAILED=0
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # used by the scripts that source this file
SCRIPTS="$REPO/scripts"

section() { printf '\n== %s\n' "$*"; }
pass()    { PASSED=$((PASSED+1)); printf '  ok    %s\n' "$*"; }
fail()    { FAILED=$((FAILED+1)); printf '  FAIL  %s\n' "$*"; }

# check "description" command...      passes when the command succeeds
check()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
# check_not "description" command...  passes when the command fails
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
# has "description" "needle" "haystack"
has()       { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (expected to find: $2)"; printf '%s\n' "$3" | tail -n 5 | sed 's/^/        | /' ;; esac; }
# has_not "description" "needle" "haystack"
has_not()   { case "$3" in *"$2"*) fail "$1 (did not expect: $2)" ;; *) pass "$1" ;; esac; }
# eq "description" expected actual
eq()        { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

finish() {
  printf '\n%s: %d passed, %d failed\n' "${1:-tests}" "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}
