#!/usr/bin/env bash
#
# modules/cpu.sh - CPU information and load analysis.
#
# Uses /proc/cpuinfo, /proc/loadavg and nproc. Read-only.

# _cpu_model - best-effort CPU model string.
_cpu_model() {
    if has_file /proc/cpuinfo; then
        local model
        model="$(awk -F: '/^[[:space:]]*model name/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
        if [[ -n "$model" ]]; then
            printf '%s\n' "$model"
            return 0
        fi
        # ARM / other architectures.
        model="$(awk -F: '
            /^[[:space:]]*Hardware/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}
            /^[[:space:]]*Model/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}
        ' /proc/cpuinfo)"
        if [[ -n "$model" ]]; then
            printf '%s\n' "$model"
            return 0
        fi
    fi
    printf 'unknown\n'
}

# _cpu_physical_cores - count unique (physical-id, core-id) pairs.
_cpu_physical_cores() {
    if ! has_file /proc/cpuinfo; then
        printf 'unknown\n'
        return 0
    fi
    local count
    count="$(awk -F: '
        /^[[:space:]]*physical id/ { pid=$2 }
        /^[[:space:]]*core id/     { gsub(/[[:space:]]/,"",pid); gsub(/[[:space:]]/,"",$2); print pid":"$2 }
    ' /proc/cpuinfo | sort -u | wc -l | tr -d ' ')"

    # Fallback: sockets * cores-per-socket when core id is unavailable.
    if [[ -z "$count" || "$count" == "0" ]]; then
        local sockets cores
        sockets="$(awk -F: '/^[[:space:]]*physical id/ {gsub(/[[:space:]]/,"",$2); print $2}' /proc/cpuinfo | sort -u | wc -l | tr -d ' ')"
        cores="$(awk -F: '/^[[:space:]]*cpu cores/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' /proc/cpuinfo)"
        if [[ -n "$cores" && "$cores" != "0" && -n "$sockets" && "$sockets" != "0" ]]; then
            printf '%d\n' "$(( sockets * cores ))"
            return 0
        fi
        printf 'unknown\n'
        return 0
    fi
    printf '%s\n' "$count"
}

# _cpu_logical_cores - count logical CPUs.
_cpu_logical_cores() {
    if has_cmd nproc; then
        local n
        n="$(nproc --all 2>/dev/null || nproc 2>/dev/null || true)"
        if [[ -n "$n" ]]; then
            printf '%s\n' "$n"
            return 0
        fi
    fi
    if has_file /proc/cpuinfo; then
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf 'unknown\n'
        return 0
    fi
    printf 'unknown\n'
}

# cpu_info - run the CPU diagnostic.
cpu_info() {
    section "3. CPU INFORMATION"

    local model phys logical arch
    model="$(_cpu_model)"
    phys="$(_cpu_physical_cores)"
    logical="$(_cpu_logical_cores)"
    arch="$(uname -m 2>/dev/null || printf 'unknown')"

    emit_kv "Model"            "$model"
    emit_kv "Architecture"     "$arch"
    emit_kv "Physical cores"   "$phys"
    emit_kv "Logical cores"    "$logical"

    mark_ran cpu
    data_set cpu.model "$model"
    data_set cpu.architecture "$arch"
    data_set cpu.physical_cores "$phys"
    data_set cpu.logical_cores "$logical"

    # Load average from /proc/loadavg.
    if has_file /proc/loadavg; then
        local l1 l5 l15 procs
        read -r l1 l5 l15 procs _ < /proc/loadavg
        emit_kv "Load average" "1m=${l1}  5m=${l5}  15m=${l15}"
        emit_kv "Processes"    "${procs} (runnable/total)"

        data_set cpu.load_1 "$l1"
        data_set cpu.load_5 "$l5"
        data_set cpu.load_15 "$l15"
        data_set cpu.procs_runnable "${procs%%/*}"
        data_set cpu.procs_total "${procs##*/}"

        # Warn when 1-minute load exceeds the number of logical cores.
        if is_number "$logical" && (( logical > 0 )); then
            local l1_int
            l1_int="${l1%.*}"
            if is_number "$l1_int" && (( l1_int > logical )); then
                emit_warn "High CPU load: 1m average ($l1) exceeds logical cores ($logical)."
                add_warning WARN "CPU load average ${l1} (1m) is above the number of logical cores (${logical})."
            else
                emit_ok "CPU load is within expected range."
            fi
        fi
    else
        emit_warn "/proc/loadavg is not available; load average skipped."
    fi
}
