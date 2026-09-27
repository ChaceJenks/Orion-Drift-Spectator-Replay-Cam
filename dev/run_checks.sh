#!/usr/bin/env bash
# Type-check and unit-test the replay camera without launching the game client.
#
# Two things are happening here:
#
#  1. STAGING. Camera packages use sibling requires by bare name, which is what
#     the game's Luau host expects ("require(\"util\")"). The reference `luau`
#     CLI insists on ./ prefixes, so tests cannot require the package directly.
#     We copy the package to .stage/pkg and rewrite the require paths in the
#     copy only. Shipped code stays in the form the game wants.
#
#  2. ANALYSIS. luau-lsp analyze type-checks the package as-is (it resolves bare
#     sibling requires), using dev/defs/spectator.d.lua for the API surface and
#     dev/base.luaurc to silence the lints that do not apply to camera scripts.
#
# Usage: dev/run_checks.sh [--skip-tests] [--skip-analyze]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${TOOLS_DIR:-}" ] && [ -x "$ROOT/../.tools/luau" ] && [ -x "$ROOT/../.tools/luau-lsp" ]; then
	TOOLS="$ROOT/../.tools"
else
	TOOLS="${TOOLS_DIR:-$ROOT/.tools}"
fi
PKG="$ROOT/Behaviors/you.replaycam"
STAGE="$ROOT/.stage"
TESTS="$ROOT/dev/tests"
DEFS="$ROOT/dev/defs/spectator.d.lua"
BASE_RC="$ROOT/dev/base.luaurc"

SKIP_TESTS=0
SKIP_ANALYZE=0
for arg in "$@"; do
	case "$arg" in
	--skip-tests) SKIP_TESTS=1 ;;
	--skip-analyze) SKIP_ANALYZE=1 ;;
	esac
done

if [ ! -x "$TOOLS/luau" ] || [ ! -x "$TOOLS/luau-lsp" ]; then
	echo "tooling missing; run dev/setup_tools.sh first" >&2
	exit 1
fi

########################################
if [ "$SKIP_TESTS" -eq 0 ]; then
	echo "== staging package for the reference CLI =="
	rm -rf "$STAGE"
	mkdir -p "$STAGE/pkg" "$STAGE/tests"
	cp "$PKG"/*.luau "$STAGE/pkg/"
	cp "$TESTS"/*.luau "$STAGE/tests/"
	# require("x") -> require("./x")  (bare sibling -> relative for the CLI only)
	sed -i -E 's/require\("([A-Za-z0-9_.\/]+)"\)/require(".\/\1")/g' "$STAGE/pkg"/*.luau

	# Each test file runs as the MAIN script, never via require(). The reference
	# CLI silently skips a required module that fails to parse: a suite driven
	# through require() reported all-clear while executing nothing at all. As
	# main scripts, parse errors and failed assertions both give a real exit code.
	echo "== unit tests =="
	test_failures=0
	test_files=0
	for test_file in "$STAGE"/tests/test_*.luau; do
		test_files=$((test_files + 1))
		echo "-- $(basename "$test_file" .luau)"
		if ! "$TOOLS/luau" "$test_file"; then
			test_failures=$((test_failures + 1))
		fi
	done
	if [ "$test_files" -eq 0 ]; then
		echo "no test files found" >&2
		exit 1
	fi
	if [ "$test_failures" -ne 0 ]; then
		echo "$test_failures of $test_files test file(s) failed" >&2
		exit 1
	fi
	echo "ran $test_files test file(s), all green"
fi

analyze() {
	"$TOOLS/luau-lsp" analyze \
		--platform=standard \
		--base-luaurc="$BASE_RC" \
		--defs="$DEFS" \
		"$@"
}

########################################
if [ "$SKIP_ANALYZE" -eq 0 ]; then
	echo "== strict type check: package =="
	# The lifecycle entry points (main/tick/onGui/...) are called by the client,
	# so FunctionUnused must be off; base.luaurc does that.
	analyze "$PKG"/*.luau

	# The tests are checked against the staged copy rather than dev/tests, because
	# they require the package by relative path ("../pkg/util"), which only exists
	# after staging. Same sources, resolvable imports.
	if [ -d "$STAGE/tests" ]; then
		echo "== strict type check: tests =="
		analyze "$STAGE"/tests/*.luau
	fi

	# The probe ships as its own camera and must stay loadable on its own.
	if [ -f "$ROOT/probe/Behaviors/you.preprobe/main.luau" ]; then
		echo "== strict type check: probe =="
		analyze "$ROOT/probe/Behaviors/you.preprobe/main.luau"
	fi

	echo "type check clean"
fi

echo "all checks passed"
