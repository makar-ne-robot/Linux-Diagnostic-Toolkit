#!/usr/bin/env bash
#
# lib/utils.sh - Shared helpers for Linux Diagnostic Toolkit.
#
# Provides:
#   * command / file availability helpers
#   * the diagnostic output buffer used to build the TXT report
#   * colored emit_* wrappers
#   * warning collection
#   * small parsing helpers
#
# All functions are side-effect free apart from printing and appending to the
# in-memory buffers, so modules never modify the system.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
LDT_NAME="Linux Diagnostic Toolkit"
LDT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
# REPORT_BUF accumulates the plain-text lines that will be written to the report.
REPORT_BUF=()
# WARNINGS holds "LEVEL|message" entries detected during diagnostics.
# LEVEL is one of INFO, WARN or CRIT.
WARNINGS=()
# Counters for the final score (INFO findings do not affect the score).
WARN_COUNT=0
CRIT_COUNT=0

# ---------------------------------------------------------------------------
# Structured diagnostic data.
#
# Modules record machine-readable findings here in addition to the human
# readable text buffer. The JSON exporter and the diagnostic summary read
# from these. Scalar values use dotted keys (e.g. "cpu.model"); list values
# use the dedicated arrays below so that record separators stay explicit.
# ---------------------------------------------------------------------------
declare -A LDT_DATA=()
# Names of the diagnostic sections that actually ran this session.
declare -a LDT_RAN=()
# "filesystem|size_kb|used_kb|avail_kb|use_percent|mount"
declare -a DISK_ROWS=()
# "filesystem|use_percent|mount"
declare -a INODE_ROWS=()
# Failed systemd unit names.
declare -a SVC_FAILED_LIST=()
# "name|state|ipv4|ipv6"
declare -a NET_IFACES=()
# DNS server addresses.
declare -a NET_DNS_LIST=()
# "name|value_c"
declare -a TEMP_ROWS=()
# "name|capacity_percent|status"
declare -a BATT_ROWS=()

# reset_state - clear all accumulated diagnostic state.
reset_state() {
    REPORT_BUF=()
    WARNINGS=()
    WARN_COUNT=0
    CRIT_COUNT=0
    LDT_DATA=()
    LDT_RAN=()
    DISK_ROWS=()
    INODE_ROWS=()
    SVC_FAILED_LIST=()
    NET_IFACES=()
    NET_DNS_LIST=()
    TEMP_ROWS=()
    BATT_ROWS=()
}

# data_set KEY VALUE - store a structured scalar (empty VALUE clears it).
data_set() {
    LDT_DATA["$1"]="$2"
}

# data_get KEY - print a structured scalar (empty string when unset).
data_get() {
    printf '%s' "${LDT_DATA[$1]:-}"
}

# mark_ran SECTION - record that a diagnostic section executed.
mark_ran() {
    LDT_RAN+=("$1")
}

# has_ran SECTION - return 0 if the given section executed this session.
has_ran() {
    local s
    for s in "${LDT_RAN[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Command / file helpers
# ---------------------------------------------------------------------------
# has_cmd NAME - return 0 if a command exists in PATH.
has_cmd() {
    command -v -- "$1" >/dev/null 2>&1
}

# has_file PATH - return 0 if PATH exists and is readable.
has_file() {
    [[ -r "$1" ]]
}

# get_hostname - best-effort hostname without assuming the `hostname` command.
get_hostname() {
    if has_file /proc/sys/kernel/hostname; then
        local h
        h="$(cat /proc/sys/kernel/hostname 2>/dev/null)"
        if [[ -n "$h" ]]; then
            printf '%s\n' "$h"
            return 0
        fi
    fi
    if has_cmd hostname; then
        local h
        h="$(hostname 2>/dev/null)"
        if [[ -n "$h" ]]; then
            printf '%s\n' "$h"
            return 0
        fi
    fi
    printf 'unknown\n'
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
# emit COLOR_VAR "text..." - print text (optionally colored) and store the
# plain version in the report buffer. COLOR_VAR is the *name* of a color
# variable, e.g. C_GREEN, or an empty string for no color.
emit() {
    local color_var="${1:-}"
    shift || true
    local text="$*"

    if [[ -n "$color_var" && -n "${!color_var:-}" ]]; then
        printf '%s%s%s\n' "${!color_var}" "$text" "${C_RESET}"
    else
        printf '%s\n' "$text"
    fi

    REPORT_BUF+=("$text")
}

# emit_info/ok/warn/err/muted - semantic colored wrappers around emit.
emit_info()  { emit C_CYAN "$@"; }
emit_ok()    { emit C_GREEN "$@"; }
emit_warn()  { emit C_YELLOW "$@"; }
emit_err()   { emit C_RED "$@"; }
emit_muted() { emit C_DIM "$@"; }

# emit_kv KEY VALUE - emit a "  KEY: VALUE" indented line.
emit_kv() {
    emit "" "  $1: $2"
}

# section TITLE - emit a visual section separator plus a heading.
section() {
    emit "" ""
    emit C_BLUE "--------------------------------------------------------------"
    emit C_BOLD "$1"
    emit C_BLUE "--------------------------------------------------------------"
}

# note TEXT - terminal-only informational line (not stored in the report).
note() {
    printf '%s%s%s\n' "${C_CYAN:-}" "$*" "${C_RESET:-}"
}

# ---------------------------------------------------------------------------
# Warning collection
# ---------------------------------------------------------------------------
# add_warning LEVEL MESSAGE - record a finding.
# LEVEL is INFO, WARN or CRIT. Only WARN/CRIT affect the health score.
add_warning() {
    local level="$1"
    shift
    local message="$*"
    WARNINGS+=("${level}|${message}")
    case "$level" in
        CRIT) CRIT_COUNT=$((CRIT_COUNT + 1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        INFO) : ;;  # informational only
        *)    WARN_COUNT=$((WARN_COUNT + 1)) ;;
    esac
}

# add_info MESSAGE - record an informational (non-scoring) finding.
add_info() {
    add_warning INFO "$@"
}

# ---------------------------------------------------------------------------
# Numeric / parsing helpers
# ---------------------------------------------------------------------------
# is_number STRING - return 0 if STRING is a non-negative integer.
is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# is_float STRING - return 0 if STRING is a finite decimal number.
# Accepts an optional sign and optional fractional part; rejects empty
# strings, words, "nan" and "inf".
is_float() {
    [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# float_gt A B - return 0 if A is strictly greater than B.
# Uses awk for reliable fractional comparison (no `bc` dependency).
# Non-numeric inputs are treated as 0 by awk, so callers should validate
# with is_float() first when that matters.
float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'
}

# percent PART TOTAL - print integer percentage (0 when TOTAL is 0).
percent() {
    local part="$1" total="$2"
    if [[ -z "$total" || "$total" -eq 0 ]]; then
        printf '0\n'
        return 0
    fi
    # Integer arithmetic only: bash has no native float.
    printf '%d\n' "$(( (part * 100) / total ))"
}

# human_kb KB - convert a kibibyte value to a human readable string.
human_kb() {
    local kb="$1"
    if ! is_number "$kb"; then
        printf '%s\n' "$kb"
        return 0
    fi
    awk -v k="$kb" 'BEGIN {
        split("KiB MiB GiB TiB PiB", u, " ");
        i = 1; v = k;
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        printf "%.2f %s", v, u[i]
    }'
}

# numeric_compare A OP B - integer comparison helper used in tests/modules.
numeric_compare() {
    local a="$1" op="$2" b="$3"
    case "$op" in
        '<')  (( a <  b )) ;;
        '<=') (( a <= b )) ;;
        '>')  (( a >  b )) ;;
        '>=') (( a >= b )) ;;
        '==') (( a == b )) ;;
        *) return 2 ;;
    esac
}

# trim STRING - strip leading/trailing whitespace.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "$s"
}

# ---------------------------------------------------------------------------
# Banner / misc
# ---------------------------------------------------------------------------
# print_banner - draw the large CLI header (terminal only).
print_banner() {
    printf '%s' "${C_CYAN:-}"
    cat <<'BANNER'
+======================================================+
|            LINUX DIAGNOSTIC TOOLKIT                  |
|                 System Analyzer                      |
+======================================================+
BANNER
    printf '%s\n' "${C_RESET:-}"
}

# die MESSAGE - print an error to stderr and exit non-zero.
die() {
    printf '%sError:%s %s\n' "${C_RED:-}" "${C_RESET:-}" "$*" >&2
    exit 1
}
