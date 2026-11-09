#!/usr/bin/env bash
#
# modules/temperature.sh - CPU / sensor temperature diagnostics.
#
# Reads temperature data from /sys/class/thermal/ and /sys/class/hwmon/.
# Strictly read-only. When no sensors are available the module reports
# "Temperature information unavailable" and does NOT treat this as a fault.
#
# Thresholds are diagnostic only (they never control hardware) and can be
# overridden through the environment.

# Configurable thresholds in degrees Celsius.
: "${LDT_TEMP_WARN:=75}"
: "${LDT_TEMP_CRIT:=90}"

# sysfs roots (override for tests).
: "${LDT_THERMAL_DIR:=/sys/class/thermal}"
: "${LDT_HWMON_DIR:=/sys/class/hwmon}"

# _is_temp_raw VALUE - return 0 if VALUE looks like a millidegree reading.
_is_temp_raw() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

# _milli_to_c VALUE - convert a millidegree string to "(x.y)" Celsius.
_milli_to_c() {
    awk -v m="$1" 'BEGIN { printf "%.1f", m / 1000 }'
}

# _read_thermal - print "name|value_c" lines from /sys/class/thermal.
_read_thermal() {
    local dir temp type
    for dir in "$LDT_THERMAL_DIR"/thermal_zone*/; do
        [[ -d "$dir" ]] || continue
        temp=""
        [[ -r "$dir/temp" ]] && temp="$(cat "$dir/temp" 2>/dev/null || true)"
        _is_temp_raw "$temp" || continue
        type=""
        [[ -r "$dir/type" ]] && type="$(cat "$dir/type" 2>/dev/null || true)"
        [[ -z "$type" ]] && type="$(basename -- "$dir")"
        printf '%s|%s\n' "$type" "$(_milli_to_c "$temp")"
    done
}

# _read_hwmon - print "name|value_c" lines from /sys/class/hwmon.
_read_hwmon() {
    local dir chip input label labelfile val
    for dir in "$LDT_HWMON_DIR"/hwmon*/; do
        [[ -d "$dir" ]] || continue
        chip=""
        [[ -r "$dir/name" ]] && chip="$(cat "$dir/name" 2>/dev/null || true)"
        for input in "$dir"/temp*_input; do
            [[ -r "$input" ]] || continue
            val="$(cat "$input" 2>/dev/null || true)"
            _is_temp_raw "$val" || continue
            label=""
            labelfile="${input%_input}_label"
            [[ -r "$labelfile" ]] && label="$(cat "$labelfile" 2>/dev/null || true)"
            [[ -z "$label" ]] && label="$(basename -- "$input")"
            [[ -n "$chip" ]] && label="${chip}:${label}"
            printf '%s|%s\n' "$label" "$(_milli_to_c "$val")"
        done
    done
}

# temperature_check - run the temperature diagnostic.
temperature_check() {
    section "8. CPU TEMPERATURE"
    mark_ran temperature

    local warn="${LDT_TEMP_WARN}" crit="${LDT_TEMP_CRIT}"
    data_set temperature.warn_threshold "$warn"
    data_set temperature.crit_threshold "$crit"

    TEMP_ROWS=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        TEMP_ROWS+=("$line")
    done < <({ _read_hwmon; _read_thermal; } 2>/dev/null)

    if (( ${#TEMP_ROWS[@]} == 0 )); then
        data_set temperature.available "0"
        emit_muted "Temperature information unavailable"
        return 0
    fi

    data_set temperature.available "1"
    emit_kv "Thresholds" "warn=${warn}C  crit=${crit}C"

    local name value level
    local hot=0
    for line in "${TEMP_ROWS[@]}"; do
        name="${line%%|*}"
        value="${line#*|}"
        # Float comparison for thresholds.
        level="$(awk -v v="$value" -v w="$warn" -v c="$crit" \
            'BEGIN { if (v >= c) print "CRIT"; else if (v >= w) print "WARN"; else print "OK" }')"
        case "$level" in
            CRIT)
                emit_err "  Sensor ${name}: ${value} C (critical)"
                add_warning CRIT "Temperature sensor ${name} is ${value} C (>= ${crit} C)."
                hot=1
                ;;
            WARN)
                emit_warn "  Sensor ${name}: ${value} C (high)"
                add_warning WARN "Temperature sensor ${name} is ${value} C (>= ${warn} C)."
                hot=1
                ;;
            *)
                emit "" "  Sensor ${name}: ${value} C"
                ;;
        esac
    done

    if (( hot )); then
        emit_warn "One or more sensors are above the configured thresholds."
    else
        emit_ok "All sensors are within the configured thresholds."
    fi
}
