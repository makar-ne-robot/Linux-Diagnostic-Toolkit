#!/usr/bin/env bash
#
# modules/battery.sh - Battery / power-supply diagnostics.
#
# Reads /sys/class/power_supply/ (read-only). Works on laptops and degrades
# gracefully to "No battery detected" on desktops. Power modes are never
# modified and no root is required.

# sysfs root (override for tests).
: "${LDT_POWER_SUPPLY_DIR:=/sys/class/power_supply}"

# _first_readable FILE... - print the contents of the first readable file.
_first_readable() {
    local f
    for f in "$@"; do
        if [[ -r "$f" ]]; then
            cat "$f" 2>/dev/null
            return 0
        fi
    done
    return 1
}

# battery_check - run the battery diagnostic.
battery_check() {
    section "9. BATTERY"
    mark_ran battery

    BATT_ROWS=()
    local dev type name capacity status count=0

    if [[ -d "$LDT_POWER_SUPPLY_DIR" ]]; then
        for dev in "$LDT_POWER_SUPPLY_DIR"/*/; do
            [[ -d "$dev" ]] || continue
            type=""
            [[ -r "$dev/type" ]] && type="$(cat "$dev/type" 2>/dev/null || true)"
            [[ "$type" == "Battery" ]] || continue
            count=$(( count + 1 ))
            name="$(basename -- "$dev")"
            capacity=""
            [[ -r "$dev/capacity" ]] && capacity="$(cat "$dev/capacity" 2>/dev/null || true)"
            status=""
            [[ -r "$dev/status" ]] && status="$(cat "$dev/status" 2>/dev/null || true)"
            BATT_ROWS+=("$name|$capacity|$status")
        done
    fi

    if (( count == 0 )); then
        data_set battery.available "0"
        emit_muted "No battery detected"
        return 0
    fi

    data_set battery.available "1"
    emit_kv "Battery count" "$count"

    local row cap st full now
    for row in "${BATT_ROWS[@]}"; do
        IFS='|' read -r name cap st <<< "$row"
        emit_kv "Battery $name" "charge=${cap:-unknown}%  status=${st:-unknown}"

        # Optional capacity metrics (charge or energy based).
        full="$(_first_readable "${LDT_POWER_SUPPLY_DIR}/${name}/charge_full" "${LDT_POWER_SUPPLY_DIR}/${name}/energy_full")"
        now="$(_first_readable "${LDT_POWER_SUPPLY_DIR}/${name}/charge_now" "${LDT_POWER_SUPPLY_DIR}/${name}/energy_now")"
        if [[ -n "$full" && -n "$now" ]]; then
            emit_kv "Battery $name capacity" "${now}/${full} (raw units)"
        fi

        if is_number "$cap" && (( cap < 10 )) && [[ "$st" == "Discharging" ]]; then
            emit_warn "Battery $name is low (${cap}%) and discharging."
            add_warning WARN "Battery $name is low (${cap}%) and discharging."
        fi
    done

    emit_ok "Battery information collected."
}
