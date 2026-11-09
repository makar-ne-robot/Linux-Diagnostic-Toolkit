#!/usr/bin/env bash
#
# main.sh - Linux Diagnostic Toolkit entry point.
#
# Interactive CLI + non-interactive flags for diagnosing a Linux system and
# generating a plain-text (TXT) or JSON report. See README.md.
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
# shellcheck source=modules/temperature.sh
source "$SCRIPT_DIR/modules/temperature.sh"
# shellcheck source=modules/battery.sh
source "$SCRIPT_DIR/modules/battery.sh"

# ---------------------------------------------------------------------------
# CLI options (defaults).
#   LDT_OUTPUT honours the environment but is overridden by --output.
# ---------------------------------------------------------------------------
OPT_FULL=0
OPT_REPORT=0
OPT_JSON=0
OPT_NOCOLOR=0
LDT_OUTPUT="${LDT_OUTPUT:-}"
# Selected individual modules (canonical names), empty means "not selected".
declare -a SELECTED_MODULES=()

# Canonical module execution order (also the report section order).
declare -a _MODULE_ORDER=(system cpu memory disk services network temperature battery)

# ---------------------------------------------------------------------------
# Usage / version.
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${LDT_NAME} v${LDT_VERSION}

A safe, read-only CLI utility for diagnosing Linux system health and
producing TXT or JSON reports.

USAGE:
    ./main.sh [OPTIONS]

DIAGNOSTIC SCOPE:
    --full            Run the complete diagnostic suite.
    --system          Run only the system-information module.
    --cpu             Run only the CPU module.
    --memory          Run only the memory module.
    --disk            Run only the disk module.
    --services        Run only the services module.
    --network         Run only the network module.
    --temperature     Run only the CPU temperature module.
    --battery         Run only the battery module.
    (Module flags can be combined, e.g. --disk --memory.)

OUTPUT:
    --report          Run diagnostics and write a report.
    --json            Write the report as JSON (implies --report).
    --output PATH     Write the report to PATH (implies --report).
                      If PATH is a directory, the default timestamped
                      filename is created inside it. Supports spaces.
    --no-color        Disable ANSI colored output.
    -h, --help        Show this help and exit.
    -v, --version     Show version and exit.

EXAMPLES:
    ./main.sh
    ./main.sh --full
    ./main.sh --full --report
    ./main.sh --full --json
    ./main.sh --full --json --output ./report.json
    ./main.sh --disk --memory
    ./main.sh --cpu --temperature
    ./main.sh --full --output ./my-report.txt
    ./main.sh --full --no-color

ENVIRONMENT:
    NO_COLOR       If set (non-empty), disables colors.
    LDT_OUTPUT     Default report path (overridden by --output).
    LDT_TEMP_WARN  Temperature warning threshold in C (default 75).
    LDT_TEMP_CRIT  Temperature critical threshold in C (default 90).
EOF
}

show_version() {
    printf '%s %s\n' "$LDT_NAME" "$LDT_VERSION"
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
# _require_path ARG - validate that an --output argument is non-empty.
_require_path() {
    local value="$1"
    if [[ -z "$value" ]]; then
        printf 'Error: --output requires a non-empty path.\n' >&2
        exit 2
    fi
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --full)        OPT_FULL=1 ;;
            --report)      OPT_REPORT=1 ;;
            --json)        OPT_JSON=1; OPT_REPORT=1 ;;
            --no-color)    OPT_NOCOLOR=1 ;;
            --system)      SELECTED_MODULES+=(system) ;;
            --cpu)         SELECTED_MODULES+=(cpu) ;;
            --memory)      SELECTED_MODULES+=(memory) ;;
            --disk)        SELECTED_MODULES+=(disk) ;;
            --services)    SELECTED_MODULES+=(services) ;;
            --network)     SELECTED_MODULES+=(network) ;;
            --temperature) SELECTED_MODULES+=(temperature) ;;
            --battery)     SELECTED_MODULES+=(battery) ;;
            --output)
                shift
                if [[ $# -eq 0 ]]; then
                    printf 'Error: --output requires a path argument.\n' >&2
                    exit 2
                fi
                _require_path "$1"
                LDT_OUTPUT="$1"
                OPT_REPORT=1
                ;;
            --output=*)
                _require_path "${1#--output=}"
                LDT_OUTPUT="${1#--output=}"
                OPT_REPORT=1
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

    # A non-empty output path implies report generation.
    if [[ -n "$LDT_OUTPUT" ]]; then
        OPT_REPORT=1
    fi
}

# ---------------------------------------------------------------------------
# Diagnostic runners.
# ---------------------------------------------------------------------------
# _run_one MODULE - dispatch a single module by canonical name.
_run_one() {
    case "$1" in
        system)      system_info ;;
        cpu)         cpu_info ;;
        memory)      memory_info ;;
        disk)        disk_check ;;
        services)    services_check ;;
        network)     network_check ;;
        temperature) temperature_check ;;
        battery)     battery_check ;;
    esac
}

# run_modules MODULE... - run the requested modules in canonical order,
# skipping duplicates. Uses the report section order for stable output.
run_modules() {
    local m sel
    for m in "${_MODULE_ORDER[@]}"; do
        for sel in "$@"; do
            if [[ "$sel" == "$m" ]]; then
                _run_one "$m"
                break
            fi
        done
    done
}

# run_all - run every diagnostic module.
run_all() {
    run_modules "${_MODULE_ORDER[@]}"
}

# do_report - write the report (TXT or JSON) from the current buffer.
do_report() {
    local path
    if (( OPT_JSON )); then
        path="$(report_write_json 2>/dev/null)" || {
            printf '%sFailed to write JSON report.%s\n' "${C_RED:-}" "${C_RESET:-}" >&2
            return 1
        }
    else
        path="$(report_write 2>/dev/null)" || {
            printf '%sFailed to write report.%s\n' "${C_RED:-}" "${C_RESET:-}" >&2
            return 1
        }
    fi
    printf '\n%sReport saved:%s %s\n' "${C_GREEN:-}" "${C_RESET:-}" "$path"
    return 0
}

# ---------------------------------------------------------------------------
# Interactive menu.
# ---------------------------------------------------------------------------
menu_disk()       { disk_check; }
menu_cpu()        { cpu_info; }
menu_memory()     { memory_info; }
menu_services()   { services_check; }
menu_network()    { network_check; }
menu_system()     { system_info; }
menu_temperature(){ temperature_check; }
menu_battery()    { battery_check; }

interactive_menu() {
    print_banner
    while true; do
        printf '\n'
        printf '%s[1]%s Full system diagnostics\n'      "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[2]%s Disk diagnostics\n'             "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[3]%s CPU diagnostics\n'              "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[4]%s Memory diagnostics\n'           "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[5]%s Services diagnostics\n'         "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[6]%s Network diagnostics\n'          "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[7]%s System information\n'           "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[8]%s CPU temperature\n'              "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[9]%s Battery diagnostics\n'          "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[10]%s Generate diagnostic report\n'  "${C_CYAN:-}" "${C_RESET:-}"
        printf '%s[11]%s Exit\n'                        "${C_CYAN:-}" "${C_RESET:-}"
        printf '\nSelect an option: '

        local choice
        if ! IFS= read -r choice; then
            # EOF (e.g. piped input): exit gracefully.
            printf '\n'
            break
        fi

        case "$choice" in
            1) reset_state; run_all; print_summary_box ;;
            2) menu_disk ;;
            3) menu_cpu ;;
            4) menu_memory ;;
            5) menu_services ;;
            6) menu_network ;;
            7) menu_system ;;
            8) menu_temperature ;;
            9) menu_battery ;;
            10)
                # If nothing has been collected yet, run a full pass first.
                if (( ${#REPORT_BUF[@]} == 0 )); then
                    reset_state
                    run_all
                    print_summary_box
                fi
                do_report
                ;;
            11|q|quit|exit) break ;;
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

    # Initialize colors (honoring --no-color, NO_COLOR and non-TTY output).
    if (( OPT_NOCOLOR )); then
        colors_init --disable
    else
        colors_init
    fi

    # Export the resolved output path for the report layer.
    export LDT_OUTPUT

    # Decide whether a non-interactive run was requested.
    local noninteractive=0
    if (( OPT_FULL || OPT_REPORT )) || (( ${#SELECTED_MODULES[@]} > 0 )); then
        noninteractive=1
    fi

    if (( noninteractive )); then
        reset_state
        if (( OPT_FULL )) || (( ${#SELECTED_MODULES[@]} == 0 )); then
            run_all
        else
            run_modules "${SELECTED_MODULES[@]}"
        fi

        print_summary_box

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
