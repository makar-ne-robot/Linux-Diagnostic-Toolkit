#!/usr/bin/env bash
#
# modules/memory.sh - RAM and swap usage analysis.
#
# Primary source is /proc/meminfo; `free` is used as an optional extra view.

# _meminfo_value KEY - print the kB value for KEY from /proc/meminfo.
_meminfo_value() {
    local key="$1"
    local file="${LDT_MEMINFO:-/proc/meminfo}"
    [[ -r "$file" ]] || return 1
    awk -v k="$key" '$1 == k":" { print $2; exit }' "$file"
}

# memory_info - run the memory diagnostic.
memory_info() {
    section "4. MEMORY INFORMATION"
    mark_ran memory

    local meminfo="${LDT_MEMINFO:-/proc/meminfo}"
    if ! has_file "$meminfo"; then
        emit_warn "/proc/meminfo is not available; memory diagnostics skipped."
        add_warning WARN "Memory information unavailable (/proc/meminfo missing)."
        return 0
    fi

    local total free avail buffers cached swap_total swap_free
    total="$(_meminfo_value MemTotal)"
    free="$(_meminfo_value MemFree)"
    avail="$(_meminfo_value MemAvailable)"
    buffers="$(_meminfo_value Buffers)"
    cached="$(_meminfo_value Cached)"
    swap_total="$(_meminfo_value SwapTotal)"
    swap_free="$(_meminfo_value SwapFree)"

    # MemAvailable may be missing on very old kernels; approximate it.
    if [[ -z "$avail" ]]; then
        avail=$(( ${free:-0} + ${buffers:-0} + ${cached:-0} ))
    fi

    if ! is_number "$total"; then
        emit_warn "Unable to parse memory totals."
        add_warning WARN "Memory totals could not be parsed from /proc/meminfo."
        return 0
    fi

    local used used_pct swap_used swap_pct
    used=$(( total - avail ))
    (( used < 0 )) && used=0
    used_pct="$(percent "$used" "$total")"

    emit_kv "Total RAM"     "$(human_kb "$total")"
    emit_kv "Used RAM"      "$(human_kb "$used")"
    emit_kv "Free RAM"      "$(human_kb "${free:-0}")"
    emit_kv "Available RAM" "$(human_kb "$avail")"
    emit_kv "RAM usage"     "${used_pct}%"

    data_set memory.total_kb "$total"
    data_set memory.used_kb "$used"
    data_set memory.free_kb "${free:-0}"
    data_set memory.available_kb "$avail"
    data_set memory.usage_percent "$used_pct"

    # Swap.
    if is_number "$swap_total" && (( swap_total > 0 )); then
        swap_used=$(( swap_total - ${swap_free:-0} ))
        (( swap_used < 0 )) && swap_used=0
        swap_pct="$(percent "$swap_used" "$swap_total")"
        emit_kv "Total swap" "$(human_kb "$swap_total")"
        emit_kv "Used swap"  "$(human_kb "$swap_used")"
        emit_kv "Swap usage" "${swap_pct}%"
        data_set memory.swap_total_kb "$swap_total"
        data_set memory.swap_used_kb "$swap_used"
        data_set memory.swap_percent "$swap_pct"
        if (( swap_pct >= 80 )); then
            emit_warn "High swap usage: ${swap_pct}%."
            add_warning WARN "Swap usage is high (${swap_pct}%)."
        fi
    else
        emit_kv "Swap" "not configured"
        data_set memory.swap_total_kb "0"
        data_set memory.swap_used_kb "0"
        data_set memory.swap_percent "0"
    fi

    # Threshold based evaluation.
    if (( used_pct >= 90 )); then
        emit_err "Critical memory usage: ${used_pct}%."
        add_warning CRIT "Memory usage is critically high (${used_pct}%)."
    elif (( used_pct >= 80 )); then
        emit_warn "High memory usage: ${used_pct}%."
        add_warning WARN "Memory usage is high (${used_pct}%)."
    else
        emit_ok "Memory usage is normal (${used_pct}%)."
    fi

    # Optional `free` snapshot for reference.
    if has_cmd free; then
        emit "" ""
        emit_muted "  free -h output:"
        local line
        while IFS= read -r line; do
            emit "" "  $line"
        done < <(free -h 2>/dev/null || true)
    fi
}
