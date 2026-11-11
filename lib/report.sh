#!/usr/bin/env bash
#
# lib/report.sh - Diagnostic report generation (TXT and JSON).
#
# Diagnostic modules append human-readable lines to REPORT_BUF and structured
# values to the LDT_DATA store / list arrays (see lib/utils.sh). This file
# assembles those into either a plain-text (TXT) document or a JSON document,
# and computes the heuristic health score.
#
# Default output directory is <project>/reports/. A caller may override the
# exact file through LDT_OUTPUT (see main.sh --output).

# ---------------------------------------------------------------------------
# Path / filename helpers
# ---------------------------------------------------------------------------
# report_default_dir - print the default reports directory.
report_default_dir() {
    printf '%s/reports\n' "${SCRIPT_DIR:-.}"
}

# report_default_filename_ext EXT - print the timestamped filename with EXT.
report_default_filename_ext() {
    printf 'linux-diagnostic-report-%s.%s\n' "$(date +%Y-%m-%d_%H-%M-%S)" "$1"
}

# report_default_filename - print the timestamped TXT filename.
report_default_filename() {
    report_default_filename_ext txt
}

# _resolve_output EXT - shared resolver for the report file path.
# If LDT_OUTPUT points to an existing directory the default filename is placed
# inside it; otherwise it is used as the exact file path.
_resolve_output() {
    local ext="$1"
    local output="${LDT_OUTPUT:-}"

    if [[ -z "$output" ]]; then
        printf '%s/%s\n' "$(report_default_dir)" "$(report_default_filename_ext "$ext")"
        return 0
    fi
    if [[ -d "$output" ]]; then
        printf '%s/%s\n' "${output%/}" "$(report_default_filename_ext "$ext")"
    else
        printf '%s\n' "$output"
    fi
}

# report_resolve_path - resolve the TXT report path.
report_resolve_path() {
    _resolve_output txt
}

# report_resolve_path_json - resolve the JSON report path.
report_resolve_path_json() {
    _resolve_output json
}

# _prepare_target FILE - create parent dirs and warn before overwriting.
# Never overwrites silently: an explicit notice is printed to stderr.
_prepare_target() {
    local file="$1"
    local dir
    dir="$(dirname -- "$file")"
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        printf 'Error: cannot create report directory: %s\n' "$dir" >&2
        return 1
    fi
    if [[ -e "$file" ]]; then
        printf 'Notice: overwriting existing file: %s\n' "$file" >&2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Health score (heuristic)
# ---------------------------------------------------------------------------
# compute_score - integer heuristic score 0..100 derived from findings.
# WARN costs 5 points, CRIT costs 20. INFO findings do not affect the score.
compute_score() {
    local score=100
    score=$(( score - WARN_COUNT * 5 - CRIT_COUNT * 20 ))
    (( score < 0 )) && score=0
    printf '%d\n' "$score"
}

# score_status SCORE - legacy numeric-tier label (kept for compatibility).
score_status() {
    local score="$1"
    if (( score >= 90 )); then
        printf 'GOOD'
    elif (( score >= 70 )); then
        printf 'FAIR'
    elif (( score >= 40 )); then
        printf 'DEGRADED'
    else
        printf 'CRITICAL'
    fi
}

# health_status - HEALTHY / WARNING / CRITICAL / UNKNOWN based on findings.
# Returns UNKNOWN when no diagnostic section produced any data.
health_status() {
    if (( ${#LDT_RAN[@]} == 0 )); then
        printf 'UNKNOWN'
        return 0
    fi
    if (( CRIT_COUNT > 0 )); then
        printf 'CRITICAL'
        return 0
    fi
    if (( WARN_COUNT > 0 )); then
        printf 'WARNING'
        return 0
    fi
    printf 'HEALTHY'
}

# health_explanation - the required heuristic disclaimer.
health_explanation() {
    printf 'Health Score is a heuristic indicator based on detected diagnostic warnings. It is not an objective measurement of hardware health or overall system reliability.'
}

# ---------------------------------------------------------------------------
# Per-area status (used by the summary box and JSON)
# ---------------------------------------------------------------------------
# _area_disk_status - OK / WARNING / CRITICAL / UNKNOWN for the disk area.
_area_disk_status() {
    has_ran disk || { printf 'UNKNOWN'; return 0; }
    if (( ${#DISK_ROWS[@]} == 0 && ${#INODE_ROWS[@]} == 0 )); then
        printf 'UNKNOWN'; return 0
    fi
    local row pct max=0
    for row in "${DISK_ROWS[@]}"; do
        IFS='|' read -r _ _ _ _ pct _ <<< "$row"
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        (( pct > max )) && max=$pct
    done
    for row in "${INODE_ROWS[@]}"; do
        IFS='|' read -r _ pct _ <<< "$row"
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        (( pct > max )) && max=$pct
    done
    if (( max >= 90 )); then
        printf 'CRITICAL'
    elif (( max >= 80 )); then
        printf 'WARNING'
    else
        printf 'OK'
    fi
}

# _area_memory_status - status for the memory area.
_area_memory_status() {
    has_ran memory || { printf 'UNKNOWN'; return 0; }
    local pct
    pct="$(data_get memory.usage_percent)"
    if ! [[ "$pct" =~ ^[0-9]+$ ]]; then
        printf 'UNKNOWN'; return 0
    fi
    if (( pct >= 90 )); then
        printf 'CRITICAL'
    elif (( pct >= 80 )); then
        printf 'WARNING'
    else
        printf 'OK'
    fi
}

# _area_services_status - status for the services area.
_area_services_status() {
    has_ran services || { printf 'UNKNOWN'; return 0; }
    local failed
    failed="$(data_get services.failed)"
    if ! [[ "$failed" =~ ^[0-9]+$ ]]; then
        printf 'UNKNOWN'; return 0
    fi
    if (( failed > 0 )); then
        printf 'WARNING'
    else
        printf 'OK'
    fi
}

# _net_state_label VALUE - map an internal probe state to a label.
# 1 -> ok, 0 -> failed, disabled -> disabled, anything else -> skipped.
_net_state_label() {
    case "$1" in
        1)        printf 'ok' ;;
        0)        printf 'failed' ;;
        disabled) printf 'disabled' ;;
        *)        printf 'skipped' ;;
    esac
}

# _area_network_status - status for the network area.
# Distinguishes "verified OK", "verified problem" and "could not verify":
#   * any verified problem (failed probe, missing route/interfaces) -> WARNING
#   * otherwise, any unverifiable check (missing tool, no timeout) -> UNKNOWN
#   * OK is returned only when the required checks ran and found no problem.
# User-disabled probes (--no-network-probes) are intentionally skipped and do
# not, by themselves, degrade the status.
_area_network_status() {
    has_ran network || { printf 'UNKNOWN'; return 0; }

    local has_ip
    has_ip="$(data_get network.has_ip_tool)"
    if (( ${#NET_IFACES[@]} == 0 )) && [[ "$has_ip" != "1" ]]; then
        printf 'UNKNOWN'; return 0
    fi

    local problem=0 unknown=0

    # Interfaces: no interfaces at all is a problem when we can enumerate them.
    if (( ${#NET_IFACES[@]} == 0 )); then
        problem=1
    fi

    # Default route: only verifiable when the `ip` tool is available.
    if [[ "$has_ip" == "1" ]]; then
        [[ -n "$(data_get network.default_route)" ]] || problem=1
    else
        unknown=1
    fi

    # External probes.
    local flag val
    for flag in network.dns_resolution network.external_reachable; do
        val="$(data_get "$flag")"
        case "$val" in
            1)        : ;;         # verified OK
            0)        problem=1 ;; # verified failure
            disabled) : ;;         # user opted out
            *)        unknown=1 ;; # not verified
        esac
    done

    if (( problem )); then
        printf 'WARNING'
    elif (( unknown )); then
        printf 'UNKNOWN'
    else
        printf 'OK'
    fi
}

# _area_system_status - status for the general system area.
_area_system_status() {
    has_ran system || { printf 'UNKNOWN'; return 0; }
    if [[ -n "$(data_get system.kernel)" ]]; then
        printf 'OK'
    else
        printf 'UNKNOWN'
    fi
}

# _area_temperature_status / _area_battery_status - availability labels.
_area_temperature_status() {
    has_ran temperature || { printf 'UNKNOWN'; return 0; }
    case "$(data_get temperature.available)" in
        1) printf 'AVAILABLE' ;;
        0) printf 'UNAVAILABLE' ;;
        *) printf 'UNKNOWN' ;;
    esac
}

_area_battery_status() {
    has_ran battery || { printf 'UNKNOWN'; return 0; }
    case "$(data_get battery.available)" in
        1) printf 'AVAILABLE' ;;
        0) printf 'NOT PRESENT' ;;
        *) printf 'UNKNOWN' ;;
    esac
}

# ---------------------------------------------------------------------------
# Summary box (terminal only)
# ---------------------------------------------------------------------------
# Fixed inner width so the box stays aligned with or without colors.
# Layout between the "|" borders: " " + label(20) + ": " + value(12) = 35.
_SUMMARY_WIDTH=35

_summary_border() {
    local fill="" i
    for (( i = 0; i < _SUMMARY_WIDTH; i++ )); do
        fill+="-"
    done
    printf '+%s+\n' "$fill"
}

# _summary_row LABEL VALUE - print one aligned "| label : value |" row.
_summary_row() {
    printf '| %-20s: %-12s|\n' "$1" "$2"
}

# _summary_title TEXT - print a centered title row (no colon).
_summary_title() {
    local text="$1"
    local len=${#text}
    local left=$(( (_SUMMARY_WIDTH - len) / 2 ))
    local right=$(( _SUMMARY_WIDTH - len - left ))
    printf '|%*s%s%*s|\n' "$left" "" "$text" "$right" ""
}

# print_summary_box - print the DIAGNOSTIC SUMMARY box (terminal output only,
# deliberately not added to the report buffer). Colors are applied to the whole
# box based on the overall status and degrade to plain text when disabled.
print_summary_box() {
    local overall score color
    overall="$(health_status)"
    score="$(compute_score)"
    case "$overall" in
        HEALTHY)  color="${C_GREEN:-}" ;;
        WARNING)  color="${C_YELLOW:-}" ;;
        CRITICAL) color="${C_RED:-}" ;;
        *)        color="${C_DIM:-}" ;;
    esac

    printf '\n%s' "$color"
    _summary_border
    _summary_title "DIAGNOSTIC SUMMARY"
    _summary_border
    _summary_row "System status" "$(_area_system_status)"
    _summary_row "Disk usage"    "$(_area_disk_status)"
    _summary_row "Memory usage"  "$(_area_memory_status)"
    _summary_row "Services"      "$(_area_services_status)"
    _summary_row "Network"       "$(_area_network_status)"
    _summary_row "Temperature"   "$(_area_temperature_status)"
    _summary_row "Battery"       "$(_area_battery_status)"
    _summary_border
    _summary_row "Health Score"  "${score}/100"
    _summary_border
    printf '%s' "${C_RESET:-}"
}

# ---------------------------------------------------------------------------
# TXT report
# ---------------------------------------------------------------------------
_report_header() {
    local host kernel
    host="$(get_hostname)"
    kernel="$(uname -sr 2>/dev/null || printf 'unknown')"
    cat <<EOF
==============================================================================
                  ${LDT_NAME} - DIAGNOSTIC REPORT
                            version ${LDT_VERSION}
==============================================================================
Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')
Hostname  : ${host}
Kernel    : ${kernel}
Tool      : ${LDT_NAME} ${LDT_VERSION}
EOF
}

_report_warnings() {
    echo ""
    echo "=============================================================================="
    echo "10. WARNINGS"
    echo "=============================================================================="
    if (( ${#WARNINGS[@]} == 0 )); then
        echo "No warnings detected."
        return 0
    fi
    local entry level message
    for entry in "${WARNINGS[@]}"; do
        level="${entry%%|*}"
        message="${entry#*|}"
        case "$level" in
            CRIT) printf '[CRITICAL] %s\n' "$message" ;;
            WARN) printf '[WARNING]  %s\n' "$message" ;;
            INFO) printf '[INFO]     %s\n' "$message" ;;
            *)    printf '[WARNING]  %s\n' "$message" ;;
        esac
    done
}

_report_summary() {
    local score overall
    score="$(compute_score)"
    overall="$(health_status)"
    echo ""
    echo "=============================================================================="
    echo "11. OVERALL ASSESSMENT"
    echo "=============================================================================="
    printf 'Informational : %d\n' "$((${#WARNINGS[@]} - WARN_COUNT - CRIT_COUNT))"
    printf 'Warnings      : %d\n' "$WARN_COUNT"
    printf 'Critical      : %d\n' "$CRIT_COUNT"
    printf 'Health Score  : %d/100 (heuristic)\n' "$score"
    printf 'Status        : %s\n' "$overall"
    echo ""
    echo "Note: $(health_explanation)"
    echo ""
    case "$overall" in
        HEALTHY)  echo "Result: System appears healthy. No action required." ;;
        WARNING)  echo "Result: Minor issues detected. Review the warnings above." ;;
        CRITICAL) echo "Result: Critical issues detected. Immediate attention advised." ;;
        *)        echo "Result: Not enough diagnostic data to assess system health." ;;
    esac
}

# report_write [PATH] - write the TXT report to PATH (or the resolved default).
report_write() {
    local file="${1:-}"
    [[ -z "$file" ]] && file="$(report_resolve_path)"

    _prepare_target "$file" || return 1

    {
        _report_header
        local line
        for line in "${REPORT_BUF[@]}"; do
            printf '%s\n' "$line"
        done
        _report_warnings
        _report_summary
    } > "$file" 2>/dev/null

    # NOTE: bash mis-evaluates `if ! { ...; } > file` when the redirection
    # itself fails (it reports success). Capture the status explicitly.
    # shellcheck disable=SC2181
    if (( $? != 0 )); then
        printf 'Error: cannot write report: %s\n' "$file" >&2
        return 1
    fi

    printf '%s\n' "$file"
    return 0
}

# ---------------------------------------------------------------------------
# JSON export
# ---------------------------------------------------------------------------
# json_escape STR - escape a string for safe embedding in JSON.
json_escape() {
    local s="$1"
    local out="" i ch code hex
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:i:1}"
        printf -v code '%d' "'$ch" 2>/dev/null || code=32
        if (( code == 92 )); then          # backslash
            out+="\\\\"
        elif (( code == 34 )); then        # double quote
            out+="\\\""
        elif (( code < 32 )); then         # other control characters
            printf -v hex '%04x' "$code"
            out+="\\u${hex}"
        else
            out+="$ch"
        fi
    done
    printf '%s' "$out"
}

# json_str / json_str_or_null / json_num_or_null / json_bool_or_null
json_str() {
    printf '"%s"' "$(json_escape "$1")"
}
json_str_or_null() {
    if [[ -z "${1:-}" ]]; then
        printf 'null'
    else
        json_str "$1"
    fi
}
json_num_or_null() {
    if [[ "${1:-}" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}
json_float_or_null() {
    if [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}
json_bool_or_null() {
    case "${1:-}" in
        1) printf 'true' ;;
        0) printf 'false' ;;
        *) printf 'null' ;;
    esac
}

# _json_kv_str KEY VALUE - emit a "key": "value" pair (value always a string).
_json_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_json_document() {
    local line row i n

    # ----- tool -----
    printf '{\n'
    printf '  "tool": { "name": %s, "version": %s },\n' \
        "$(json_str "$LDT_NAME")" "$(json_str "$LDT_VERSION")"
    printf '  "timestamp": %s,\n' "$(json_str "$(_json_ts)")"
    printf '  "timestamp_local": %s,\n' "$(json_str "$(date '+%Y-%m-%d %H:%M:%S %Z')")"

    # ----- system -----
    printf '  "system": {\n'
    printf '    "distribution": %s,\n' "$(json_str_or_null "$(data_get system.distribution)")"
    printf '    "os_version": %s,\n'   "$(json_str_or_null "$(data_get system.os_version)")"
    printf '    "kernel": %s,\n'       "$(json_str_or_null "$(data_get system.kernel)")"
    printf '    "architecture": %s,\n' "$(json_str_or_null "$(data_get system.architecture)")"
    printf '    "hostname": %s,\n'     "$(json_str_or_null "$(data_get system.hostname)")"
    printf '    "uptime": %s,\n'       "$(json_str_or_null "$(data_get system.uptime)")"
    printf '    "init_system": %s\n'   "$(json_str_or_null "$(data_get system.init_system)")"
    printf '  },\n'

    # ----- cpu -----
    printf '  "cpu": {\n'
    printf '    "model": %s,\n'          "$(json_str_or_null "$(data_get cpu.model)")"
    printf '    "architecture": %s,\n'   "$(json_str_or_null "$(data_get cpu.architecture)")"
    printf '    "physical_cores": %s,\n' "$(json_num_or_null "$(data_get cpu.physical_cores)")"
    printf '    "logical_cores": %s,\n'  "$(json_num_or_null "$(data_get cpu.logical_cores)")"
    printf '    "load_average": { "1min": %s, "5min": %s, "15min": %s },\n' \
        "$(json_float_or_null "$(data_get cpu.load_1)")" \
        "$(json_float_or_null "$(data_get cpu.load_5)")" \
        "$(json_float_or_null "$(data_get cpu.load_15)")"
    printf '    "processes": { "runnable": %s, "total": %s }\n' \
        "$(json_num_or_null "$(data_get cpu.procs_runnable)")" \
        "$(json_num_or_null "$(data_get cpu.procs_total)")"
    printf '  },\n'

    # ----- memory -----
    printf '  "memory": {\n'
    printf '    "total_kb": %s,\n'     "$(json_num_or_null "$(data_get memory.total_kb)")"
    printf '    "used_kb": %s,\n'      "$(json_num_or_null "$(data_get memory.used_kb)")"
    printf '    "free_kb": %s,\n'      "$(json_num_or_null "$(data_get memory.free_kb)")"
    printf '    "available_kb": %s,\n' "$(json_num_or_null "$(data_get memory.available_kb)")"
    printf '    "usage_percent": %s,\n' "$(json_num_or_null "$(data_get memory.usage_percent)")"
    printf '    "swap_total_kb": %s,\n' "$(json_num_or_null "$(data_get memory.swap_total_kb)")"
    printf '    "swap_used_kb": %s,\n'  "$(json_num_or_null "$(data_get memory.swap_used_kb)")"
    printf '    "swap_percent": %s\n'   "$(json_num_or_null "$(data_get memory.swap_percent)")"
    printf '  },\n'

    # ----- disk -----
    printf '  "disk": {\n'
    printf '    "filesystems": ['
    n=${#DISK_ROWS[@]}
    for (( i = 0; i < n; i++ )); do
        row="${DISK_ROWS[$i]}"
        IFS='|' read -r fs size used avail pct mount <<< "$row"
        (( i > 0 )) && printf ','
        printf '\n      { "filesystem": %s, "size_kb": %s, "used_kb": %s, "available_kb": %s, "use_percent": %s, "mount": %s }' \
            "$(json_str_or_null "$fs")" "$(json_num_or_null "$size")" "$(json_num_or_null "$used")" \
            "$(json_num_or_null "$avail")" "$(json_num_or_null "$pct")" "$(json_str_or_null "$mount")"
    done
    (( n > 0 )) && printf '\n    '
    printf '],\n'
    printf '    "inodes": ['
    n=${#INODE_ROWS[@]}
    for (( i = 0; i < n; i++ )); do
        row="${INODE_ROWS[$i]}"
        IFS='|' read -r fs pct mount <<< "$row"
        (( i > 0 )) && printf ','
        printf '\n      { "filesystem": %s, "use_percent": %s, "mount": %s }' \
            "$(json_str_or_null "$fs")" "$(json_num_or_null "$pct")" "$(json_str_or_null "$mount")"
    done
    (( n > 0 )) && printf '\n    '
    printf ']\n'
    printf '  },\n'

    # ----- services -----
    printf '  "services": {\n'
    printf '    "init_system": %s,\n'    "$(json_str_or_null "$(data_get services.init_system)")"
    printf '    "manager_state": %s,\n'  "$(json_str_or_null "$(data_get services.manager_state)")"
    printf '    "total": %s,\n'          "$(json_num_or_null "$(data_get services.total)")"
    printf '    "running": %s,\n'        "$(json_num_or_null "$(data_get services.running)")"
    printf '    "failed": %s,\n'         "$(json_num_or_null "$(data_get services.failed)")"
    printf '    "failed_units": ['
    n=${#SVC_FAILED_LIST[@]}
    for (( i = 0; i < n; i++ )); do
        (( i > 0 )) && printf ', '
        printf '%s' "$(json_str "${SVC_FAILED_LIST[$i]}")"
    done
    printf ']\n'
    printf '  },\n'

    # ----- network -----
    printf '  "network": {\n'
    printf '    "interfaces": ['
    n=${#NET_IFACES[@]}
    for (( i = 0; i < n; i++ )); do
        row="${NET_IFACES[$i]}"
        IFS='|' read -r name state v4 v6 <<< "$row"
        (( i > 0 )) && printf ','
        printf '\n      { "name": %s, "state": %s, "ipv4": %s, "ipv6": %s }' \
            "$(json_str_or_null "$name")" "$(json_str_or_null "$state")" \
            "$(json_str_or_null "$v4")" "$(json_str_or_null "$v6")"
    done
    (( n > 0 )) && printf '\n    '
    printf '],\n'
    printf '    "probes_enabled": %s,\n' "$(json_bool_or_null "$(data_get network.probes_enabled)")"
    printf '    "default_route": %s,\n' "$(json_str_or_null "$(data_get network.default_route)")"
    printf '    "dns_servers": ['
    n=${#NET_DNS_LIST[@]}
    for (( i = 0; i < n; i++ )); do
        (( i > 0 )) && printf ', '
        printf '%s' "$(json_str "${NET_DNS_LIST[$i]}")"
    done
    printf '],\n'
    printf '    "dns_resolution": %s,\n' "$(json_bool_or_null "$(data_get network.dns_resolution)")"
    printf '    "dns_probe": %s,\n' "$(json_str "$(_net_state_label "$(data_get network.dns_resolution)")")"
    printf '    "external_reachable": %s,\n' "$(json_bool_or_null "$(data_get network.external_reachable)")"
    printf '    "external_probe": %s\n' "$(json_str "$(_net_state_label "$(data_get network.external_reachable)")")"
    printf '  },\n'

    # ----- temperature -----
    printf '  "temperature": {\n'
    printf '    "available": %s,\n' "$(json_bool_or_null "$(data_get temperature.available)")"
    printf '    "unit": "C",\n'
    printf '    "warn_threshold": %s,\n' "$(json_num_or_null "$(data_get temperature.warn_threshold)")"
    printf '    "crit_threshold": %s,\n' "$(json_num_or_null "$(data_get temperature.crit_threshold)")"
    printf '    "sensors": ['
    n=${#TEMP_ROWS[@]}
    for (( i = 0; i < n; i++ )); do
        row="${TEMP_ROWS[$i]}"
        IFS='|' read -r name value <<< "$row"
        (( i > 0 )) && printf ','
        printf '\n      { "name": %s, "value_c": %s }' \
            "$(json_str_or_null "$name")" "$(json_float_or_null "$value")"
    done
    (( n > 0 )) && printf '\n    '
    printf ']\n'
    printf '  },\n'

    # ----- battery -----
    printf '  "battery": {\n'
    printf '    "available": %s,\n' "$(json_bool_or_null "$(data_get battery.available)")"
    printf '    "batteries": ['
    n=${#BATT_ROWS[@]}
    for (( i = 0; i < n; i++ )); do
        row="${BATT_ROWS[$i]}"
        IFS='|' read -r name capacity status <<< "$row"
        (( i > 0 )) && printf ','
        printf '\n      { "name": %s, "capacity_percent": %s, "status": %s }' \
            "$(json_str_or_null "$name")" "$(json_num_or_null "$capacity")" "$(json_str_or_null "$status")"
    done
    (( n > 0 )) && printf '\n    '
    printf ']\n'
    printf '  },\n'

    # ----- warnings -----
    printf '  "warnings": ['
    n=${#WARNINGS[@]}
    for (( i = 0; i < n; i++ )); do
        local entry="${WARNINGS[$i]}"
        local level="${entry%%|*}"
        local message="${entry#*|}"
        (( i > 0 )) && printf ','
        printf '\n    { "level": %s, "message": %s }' \
            "$(json_str "$level")" "$(json_str "$message")"
    done
    (( n > 0 )) && printf '\n  '
    printf '],\n'

    # ----- health score -----
    printf '  "health_score": {\n'
    printf '    "score": %s,\n' "$(json_num_or_null "$(compute_score)")"
    printf '    "type": "heuristic",\n'
    printf '    "status": %s,\n' "$(json_str "$(health_status)")"
    printf '    "warnings": %s,\n' "$(json_num_or_null "$WARN_COUNT")"
    printf '    "critical": %s,\n' "$(json_num_or_null "$CRIT_COUNT")"
    printf '    "explanation": %s\n' "$(json_str "$(health_explanation)")"
    printf '  }\n'
    printf '}\n'
}

# report_write_json [PATH] - write the JSON report to PATH.
report_write_json() {
    local file="${1:-}"
    [[ -z "$file" ]] && file="$(report_resolve_path_json)"

    _prepare_target "$file" || return 1

    { _json_document; } > "$file" 2>/dev/null

    # shellcheck disable=SC2181
    if (( $? != 0 )); then
        printf 'Error: cannot write JSON report: %s\n' "$file" >&2
        return 1
    fi

    printf '%s\n' "$file"
    return 0
}
