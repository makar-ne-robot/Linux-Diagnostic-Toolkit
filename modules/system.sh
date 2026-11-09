#!/usr/bin/env bash
#
# modules/system.sh - General system / distribution information.
#
# Reads /etc/os-release, uname and the uptime data. Does not modify anything.

# _read_os_release KEY - print the value of KEY from an os-release file.
_read_os_release() {
    local key="$1"
    local file
    if [[ -n "${LDT_OS_RELEASE:-}" ]]; then
        # Explicit override (used by tests); no fallback.
        file="$LDT_OS_RELEASE"
    elif [[ -r /etc/os-release ]]; then
        file=/etc/os-release
    else
        file=/usr/lib/os-release
    fi
    [[ -r "$file" ]] || return 1
    # Values may be quoted; strip surrounding quotes.
    awk -F= -v k="$key" '$1 == k {
        sub("^" k "=", "");
        gsub(/^"|"$/, "");
        print; exit
    }' "$file"
}

# _uptime_human - print uptime in a friendly form.
_uptime_human() {
    if has_cmd uptime; then
        local up
        up="$(uptime -p 2>/dev/null)"
        if [[ -n "$up" ]]; then
            printf '%s\n' "${up#up }"
            return 0
        fi
    fi
    if has_file /proc/uptime; then
        local secs days hours mins
        secs="$(awk '{printf "%d", $1}' /proc/uptime)"
        days=$(( secs / 86400 ))
        hours=$(( (secs % 86400) / 3600 ))
        mins=$(( (secs % 3600) / 60 ))
        # Pluralize units for readability.
        printf '%d day%s, %d hour%s, %d minute%s\n' \
            "$days" "$( ((days == 1)) && printf '' || printf 's' )" \
            "$hours" "$( ((hours == 1)) && printf '' || printf 's' )" \
            "$mins" "$( ((mins == 1)) && printf '' || printf 's' )"
        return 0
    fi
    printf 'unknown\n'
}

# system_info - run the general system diagnostic.
system_info() {
    section "2. SYSTEM INFORMATION"

    local distro version pretty kernel arch hostname uptime_h init_sys

    pretty="$(_read_os_release PRETTY_NAME 2>/dev/null || true)"
    distro="$(_read_os_release NAME 2>/dev/null || true)"
    version="$(_read_os_release VERSION 2>/dev/null || true)"
    if [[ -z "$version" ]]; then
        version="$(_read_os_release VERSION_ID 2>/dev/null || true)"
    fi
    if [[ -z "$version" ]]; then
        version="$(_read_os_release BUILD_ID 2>/dev/null || true)"
    fi

    if [[ -z "$distro" ]]; then
        if has_cmd lsb_release; then
            distro="$(lsb_release -ds 2>/dev/null || true)"
        fi
    fi
    [[ -z "$distro" ]] && distro="Unknown Linux distribution"

    kernel="$(uname -r 2>/dev/null || printf 'unknown')"
    arch="$(uname -m 2>/dev/null || printf 'unknown')"
    hostname="$(get_hostname)"
    uptime_h="$(_uptime_human)"

    emit_kv "Distribution" "${pretty:-$distro}"
    emit_kv "OS Version"   "${version:-N/A}"
    emit_kv "Kernel"       "$kernel"
    emit_kv "Architecture" "$arch"
    emit_kv "Hostname"     "$hostname"
    emit_kv "Uptime"       "$uptime_h"

    # Identify the init system for informational purposes.
    if [[ -d /run/systemd/system ]] && has_cmd systemctl; then
        init_sys="systemd"
    elif [[ -r /proc/1/comm ]]; then
        init_sys="$(cat /proc/1/comm 2>/dev/null || printf 'unknown')"
    else
        init_sys="unknown"
    fi
    emit_kv "Init system"  "$init_sys"

    emit_ok "System information collected."
}
