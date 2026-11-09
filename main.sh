#!/usr/bin/env bash
#
# main.sh - Linux Diagnostic Toolkit entry point.
#
# Interactive CLI + non-interactive flags for diagnosing a Linux system and
# generating a plain-text report. See README.md for full documentation.
#
# This tool is strictly read-only: it never modifies system configuration,
# never uses sudo and never installs packages.

set -u -o pipefail

# ---------------------------------------------------------------------------
# Resolve the directory of this script so it can run from any cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# ---------------------------------------------------------------------------
# Load libraries and modules.
# ---------------------------------------------------------------------------
# shellcheck source=lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
# shellcheck source=lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"
# shellcheck source=modules/system.sh
source "$SCRIPT_DIR/modules/system.sh"
# shellcheck source=modules/disk.sh
source "$SCRIPT_DIR/modules/disk.sh"
# shellcheck source=modules/cpu.sh
source "$SCRIPT_DIR/modules/cpu.sh"
# shellcheck source=modules/memory.sh
source "$SCRIPT_DIR/modules/memory.sh"
# shellcheck source=modules/services.sh
source "$SCRIPT_DIR/modules/services.sh"
# shellcheck source=modules/network.sh
source "$SCRIPT_DIR/modules/network.sh"

# ---------------------------------------------------------------------------
# CLI options (defaults).
# ---------------------------------------------------------------------------
OPT_FULL=0
OPT_REPORT=0
OPT_NOCOLOR=0
LDT_OUTPUT=""

# ---------------------------------------------------------------------------
# Usage / version.
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${LDT_NAME} v${LDT_VERSION}

A safe, read-only CLI utility for diagnosing Linux system health and
producing a plain-text report.

USAGE:
    ./main.sh [OPTIONS]

OPTIONS:
    --full            Run the full diagnostic suite in non-interactive mode.
    --report          Run diagnostics and write a TXT report.
    --no-color        Disable ANSI colored output.
    --output PATH     Write the report to PATH (file or directory).
    -h, --help        Show this help and exit.
    -v, --version     Show version and exit.

EXAMPLES:
    ./main.sh
    ./main.sh --full
    ./main.sh --full --report
    ./main.sh --report
    ./main.sh --full --no-color
    ./main.sh --full --output ./my-report.txt

ENVIRONMENT:
    NO_COLOR          If set (non-empty), disables colors.
    LDT_OUTPUT        Alternative way to set the output path.
EOF
}

show_version() {
    printf '%s %s\n' "$LDT_NAME" "$LDT_VERSION"
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --full)      OPT_FULL=1 ;;
            --report)    OPT_REPORT=1 ;;
            --no-color)  OPT_NOCOLOR=1 ;;
            --output)
                shift
                if [[ $# -eq 0 ]]; then
                    printf 'Error: --output requires a path argument.\n' >&2
                    exit 2
                fi
                LDT_OUTPUT="$1"
                ;;
            --output=*)
                LDT_OUTPUT="${1#--output=}"
                ;;
            -h|--help)    usage; exit 0 ;;
            -v|--version) show_version; exit 0 ;;
            --)
                shift
                break
                ;;
            *)
                printf 'Error: unknown option: %s\n' "$1" >&2
                printf 'Try --help for usage information.\n' >&2
                exit 2
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Diagnostic runners.
# ---------------------------------------------------------------------------
# run_all - run every diagnostic module in report order.
run_all() {
    system_info
    cpu_info
    memory_info
    disk_check
    services_check
    network_check
}

# do_report - write the report from the current buffer.
do_report() {
    local path
    if path="$(report_write 2>/dev/null)"; then
        printf '%s\n' ""
        printf '%sReport saved:%s %s\n' "${C_GREEN:-}" "${C_RESET:-}" "$path"
        return 0
    else
        printf '%sFailed to write report.%s\n' "${C_RED:-}" "${C_RESET:-}" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Interactive menu.
# ---------------------------------------------------------------------------
menu_disk()    { disk_check; }
menu_cpu()     { cpu_info; }
menu_memory()  { memory_info; }
menu_services(){ services_check; }
menu_network() { network_check; }
menu_system()  { system_info; }

interactive_menu() {
    print_banner
    while true; do
        printf '\n'
        printf '%s[1]%s Full system diagnostics\n' "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[2]%s Disk diagnostics\n'        "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[3]%s CPU diagnostics\n'         "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[4]%s Memory diagnostics\n'      "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[5]%s Services diagnostics\n'    "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[6]%s Network diagnostics\n'     "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[7]%s System information\n'      "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[8]%s Generate diagnostic report\n' "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[9]%s Exit\n'                    "${C_CYAN:-}" "${C_RESET:-}"
        printf '\nSelect an option: '

        local choice
        if ! IFS= read -r choice; then
            # EOF (e.g. piped input): exit gracefully.
            printf '\n'
            break
        fi

        case "$choice" in
            1) reset_state; run_all ;;
            2) menu_disk ;;
            3) menu_cpu ;;
            4) menu_memory ;;
            5) menu_services ;;
            6) menu_network ;;
            7) menu_system ;;
            8)
                # If nothing has been collected yet, run a full pass first.
                if (( ${#REPORT_BUF[@]} == 0 )); then
                    reset_state
                    run_all
                fi
                do_report
                ;;
            9|q|quit|exit) break ;;
            "") : ;;
            *) printf '%sInvalid option: %s%s\n' "${C_YELLOW:-}" "$choice" "${C_RESET:-}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Initialize colors (honoring --no-color and NO_COLOR).
    if (( OPT_NOCOLOR )); then
        colors_init --disable
    else
        colors_init
    fi

    # Export the resolved output path for the report layer.
    export LDT_OUTPUT

    # Non-interactive modes.
    if (( OPT_FULL || OPT_REPORT )); then
        reset_state
        run_all
        if (( OPT_REPORT )); then
            do_report || exit 1
        fi
        return 0
    fi

    # Interactive mode.
    interactive_menu
    return 0
}

main "$@"
