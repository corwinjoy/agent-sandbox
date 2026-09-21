#!/usr/bin/env bash
# Run the test suite.
#
#   tests/run-tests.sh                 static + unit   (seconds; needs bash, jq, python3, git)
#   tests/run-tests.sh --integration   also the integration tests (needs rootless Podman and a
#                                      finished 01-setup-podman.sh; about a minute)
#
# Not covered here, because they need a Claude login, a GitHub token or a GPU:
#   test-hook-blocking.sh [--untrusted], agent-run.sh --check-token, --gpu, --perf
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
RC=0
./static.sh || RC=1
./unit.sh   || RC=1
if [ "${1:-}" = "--integration" ]; then ./integration.sh || RC=1; fi
echo; [ "$RC" = 0 ] && echo "ALL TEST SUITES PASSED" || echo "SOME TESTS FAILED"
exit "$RC"
