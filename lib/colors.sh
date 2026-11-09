#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# lib/colors.sh - ANSI color handling for Linux Diagnostic Toolkit.
#
# Colors are initialized through colors_init() so that the CLI can honor the
# --no-color flag and the NO_COLOR environment variable. When stdout is not a
# terminal, colors are disabled automatically.
#
# This file only defines variables/functions; it does not execute anything at
# source time, which keeps it safe to source from tests.

# Color escape variables. Empty string means "no color".
C_RESET=''
C_BOLD=''
C_DIM=''
C_RED=''
C_GREEN=''
C_YELLOW=''
C_BLUE=''
C_CYAN=''
C_MAGENTA=''

# Internal flag; 1 means colors are enabled.
LDT_COLORS_ENABLED=0

# colors_init [--force-disable]
# Decide whether colored output should be used and populate the C_* variables.
colors_init() {
    local disable=0

    # Explicit request from the CLI flag.
    if [[ "${1:-}" == "--disable" ]]; then
        disable=1
    fi

    # Respect the de-facto NO_COLOR standard: any non-empty value disables color.
    if [[ -n "${NO_COLOR:-}" ]]; then
        disable=1
    fi

    # Allow tests / callers to force-disable through an internal variable.
    if [[ "${LDT_NO_COLOR:-0}" == "1" ]]; then
        disable=1
    fi

    # Disable color when stdout is not a terminal (e.g. piped or redirected).
    if [[ ! -t 1 ]]; then
        disable=1
    fi

    # A "dumb" terminal does not understand ANSI codes.
    if [[ "${TERM:-}" == "dumb" ]]; then
        disable=1
    fi

    if (( disable )); then
        C_RESET=''; C_BOLD=''; C_DIM=''
        C_RED=''; C_GREEN=''; C_YELLOW=''
        C_BLUE=''; C_CYAN=''; C_MAGENTA=''
        LDT_COLORS_ENABLED=0
        return 0
    fi

    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_MAGENTA=$'\033[35m'
    LDT_COLORS_ENABLED=1
    return 0
}
