#!/usr/bin/env bash
#
# modules/services.sh - Init system / service health checks.
#
# Only queries state through systemctl; it never starts, stops, enables or
# otherwise modifies any unit.

# _detect_init - print the detected init system name.
_detect_init() {
    if [[ -d /run/systemd/system ]] && has_cmd systemctl; then
        printf 'systemd\n'
        return 0
    fi
    if [[ -r /proc/1/comm ]]; then
        local comm
        comm="$(cat /proc/1/comm 2>/dev/null || true)"
        case "$comm" in
            systemd) printf 'systemd\n' ;;
            init)    printf 'sysvinit\n' ;;
            openrc-init) printf 'openrc\n' ;;
            "")      printf 'unknown\n' ;;
            *)       printf '%s\n' "$comm" ;;
        esac
        return 0
    fi
    printf 'unknown\n'
}

# _services_systemd - systemd specific diagnostics.
_services_systemd() {
    if ! has_cmd systemctl; then
        emit_warn "'systemctl' is not available; cannot enumerate services."
        add_warning WARN "Service enumeration unavailable (systemctl missing)."
        return 0
    fi

    local running=0 failed=0 total=0
    local line state

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Columns: UNIT LOAD ACTIVE SUB DESCRIPTION
        # shellcheck disable=SC2086
        set -- $line
        state="${4:-}"
        total=$(( total + 1 ))
        if [[ "$state" == "running" ]]; then
            running=$(( running + 1 ))
        fi
    done < <(systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null || true)

    local failed_list
    failed_list="$(systemctl list-units --type=service --state=failed --no-legend --no-pager --plain 2>/dev/null || true)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        failed=$(( failed + 1 ))
    done <<< "$failed_list"

    emit_kv "Init system"      "systemd"
    emit_kv "Total services"   "$total"
    emit_kv "Running services" "$running"
    emit_kv "Failed services"  "$failed"

    # Overall systemd state, when available.
    if systemctl is-system-running >/dev/null 2>&1; then
        local sys_state
        sys_state="$(systemctl is-system-running 2>/dev/null || true)"
        [[ -n "$sys_state" ]] && emit_kv "System state" "$sys_state"
    fi

    if (( failed > 0 )); then
        emit_warn "$failed failed service(s) detected:"
        local u
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            emit_warn "  - $u"
        done <<< "$failed_list"
        add_warning WARN "$failed systemd service(s) are in a failed state."
    else
        emit_ok "No failed systemd services."
    fi
}

# _services_other INIT - fallback for non-systemd systems.
_services_other() {
    local init="$1"
    emit_kv "Init system" "$init"
    emit_info "Detailed service inspection is only supported on systemd."
    emit_info "No service state was modified."
}

# services_check - run the services diagnostic.
services_check() {
    section "6. SYSTEM SERVICES"

    local init
    init="$(_detect_init)"
    emit_kv "Detected init" "$init"

    if [[ "$init" == "systemd" ]]; then
        _services_systemd
    else
        _services_other "$init"
    fi
}
