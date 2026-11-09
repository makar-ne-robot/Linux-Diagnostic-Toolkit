#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# tests/test.sh - Basic test suite for Linux Diagnostic Toolkit.
#
# The suite is read-only: it never modifies the system, never requires root
# and cleans up any temporary files it creates.

set -u -o pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." >/dev/null 2>&1 && pwd)"

# Report helpers expect SCRIPT_DIR to be defined by main.sh; provide it here.
SCRIPT_DIR="$PROJECT_DIR"
export SCRIPT_DIR
export LDT_OUTPUT=""

# ---------------------------------------------------------------------------
# Minimal test harness.
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    printf '  [PASS] %s\n' "$1"
}

fail() {
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    printf '  [FAIL] %s\n' "$1"
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

assert_true() {
    local name="$1"
    shift
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

assert_false() {
    local name="$1"
    shift
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if "$@"; then
        fail "$name"
    else
        pass "$name"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name (missing '$needle')"
    fi
}

# ---------------------------------------------------------------------------
# Load the toolkit.
# ---------------------------------------------------------------------------
# shellcheck source=../lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=../lib/utils.sh
source "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../lib/report.sh
source "$PROJECT_DIR/lib/report.sh"
# shellcheck source=../modules/system.sh
source "$PROJECT_DIR/modules/system.sh"
# shellcheck source=../modules/disk.sh
source "$PROJECT_DIR/modules/disk.sh"
# shellcheck source=../modules/cpu.sh
source "$PROJECT_DIR/modules/cpu.sh"
# shellcheck source=../modules/memory.sh
source "$PROJECT_DIR/modules/memory.sh"
# shellcheck source=../modules/services.sh
source "$PROJECT_DIR/modules/services.sh"
# shellcheck source=../modules/network.sh
source "$PROJECT_DIR/modules/network.sh"

# Force plain output during tests.
colors_init --disable

# ---------------------------------------------------------------------------
# Tests: utility helpers.
# ---------------------------------------------------------------------------
test_utils() {
    printf '\n[utils helpers]\n'

    assert_true  "has_cmd detects bash"     has_cmd bash
    assert_false "has_cmd rejects missing"  has_cmd definitely_not_a_command_xyz
    assert_true  "has_file detects readable" has_file /etc/os-release
    assert_false "has_file rejects missing"  has_file /nonexistent/path/xyz

    assert_eq "50" "$(percent 50 100)" "percent basic"
    assert_eq "0"  "$(percent 0 0)"    "percent zero-total"

    assert_eq "512.00 KiB" "$(human_kb 512)"     "human_kb KiB"
    assert_eq "1.00 MiB" "$(human_kb 1024)"      "human_kb MiB"
    assert_eq "1.00 GiB" "$(human_kb 1048576)"   "human_kb GiB"

    assert_true  "is_number accepts digits" is_number 42
    assert_false "is_number rejects text"   is_number abc
    assert_eq "hello" "$(trim '  hello  ')" "trim whitespace"

    assert_true "numeric_compare >"  numeric_compare 5 '>' 3
    assert_true "numeric_compare <=" numeric_compare 3 '<=' 3
}

# ---------------------------------------------------------------------------
# Tests: score / report logic.
# ---------------------------------------------------------------------------
test_score() {
    printf '\n[scoring]\n'

    WARN_COUNT=0; CRIT_COUNT=0
    assert_eq "100" "$(compute_score)" "score with no findings"
    assert_eq "GOOD" "$(score_status 100)" "status GOOD"

    WARN_COUNT=2; CRIT_COUNT=0
    assert_eq "90" "$(compute_score)" "score with 2 warnings"

    WARN_COUNT=0; CRIT_COUNT=5
    assert_eq "0" "$(compute_score)" "score floors at 0"
    assert_eq "CRITICAL" "$(score_status 0)" "status CRITICAL"

    WARN_COUNT=0; CRIT_COUNT=0
}

# ---------------------------------------------------------------------------
# Tests: modules run and produce output.
# ---------------------------------------------------------------------------
test_modules() {
    printf '\n[modules]\n'

    local out

    reset_state
    out="$(system_info 2>&1)"
    assert_contains "$out" "SYSTEM INFORMATION" "system_info section header"
    assert_contains "$out" "Kernel" "system_info kernel line"

    reset_state
    out="$(cpu_info 2>&1)"
    assert_contains "$out" "CPU INFORMATION" "cpu_info section header"
    assert_contains "$out" "Logical cores" "cpu_info logical cores"

    reset_state
    out="$(memory_info 2>&1)"
    assert_contains "$out" "MEMORY INFORMATION" "memory_info section header"

    reset_state
    out="$(disk_check 2>&1)"
    assert_contains "$out" "DISK USAGE" "disk_check section header"

    reset_state
    out="$(services_check 2>&1)"
    assert_contains "$out" "SYSTEM SERVICES" "services_check section header"

    reset_state
    out="$(network_check 2>&1)"
    assert_contains "$out" "NETWORK" "network_check section header"
}

# ---------------------------------------------------------------------------
# Tests: graceful handling of missing files/commands.
# ---------------------------------------------------------------------------
test_missing_resources() {
    printf '\n[missing resources]\n'

    # Memory module with a non-existent meminfo file must add a warning.
    reset_state
    LDT_MEMINFO=/nonexistent/meminfo memory_info >/dev/null 2>&1
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if (( ${#WARNINGS[@]} > 0 )); then
        pass "memory_info warns on missing meminfo"
    else
        fail "memory_info warns on missing meminfo"
    fi
    unset LDT_MEMINFO

    # OS release reader with missing file returns non-zero.
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if ! LDT_OS_RELEASE=/nonexistent/os-release _read_os_release NAME; then
        pass "_read_os_release fails gracefully"
    else
        fail "_read_os_release fails gracefully"
    fi
}

# ---------------------------------------------------------------------------
# Tests: report generation.
# ---------------------------------------------------------------------------
test_report() {
    printf '\n[report generation]\n'

    local tmp report
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ldt-test.XXXXXX")"

    reset_state
    system_info >/dev/null 2>&1
    cpu_info >/dev/null 2>&1

    report="$tmp/report.txt"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if report_write "$report" >/dev/null 2>&1 && [[ -s "$report" ]]; then
        pass "report_write creates file"
    else
        fail "report_write creates file"
    fi

    local content
    content="$(cat "$report" 2>/dev/null)"
    assert_contains "$content" "DIAGNOSTIC REPORT" "report has header"
    assert_contains "$content" "WARNINGS" "report has warnings section"
    assert_contains "$content" "OVERALL ASSESSMENT" "report has assessment"

    # Default filename pattern.
    local fname
    fname="$(report_default_filename)"
    assert_contains "$fname" "linux-diagnostic-report-" "report filename prefix"

    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Tests: CLI flags (run the real entry point).
# ---------------------------------------------------------------------------
test_cli() {
    printf '\n[cli flags]\n'

    local out tmp report

    out="$(bash "$PROJECT_DIR/main.sh" --version 2>&1)"
    assert_contains "$out" "Linux Diagnostic Toolkit" "--version output"

    out="$(bash "$PROJECT_DIR/main.sh" --help 2>&1)"
    assert_contains "$out" "USAGE" "--help output"

    # Unknown flag must exit non-zero.
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if bash "$PROJECT_DIR/main.sh" --definitely-unknown >/dev/null 2>&1; then
        fail "unknown flag rejected"
    else
        pass "unknown flag rejected"
    fi

    # Full diagnostics with report to a temp file.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ldt-cli.XXXXXX")"
    report="$tmp/out.txt"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if bash "$PROJECT_DIR/main.sh" --full --no-color --output "$report" >/dev/null 2>&1; then
        # --full without --report should NOT create the file.
        if [[ -e "$report" ]]; then
            fail "--full alone did not write a report"
        else
            pass "--full alone does not write a report"
        fi
    else
        fail "--full exited non-zero"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if bash "$PROJECT_DIR/main.sh" --full --report --no-color --output "$report" >/dev/null 2>&1 \
        && [[ -s "$report" ]]; then
        pass "--full --report writes a report"
    else
        fail "--full --report writes a report"
    fi

    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------
printf '=============================================\n'
printf ' Linux Diagnostic Toolkit - Test Suite\n'
printf '=============================================\n'

test_utils
test_score
test_modules
test_missing_resources
test_report
test_cli

printf '\n=============================================\n'
printf ' Results: %d passed, %d failed (%d assertions)\n' \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_RUN"
printf '=============================================\n'

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
exit 0
