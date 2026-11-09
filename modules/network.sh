#!/usr/bin/env bash
#
# modules/network.sh - Network connectivity diagnostics.
#
# Strictly read-only and safe: enumerates interfaces, addresses and routes,
# checks DNS resolution and pings a single well-known public IP. It never
# changes network settings and never scans other hosts.

# Public targets used for connectivity checks (safe, single requests).
_NET_PING_TARGET="1.1.1.1"
_NET_DNS_TARGET="example.com"

# _net_interfaces - list interfaces with operational state.
_net_interfaces() {
    if has_cmd ip; then
        ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}'
        return 0
    fi
    if [[ -d /sys/class/net ]]; then
        ls -1 /sys/class/net 2>/dev/null
        return 0
    fi
    return 1
}

# _net_link_state IFACE - print UP/DOWN using ip or /sys.
_net_link_state() {
    local iface="$1"
    if has_cmd ip; then
        if ip link show "$iface" 2>/dev/null | grep -q 'state UP'; then
            printf 'UP\n'
        else
            printf 'DOWN\n'
        fi
        return 0
    fi
    if [[ -r "/sys/class/net/$iface/operstate" ]]; then
        tr '[:lower:]' '[:upper:]' < "/sys/class/net/$iface/operstate"
        return 0
    fi
    printf 'unknown\n'
}

# _net_ipv4 IFACE - print IPv4 address(es) for an interface.
_net_ipv4() {
    local iface="$1"
    if has_cmd ip; then
        ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | paste -sd, - 2>/dev/null
    fi
}

# _net_ipv6 IFACE - print the first IPv6 address for an interface.
_net_ipv6() {
    local iface="$1"
    if has_cmd ip; then
        ip -o -6 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}'
    fi
}

# network_check - run the network diagnostic.
network_check() {
    section "7. NETWORK"
    mark_ran network
    if has_cmd ip; then
        data_set network.has_ip_tool "1"
    else
        data_set network.has_ip_tool "0"
    fi

    # ------------------------------------------------------------------
    # Interfaces
    # ------------------------------------------------------------------
    if ! has_cmd ip && [[ ! -d /sys/class/net ]]; then
        emit_warn "Neither 'ip' nor /sys/class/net is available; network checks limited."
        add_warning WARN "Network diagnostics limited (ip command missing)."
    fi

    local iface count=0
    while IFS= read -r iface; do
        [[ -z "$iface" || "$iface" == "lo" ]] && continue
        count=$(( count + 1 ))
        local state v4 v6
        state="$(_net_link_state "$iface")"
        v4="$(_net_ipv4 "$iface")"
        v6="$(_net_ipv6 "$iface")"
        NET_IFACES+=("$iface|$state|$v4|$v6")
        local desc="Interface $iface: state=$state"
        [[ -n "$v4" ]] && desc+="  IPv4=$v4"
        [[ -n "$v6" ]] && desc+="  IPv6=$v6"
        if [[ "$state" == "UP" ]]; then
            emit_ok "$desc"
        else
            emit_muted "$desc"
        fi
    done < <(_net_interfaces 2>/dev/null)

    if (( count == 0 )); then
        emit_warn "No non-loopback network interfaces found."
        add_warning WARN "No active network interfaces detected."
    else
        emit_kv "Interfaces" "$count"
    fi

    # ------------------------------------------------------------------
    # Default route
    # ------------------------------------------------------------------
    if has_cmd ip; then
        local route
        route="$(ip route show default 2>/dev/null | head -n1)"
        data_set network.default_route "$route"
        if [[ -n "$route" ]]; then
            emit_ok "Default route: $route"
        else
            emit_warn "No default route configured."
            add_warning WARN "No default network route is configured."
        fi
    fi

    # ------------------------------------------------------------------
    # DNS configuration and resolution
    # ------------------------------------------------------------------
    if has_file /etc/resolv.conf; then
        local ns
        ns="$(awk '/^[[:space:]]*nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null)"
        NET_DNS_LIST=()
        local server
        while IFS= read -r server; do
            [[ -z "$server" ]] && continue
            NET_DNS_LIST+=("$server")
        done <<< "$ns"
        if (( ${#NET_DNS_LIST[@]} > 0 )); then
            local joined
            joined="$(printf '%s,' "${NET_DNS_LIST[@]}")"
            emit_kv "DNS servers" "${joined%,}"
        else
            emit_warn "No nameservers configured in /etc/resolv.conf."
        fi
    fi

    if has_cmd getent; then
        if has_cmd timeout; then
            if timeout 5 getent hosts "$_NET_DNS_TARGET" >/dev/null 2>&1; then
                emit_ok "DNS resolution works (resolved $_NET_DNS_TARGET)."
                data_set network.dns_resolution "1"
            else
                emit_warn "DNS resolution failed for $_NET_DNS_TARGET."
                add_warning WARN "DNS resolution appears to be failing."
                data_set network.dns_resolution "0"
            fi
        elif getent hosts "$_NET_DNS_TARGET" >/dev/null 2>&1; then
            emit_ok "DNS resolution works."
            data_set network.dns_resolution "1"
        else
            emit_warn "DNS resolution failed for $_NET_DNS_TARGET."
            add_warning WARN "DNS resolution appears to be failing."
            data_set network.dns_resolution "0"
        fi
    else
        emit_muted "getent not available; DNS resolution check skipped."
    fi

    # ------------------------------------------------------------------
    # External reachability (single ICMP echo)
    # ------------------------------------------------------------------
    if has_cmd ping; then
        local ping_ok=0
        if has_cmd timeout; then
            if timeout 6 ping -c 1 -W 3 "$_NET_PING_TARGET" >/dev/null 2>&1; then
                ping_ok=1
            fi
        elif ping -c 1 -W 3 "$_NET_PING_TARGET" >/dev/null 2>&1; then
            ping_ok=1
        fi
        if (( ping_ok )); then
            emit_ok "External connectivity OK (ping $_NET_PING_TARGET)."
            data_set network.external_reachable "1"
        else
            emit_warn "Could not reach $_NET_PING_TARGET (host may be offline or ICMP blocked)."
            add_warning WARN "External network connectivity check failed."
            data_set network.external_reachable "0"
        fi
    else
        emit_muted "ping not available; external connectivity check skipped."
    fi
}
