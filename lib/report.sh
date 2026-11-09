#!/usr/bin/env bash
#
# lib/report.sh - Diagnostic report generation.
#
# The report is plain text (TXT). Individual diagnostic modules append plain
# lines to REPORT_BUF via emit(); this file assembles the final document with a
# header, the collected body, the warnings section and an overall score.
#
# Default output directory is <project>/reports/. A caller may override the
# exact file through LDT_OUTPUT (see main.sh --output).

# report_default_dir - print the default reports directory.
report_default_dir() {
    printf '%s/reports\n' "${SCRIPT_DIR:-.}"
}

# report_default_filename - print the timestamped default filename.
report_default_filename() {
    printf 'linux-diagnostic-report-%s.txt\n' "$(date +%Y-%m-%d_%H-%M-%S)"
}

# report_resolve_path - determine the final report file path.
# Honors LDT_OUTPUT: if it points to an existing directory the default filename
# is placed inside it; otherwise it is used as the exact file path.
report_resolve_path() {
    local output="${LDT_OUTPUT:-}"
    local dir filename

    if [[ -z "$output" ]]; then
        dir="$(report_default_dir)"
        filename="$(report_default_filename)"
        printf '%s/%s\n' "$dir" "$filename"
        return 0
    fi

    if [[ -d "$output" ]]; then
        printf '%s/%s\n' "${output%/}" "$(report_default_filename)"
    else
        printf '%s\n' "$output"
    fi
}

# compute_score - integer health score 0..100 derived from findings.
compute_score() {
    local score=100
    score=$(( score - WARN_COUNT * 5 - CRIT_COUNT * 20 ))
    (( score < 0 )) && score=0
    printf '%d\n' "$score"
}

# score_status SCORE - print a human readable status label.
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

# _report_header - emit the report document header.
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

# _report_warnings - print the warnings section.
_report_warnings() {
    echo ""
    echo "=============================================================================="
    echo "8. WARNINGS"
    echo "=============================================================================="
    if (( ${#WARNINGS[@]} == 0 )); then
        echo "No warnings detected. System looks healthy."
        return 0
    fi
    local entry level message
    for entry in "${WARNINGS[@]}"; do
        level="${entry%%|*}"
        message="${entry#*|}"
        if [[ "$level" == "CRIT" ]]; then
            printf '[CRITICAL] %s\n' "$message"
        else
            printf '[WARNING]  %s\n' "$message"
        fi
    done
}

# _report_summary - print the overall assessment section.
_report_summary() {
    local score status
    score="$(compute_score)"
    status="$(score_status "$score")"
    echo ""
    echo "=============================================================================="
    echo "9. OVERALL ASSESSMENT"
    echo "=============================================================================="
    printf 'Warnings : %d\n' "$WARN_COUNT"
    printf 'Critical : %d\n' "$CRIT_COUNT"
    printf 'Health   : %d/100 (%s)\n' "$score" "$status"
    echo ""
    case "$status" in
        GOOD)     echo "Result: System appears healthy. No action required." ;;
        FAIR)     echo "Result: Minor issues detected. Review the warnings above." ;;
        DEGRADED) echo "Result: Several issues detected. Investigation recommended." ;;
        CRITICAL) echo "Result: Critical issues detected. Immediate attention advised." ;;
    esac
}

# report_write [PATH] - write the full report to PATH (or the resolved default).
report_write() {
    local file="${1:-}"
    [[ -z "$file" ]] && file="$(report_resolve_path)"

    local dir
    dir="$(dirname -- "$file")"
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        printf 'Error: cannot create report directory: %s\n' "$dir" >&2
        return 1
    fi

    if ! {
        _report_header
        local line
        for line in "${REPORT_BUF[@]}"; do
            printf '%s\n' "$line"
        done
        _report_warnings
        _report_summary
    } > "$file" 2>/dev/null; then
        printf 'Error: cannot write report: %s\n' "$file" >&2
        return 1
    fi

    printf '%s\n' "$file"
    return 0
}
