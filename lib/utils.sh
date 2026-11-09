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
WARNINGS=()
# Counters for the final score.
WARN_COUNT=0
CRIT_COUNT=0

# reset_state - clear all accumulated diagnostic state.
reset_state() {
    REPORT_BUF=()
    WARNINGS=()
    WARN_COUNT=0
    CRIT_COUNT=0
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
# add_warning LEVEL MESSAGE - record a warning/critical finding.
# LEVEL is WARN or CRIT.
add_warning() {
    local level="$1"
    shift
    local message="$*"
    WARNINGS+=("${level}|${message}")
    if [[ "$level" == "CRIT" ]]; then
        CRIT_COUNT=$((CRIT_COUNT + 1))
    else
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
}

# ---------------------------------------------------------------------------
# Numeric / parsing helpers
# ---------------------------------------------------------------------------
# is_number STRING - return 0 if STRING is a non-negative integer.
is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
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
