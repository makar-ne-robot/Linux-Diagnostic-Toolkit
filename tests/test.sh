#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
#
# tests/test.sh - Test suite for Linux Diagnostic Toolkit.
#
# The suite is ISOLATED and read-only:
#   * External commands (df, ip, systemctl, getent, ping, free, nproc) are
#     shadowed by mock scripts placed first on PATH, so results are
#     deterministic and no real network or system state is touched.
#   * sysfs inputs (meminfo, os-release, thermal, hwmon, power_supply) are
#     redirected through the LDT_* environment overrides.
#   * A curated PATH with the optional diagnostics removed exercises graceful
#     degradation without internet access.
#   * All temporary files are created under TMPDIR and removed at the end.

set -u -o pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." >/dev/null 2>&1 && pwd)"

# Report helpers expect SCRIPT_DIR to be defined by main.sh; provide it here.
SCRIPT_DIR="$PROJECT_DIR"
export SCRIPT_DIR
LDT_OUTPUT=""
export LDT_OUTPUT

# Working scratch space (cleaned up on exit).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ldt-test.XXXXXX")"
MOCKBIN="$WORK/mockbin"
MINBIN="$WORK/minbin"
mkdir -p "$MOCKBIN" "$MINBIN"
cleanup() {
    # Restore any permissions we tightened so rm can proceed.
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Minimal test harness.
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    printf '  [PASS] %s\n' "$1"
}
fail() {
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    printf '  [FAIL] %s\n' "$1"
}
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}
assert_true() {
    local name="$1"; shift
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if "$@"; then pass "$name"; else fail "$name"; fi
}
assert_false() {
    local name="$1"; shift
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if "$@"; then fail "$name"; else pass "$name"; fi
}
assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name (missing '$needle')"
    fi
}
assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name (unexpected '$needle')"
    fi
}

# json_valid FILE - validate JSON using python3 or jq when available.
json_valid() {
    if has_cmd python3; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
    elif has_cmd jq; then
        jq empty "$1" >/dev/null 2>&1
    else
        # Crude fallback: balanced braces only. Better than nothing.
        [[ "$(head -c1 "$1")" == "{" && "$(tail -c1 "$1")" == "}" ]]
    fi
}
assert_json_valid() {
    local file="$1" name="$2"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if json_valid "$file"; then
        pass "$name"
    else
        fail "$name (invalid JSON)"
    fi
}

# ---------------------------------------------------------------------------
# Load the toolkit.
# ---------------------------------------------------------------------------
# shellcheck source=../lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=../lib/utils.sh
source "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../lib/report.sh
source "$PROJECT_DIR/lib/report.sh"
# shellcheck source=../modules/system.sh
source "$PROJECT_DIR/modules/system.sh"
# shellcheck source=../modules/disk.sh
source "$PROJECT_DIR/modules/disk.sh"
# shellcheck source=../modules/cpu.sh
source "$PROJECT_DIR/modules/cpu.sh"
# shellcheck source=../modules/memory.sh
source "$PROJECT_DIR/modules/memory.sh"
# shellcheck source=../modules/services.sh
source "$PROJECT_DIR/modules/services.sh"
# shellcheck source=../modules/network.sh
source "$PROJECT_DIR/modules/network.sh"
# shellcheck source=../modules/temperature.sh
source "$PROJECT_DIR/modules/temperature.sh"
# shellcheck source=../modules/battery.sh
source "$PROJECT_DIR/modules/battery.sh"

# Force plain output during tests.
colors_init --disable

# ---------------------------------------------------------------------------
# Mock commands.
# ---------------------------------------------------------------------------
write_mock_df() {
    cat > "$MOCKBIN/df" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-Pi"* || "$*" == *"-i"* ]]; then
    cat <<'DATA'
Filesystem       Inodes  IUsed   IFree IUse% Mounted on
/dev/mock0       100000   1000   99000    1% /
/dev/mock1       200000  40000  160000   20% /data
DATA
else
    cat <<'DATA'
Filesystem   1024-blocks    Used Available Capacity Mounted on
/dev/mock0       1000000  850000    150000      85% /
/dev/mock1       2000000  500000   1500000      25% /data
DATA
fi
EOF
    chmod +x "$MOCKBIN/df"
}

write_mock_systemctl() {
    cat > "$MOCKBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *is-system-running*)
        printf '%s\n' "${MOCK_SYSTEMD_STATE:-running}"
        [[ "${MOCK_SYSTEMD_STATE:-running}" == "running" ]]
        exit $?
        ;;
    *"--state=failed"*)
        printf '%s' "${MOCK_SYSTEMD_FAILED:-}"
        exit 0
        ;;
    *list-units*)
        printf '%s' "${MOCK_SYSTEMD_UNITS:-}"
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$MOCKBIN/systemctl"
}

write_mock_ip() {
    cat > "$MOCKBIN/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"-o link show"*)
        printf '1: lo: <LOOPBACK,UP>\n2: eth0: <BROADCAST,UP>\n'
        ;;
    *"-o -4 addr"*)
        printf '2: eth0    inet %s\n' "${MOCK_IP_V4:-10.0.0.2/24}"
        ;;
    *"-o -6 addr"*)
        :
        ;;
    *"route show default"*)
        printf '%s\n' "${MOCK_IP_ROUTE:-default via 10.0.0.1 dev eth0}"
        ;;
esac
exit 0
EOF
    chmod +x "$MOCKBIN/ip"
}

write_mock_getent() {
    cat > "$MOCKBIN/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_DNS_FAIL:-0}" == "1" ]]; then
    exit 2
fi
printf '93.184.216.34 %s\n' "${2:-example.com}"
exit 0
EOF
    chmod +x "$MOCKBIN/getent"
}

write_mock_ping() {
    cat > "$MOCKBIN/ping" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_PING_FAIL:-0}" == "1" ]] && exit 1
exit 0
EOF
    chmod +x "$MOCKBIN/ping"
}

write_mock_free() {
    cat > "$MOCKBIN/free" <<'EOF'
#!/usr/bin/env bash
cat <<'DATA'
               total        used        free
Mem:            7.4Gi       3.4Gi       2.4Gi
Swap:           3.7Gi          0B       3.7Gi
DATA
EOF
    chmod +x "$MOCKBIN/free"
}

write_mock_nproc() {
    cat > "$MOCKBIN/nproc" <<'EOF'
#!/usr/bin/env bash
echo "${MOCK_NPROC:-8}"
EOF
    chmod +x "$MOCKBIN/nproc"
}

# Core tools that must be present in a self-contained PATH for module tests.
CORE_TOOLS="bash sh env awk sed grep cat sort uniq wc tr cut head tail dirname basename date mkdir ls paste uname rm sleep"

# build_netbin DIR WITH_TIMEOUT WITH_GETENT WITH_PING WITH_IP
# Build a self-contained PATH containing only core tools plus the requested
# network commands (mocked). This lets us exercise "tool missing" scenarios
# without relying on the host PATH.
build_netbin() {
    local dir="$1" with_timeout="$2" with_getent="$3" with_ping="$4" with_ip="$5"
    local c src
    mkdir -p "$dir"
    for c in $CORE_TOOLS; do
        src="$(command -v -- "$c" 2>/dev/null)" || continue
        [[ "$src" == /* && -x "$src" ]] && ln -sf "$src" "$dir/$c"
    done
    if [[ "$with_timeout" == 1 ]]; then
        src="$(command -v -- timeout 2>/dev/null)" || true
        [[ -n "$src" && -x "$src" ]] && ln -sf "$src" "$dir/timeout"
    fi
    [[ "$with_getent" == 1 ]] && cp "$MOCKBIN/getent" "$dir/getent"
    [[ "$with_ping" == 1 ]]   && cp "$MOCKBIN/ping"   "$dir/ping"
    [[ "$with_ip" == 1 ]]     && cp "$MOCKBIN/ip"     "$dir/ip"
    return 0
}

# Build the curated "minimal" PATH: essential tools, but WITHOUT the optional
# diagnostics (df, ip, getent, ping, free, nproc, systemctl, uptime, hostname).
build_minbin() {
    local c p
    for c in bash sh awk sed grep cat sort uniq wc tr cut head tail \
             dirname basename date mkdir ls paste uname rm env sleep; do
        p="$(command -v -- "$c" 2>/dev/null)" || continue
        [[ "$p" == /* && -x "$p" ]] && ln -sf "$p" "$MINBIN/$c"
    done
}

setup_mocks() {
    write_mock_df
    write_mock_systemctl
    write_mock_ip
    write_mock_getent
    write_mock_ping
    write_mock_free
    write_mock_nproc
    build_minbin
}

# with_mocks CMD... - run with the mock bin prepended to PATH.
with_mocks() {
    PATH="$MOCKBIN:$PATH" "$@"
}

# run_mod CMD... - run a diagnostic function in the CURRENT shell (so the
# structured state persists) while capturing its terminal output in OUT.
OUT=""
run_mod() {
    with_mocks "$@" > "$WORK/.out" 2>&1
    OUT="$(cat "$WORK/.out")"
}

# cli ARGS... - run the real entry point with mock commands (no network).
cli() {
    PATH="$MOCKBIN:$PATH" bash "$PROJECT_DIR/main.sh" "$@"
}

# ---------------------------------------------------------------------------
# Tests: utility helpers.
# ---------------------------------------------------------------------------
test_utils() {
    printf '\n[utils helpers]\n'

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if with_mocks has_cmd df; then pass "has_cmd resolves mock"; else fail "has_cmd resolves mock"; fi
    assert_false "has_cmd rejects missing"  has_cmd definitely_not_a_command_xyz
    assert_true  "has_file detects readable" has_file /etc/os-release
    assert_false "has_file rejects missing"  has_file /nonexistent/path/xyz

    assert_eq "50" "$(percent 50 100)" "percent basic"
    assert_eq "0"  "$(percent 0 0)"    "percent zero-total"

    assert_eq "512.00 KiB" "$(human_kb 512)"   "human_kb KiB"
    assert_eq "1.00 MiB" "$(human_kb 1024)"    "human_kb MiB"
    assert_eq "1.00 GiB" "$(human_kb 1048576)" "human_kb GiB"

    assert_true  "is_number accepts digits" is_number 42
    assert_false "is_number rejects text"   is_number abc
    assert_eq "hello" "$(trim '  hello  ')" "trim whitespace"

    assert_true  "is_float accepts 3.9"     is_float 3.9
    assert_true  "is_float accepts integer" is_float 4
    assert_false "is_float rejects word"    is_float abc
    assert_false "is_float rejects empty"   is_float ""
    assert_false "is_float rejects nan"     is_float nan

    assert_true  "float_gt 4.9 > 4"   float_gt 4.9 4
    assert_true  "float_gt 4.1 > 4"   float_gt 4.1 4
    assert_false "float_gt 4.0 > 4"   float_gt 4.0 4
    assert_false "float_gt 3.9 > 4"   float_gt 3.9 4
}

# ---------------------------------------------------------------------------
# Tests: scoring and health status.
# ---------------------------------------------------------------------------
test_score() {
    printf '\n[scoring]\n'

    reset_state
    assert_eq "UNKNOWN" "$(health_status)" "health UNKNOWN with no data"

    reset_state
    compute_score >/dev/null
    mark_ran system
    assert_eq "HEALTHY" "$(health_status)" "health HEALTHY"
    assert_eq "100" "$(compute_score)" "score with no findings"
    assert_eq "GOOD" "$(score_status 100)" "status GOOD"

    WARN_COUNT=2
    assert_eq "WARNING" "$(health_status)" "health WARNING"
    assert_eq "90" "$(compute_score)" "score with 2 warnings"

    WARN_COUNT=0; CRIT_COUNT=1
    assert_eq "CRITICAL" "$(health_status)" "health CRITICAL"

    WARN_COUNT=0; CRIT_COUNT=5
    assert_eq "0" "$(compute_score)" "score floors at 0"
    assert_eq "CRITICAL" "$(score_status 0)" "status CRITICAL"

    WARN_COUNT=0; CRIT_COUNT=0
}

# ---------------------------------------------------------------------------
# Tests: modules (with mocks).
# ---------------------------------------------------------------------------
test_modules() {
    printf '\n[modules]\n'

    local out

    reset_state
    run_mod system_info
    assert_contains "$OUT" "SYSTEM INFORMATION" "system_info section header"
    assert_true "system_info recorded data" test -n "$(data_get system.kernel)"

    reset_state
    run_mod cpu_info
    out="$OUT"
    assert_contains "$out" "CPU INFORMATION" "cpu_info section header"
    assert_eq "8" "$(data_get cpu.logical_cores)" "cpu logical cores from mock nproc"

    reset_state
    run_mod disk_check
    out="$OUT"
    assert_contains "$out" "DISK USAGE" "disk_check section header"
    assert_contains "$out" "85%" "disk_check shows 85% filesystem"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "${WARNINGS[*]:-}" == *"85% full"* ]]; then pass "disk_check records full warning"; else fail "disk_check records full warning"; fi
    assert_eq "WARNING" "$(_area_disk_status)" "disk area status WARNING"

    reset_state
    run_mod memory_info
    assert_contains "$OUT" "MEMORY INFORMATION" "memory_info section header"

    reset_state
    run_mod network_check
    assert_contains "$OUT" "NETWORK" "network_check section header"
    assert_eq "OK" "$(_area_network_status)" "network area OK with mocks"

    reset_state
    run_mod services_check
    assert_contains "$OUT" "SYSTEM SERVICES" "services_check section header"
}

# ---------------------------------------------------------------------------
# Tests: CPU load average comparison (fractional values).
# ---------------------------------------------------------------------------
# _cpu_load_has_warning - return 0 if a CPU-load warning was recorded.
_cpu_load_has_warning() {
    [[ "${WARNINGS[*]:-}" == *"CPU load average"* ]]
}

test_cpu_load() {
    printf '\n[cpu load average]\n'

    local lf="$WORK/loadavg"
    local out
    export MOCK_NPROC=4

    # value expected_warning name
    _cpu_load_case() {
        local val="$1" expect="$2" name="$3"
        printf '%s 0.10 0.20 1/100 1234\n' "$val" > "$lf"
        reset_state
        export LDT_LOADAVG="$lf"
        with_mocks cpu_info > "$WORK/.out" 2>&1
        out="$(cat "$WORK/.out")"
        unset LDT_LOADAVG
        local got=0
        _cpu_load_has_warning && got=1
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        if [[ "$got" == "$expect" ]]; then
            pass "$name"
        else
            fail "$name (warning=$got expected=$expect)"
        fi
    }

    _cpu_load_case "3.90" 0 "load 3.9 with 4 cores: no warning"
    _cpu_load_case "4.00" 0 "load 4.0 with 4 cores: no warning"
    _cpu_load_case "4.10" 1 "load 4.1 with 4 cores: warning"
    _cpu_load_case "4.90" 1 "load 4.9 with 4 cores: warning"

    # Invalid load value must not warn and must not crash.
    printf 'not-a-number 0.1 0.2 1/100 9\n' > "$lf"
    reset_state
    export LDT_LOADAVG="$lf"
    with_mocks cpu_info > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    unset LDT_LOADAVG
    assert_contains "$out" "not a valid number" "invalid load value handled"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if _cpu_load_has_warning; then fail "invalid load value adds no warning"; else pass "invalid load value adds no warning"; fi

    # Unknown logical core count must skip the comparison.
    export MOCK_NPROC=abc
    printf '9.99 0.1 0.2 1/100 9\n' > "$lf"
    reset_state
    export LDT_LOADAVG="$lf"
    with_mocks cpu_info > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    unset LDT_LOADAVG
    assert_contains "$out" "Logical core count unknown" "unknown cores skip comparison"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if _cpu_load_has_warning; then fail "unknown cores add no warning"; else pass "unknown cores add no warning"; fi

    unset MOCK_NPROC
}

# ---------------------------------------------------------------------------
# Tests: systemd states (degraded bug, running, non-systemd).
# ---------------------------------------------------------------------------
test_systemd() {
    printf '\n[systemd]\n'

    local out

    # running state
    reset_state
    export MOCK_SYSTEMD_STATE=running
    export MOCK_SYSTEMD_UNITS=$'a.service loaded active running A\nb.service loaded active running B\n'
    export MOCK_SYSTEMD_FAILED=""
    run_mod _services_systemd
    out="$OUT"
    assert_contains "$out" "System state: running" "systemd running state shown"
    assert_eq "0" "$(data_get services.failed)" "systemd no failed services"
    assert_eq "OK" "$(_area_services_status)" "services area OK"

    # degraded state: is-system-running exits non-zero but still prints state
    reset_state
    export MOCK_SYSTEMD_STATE=degraded
    export MOCK_SYSTEMD_UNITS=$'a.service loaded active running A\n'
    export MOCK_SYSTEMD_FAILED=$'broken.service loaded failed failed Broken\n'
    run_mod _services_systemd
    out="$OUT"
    assert_contains "$out" "System state: degraded" "systemd degraded state shown (bug fix)"
    assert_eq "1" "$(data_get services.failed)" "systemd failed count degraded"
    assert_eq "WARNING" "$(_area_services_status)" "services area WARNING on failure"
    assert_eq "broken.service" "${SVC_FAILED_LIST[0]:-}" "failed unit name captured"

    unset MOCK_SYSTEMD_STATE MOCK_SYSTEMD_UNITS MOCK_SYSTEMD_FAILED

    # non-systemd fallback
    reset_state
    out="$(_services_other sysvinit 2>&1)"
    assert_contains "$out" "only supported on systemd" "non-systemd emits informative notice"
    assert_eq "UNKNOWN" "$(_area_services_status)" "non-systemd services area UNKNOWN"
}

# ---------------------------------------------------------------------------
# Tests: temperature module with mock sysfs.
# ---------------------------------------------------------------------------
test_temperature() {
    printf '\n[temperature]\n'

    local tdir="$WORK/thermal" hdir="$WORK/hwmon"
    mkdir -p "$tdir/thermal_zone0" "$hdir/hwmon0"
    printf '47000\n' > "$tdir/thermal_zone0/temp"
    printf 'x86_pkg_temp\n' > "$tdir/thermal_zone0/type"
    printf 'coretemp\n' > "$hdir/hwmon0/name"
    printf '91000\n' > "$hdir/hwmon0/temp1_input"
    printf 'Package id 0\n' > "$hdir/hwmon0/temp1_label"

    reset_state
    local out
    LDT_THERMAL_DIR="$tdir" LDT_HWMON_DIR="$hdir" temperature_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "x86_pkg_temp" "temperature reads thermal zone"
    assert_contains "$out" "Package id 0" "temperature reads hwmon label"
    assert_contains "$out" "HARDWARE TEMPERATURES" "temperature section renamed"
    assert_eq "1" "$(data_get temperature.available)" "temperature available flag"
    assert_eq "1" "$(data_get temperature.thresholds_valid)" "default thresholds valid"
    assert_true "temperature records sensor rows" test "${#TEMP_ROWS[@]}" -ge 2
    # 91C must exceed the default crit threshold (90).
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if (( CRIT_COUNT >= 1 )); then pass "temperature flags critical sensor"; else fail "temperature flags critical sensor"; fi

    # No sensors: must be unavailable and NOT a fault.
    local empty="$WORK/empty"
    mkdir -p "$empty"
    reset_state
    LDT_THERMAL_DIR="$empty" LDT_HWMON_DIR="$empty" temperature_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "Temperature information unavailable" "temperature unavailable message"
    assert_eq "0" "$(data_get temperature.available)" "temperature unavailable flag"
    assert_eq "0" "$WARN_COUNT" "temperature absence is not a warning"

    # Configurable thresholds.
    reset_state
    LDT_HWMON_DIR="$hdir" LDT_THERMAL_DIR="$empty" LDT_TEMP_CRIT=200 temperature_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "1" "$(data_get temperature.available)" "threshold override keeps data"
    assert_eq "200" "$(data_get temperature.crit_threshold)" "custom crit threshold recorded"
    assert_eq "1" "$(data_get temperature.thresholds_valid)" "custom thresholds valid"
    assert_eq "0" "$CRIT_COUNT" "higher crit threshold avoids critical"

    # Non-numeric threshold: must warn and must not classify as normal.
    reset_state
    LDT_HWMON_DIR="$hdir" LDT_THERMAL_DIR="$empty" LDT_TEMP_WARN=abc temperature_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "Invalid temperature thresholds" "non-numeric threshold rejected"
    assert_eq "0" "$(data_get temperature.thresholds_valid)" "non-numeric threshold flag invalid"
    assert_not_contains "$out" "All sensors are within" "invalid thresholds not classified normal"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if (( WARN_COUNT >= 1 )); then pass "invalid thresholds add a warning"; else fail "invalid thresholds add a warning"; fi

    # warn >= crit must be rejected too.
    reset_state
    LDT_HWMON_DIR="$hdir" LDT_THERMAL_DIR="$empty" LDT_TEMP_WARN=100 LDT_TEMP_CRIT=50 temperature_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "Invalid temperature thresholds" "warn >= crit rejected"
    assert_eq "0" "$(data_get temperature.thresholds_valid)" "warn >= crit flag invalid"

    # Empty/infinite-like values are rejected (source-time default is valid,
    # so an explicit non-number is used to exercise the guard).
    reset_state
    LDT_HWMON_DIR="$hdir" LDT_THERMAL_DIR="$empty" LDT_TEMP_WARN=inf temperature_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "Invalid temperature thresholds" "inf threshold rejected"
}

# ---------------------------------------------------------------------------
# Tests: battery module with mock sysfs.
# ---------------------------------------------------------------------------
test_battery() {
    printf '\n[battery]\n'

    local pdir="$WORK/psu"
    mkdir -p "$pdir/BAT0" "$pdir/BAT1"
    printf 'Battery\n' > "$pdir/BAT0/type"
    printf '5\n' > "$pdir/BAT0/capacity"
    printf 'Discharging\n' > "$pdir/BAT0/status"
    printf 'Battery\n' > "$pdir/BAT1/type"
    printf '90\n' > "$pdir/BAT1/capacity"
    printf 'Charging\n' > "$pdir/BAT1/status"

    reset_state
    local out
    LDT_POWER_SUPPLY_DIR="$pdir" battery_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "Battery count" "battery count line"
    assert_contains "$out" "charge=5%" "battery reads capacity"
    assert_contains "$out" "status=Discharging" "battery reads status"
    assert_eq "1" "$(data_get battery.available)" "battery available flag"
    assert_eq "2" "${#BATT_ROWS[@]}" "multiple batteries detected"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if (( WARN_COUNT >= 1 )); then pass "low discharging battery warns"; else fail "low discharging battery warns"; fi

    # No battery (desktop): not a fault.
    local pempty="$WORK/psu-empty"
    mkdir -p "$pempty"
    reset_state
    LDT_POWER_SUPPLY_DIR="$pempty" battery_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_contains "$out" "No battery detected" "no battery message"
    assert_eq "0" "$(data_get battery.available)" "battery unavailable flag"
    assert_eq "0" "$WARN_COUNT" "no battery is not a warning"
}

# ---------------------------------------------------------------------------
# Tests: network probes, timeouts and status states.
# ---------------------------------------------------------------------------
test_network_probes() {
    printf '\n[network probes]\n'

    local BALL="$WORK/net-all" BNTO="$WORK/net-notimeout"
    local BNG="$WORK/net-nogetent" BNP="$WORK/net-noping" BNI="$WORK/net-noip"
    build_netbin "$BALL" 1 1 1 1
    build_netbin "$BNTO" 0 1 1 1
    build_netbin "$BNG"  1 0 1 1
    build_netbin "$BNP"  1 1 0 1
    build_netbin "$BNI"  1 1 1 0

    local out

    # All tools available, healthy results -> OK.
    reset_state
    PATH="$BALL" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "1" "$(data_get network.dns_resolution)" "all tools: dns ok"
    assert_eq "1" "$(data_get network.external_reachable)" "all tools: ping ok"
    assert_eq "OK" "$(_area_network_status)" "all tools: status OK"

    # No timeout: probes must be skipped, not run unbounded.
    reset_state
    PATH="$BNTO" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "unknown" "$(data_get network.dns_resolution)" "no timeout: dns skipped"
    assert_eq "unknown" "$(data_get network.external_reachable)" "no timeout: ping skipped"
    assert_contains "$out" "skipped to avoid hanging" "no timeout: message shown"
    assert_eq "UNKNOWN" "$(_area_network_status)" "no timeout: status UNKNOWN"

    # No getent: DNS unverifiable, ping ok -> UNKNOWN (not OK).
    reset_state
    PATH="$BNG" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "unknown" "$(data_get network.dns_resolution)" "no getent: dns unknown"
    assert_eq "1" "$(data_get network.external_reachable)" "no getent: ping ok"
    assert_contains "$out" "'getent' not available" "no getent: message shown"
    assert_eq "UNKNOWN" "$(_area_network_status)" "no getent: status UNKNOWN"

    # No ping: external unverifiable -> UNKNOWN.
    reset_state
    PATH="$BNP" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "unknown" "$(data_get network.external_reachable)" "no ping: external unknown"
    assert_contains "$out" "'ping' not available" "no ping: message shown"
    assert_eq "UNKNOWN" "$(_area_network_status)" "no ping: status UNKNOWN"

    # DNS failure -> WARNING.
    reset_state
    MOCK_DNS_FAIL=1 PATH="$BALL" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "0" "$(data_get network.dns_resolution)" "dns failure recorded"
    assert_eq "WARNING" "$(_area_network_status)" "dns failure: status WARNING"

    # External unreachable -> WARNING.
    reset_state
    MOCK_PING_FAIL=1 PATH="$BALL" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "0" "$(data_get network.external_reachable)" "ping failure recorded"
    assert_eq "WARNING" "$(_area_network_status)" "ping failure: status WARNING"

    # Probes disabled -> local checks only, status OK.
    reset_state
    LDT_NO_NETWORK_PROBES=1 PATH="$BALL" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "disabled" "$(data_get network.dns_resolution)" "disabled: dns disabled"
    assert_eq "disabled" "$(data_get network.external_reachable)" "disabled: ping disabled"
    assert_eq "0" "$(data_get network.probes_enabled)" "disabled: probes_enabled=0"
    assert_contains "$out" "probes disabled" "disabled: message shown"
    assert_eq "OK" "$(_area_network_status)" "disabled: status OK (local only)"

    # No ip tool: route unverifiable -> UNKNOWN.
    reset_state
    PATH="$BNI" network_check > "$WORK/.out" 2>&1
    out="$(cat "$WORK/.out")"
    assert_eq "UNKNOWN" "$(_area_network_status)" "no ip: status UNKNOWN"
}

# ---------------------------------------------------------------------------
# Tests: graceful handling of missing files.
# ---------------------------------------------------------------------------
test_missing_files() {
    printf '\n[missing files]\n'

    reset_state
    LDT_MEMINFO=/nonexistent/meminfo with_mocks memory_info >/dev/null 2>&1
    assert_true "memory_info warns on missing meminfo" test "${#WARNINGS[@]}" -gt 0

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if ! LDT_OS_RELEASE=/nonexistent/os-release _read_os_release NAME; then
        pass "_read_os_release fails gracefully"
    else
        fail "_read_os_release fails gracefully"
    fi
}

# ---------------------------------------------------------------------------
# Tests: report generation (TXT + JSON).
# ---------------------------------------------------------------------------
test_report() {
    printf '\n[report generation]\n'

    local report
    report="$WORK/report.txt"

    reset_state
    with_mocks system_info >/dev/null 2>&1
    with_mocks cpu_info >/dev/null 2>&1

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if report_write "$report" >/dev/null 2>&1 && [[ -s "$report" ]]; then
        pass "report_write creates file"
    else
        fail "report_write creates file"
    fi

    local content
    content="$(cat "$report" 2>/dev/null)"
    assert_contains "$content" "DIAGNOSTIC REPORT" "txt has header"
    assert_contains "$content" "WARNINGS" "txt has warnings section"
    assert_contains "$content" "OVERALL ASSESSMENT" "txt has assessment"
    assert_contains "$content" "heuristic" "txt documents heuristic score"

    # Default filename pattern.
    local fname
    fname="$(report_default_filename)"
    assert_contains "$fname" "linux-diagnostic-report-" "report filename prefix"

    # Overwrite is announced, not silent.
    local err
    err="$(report_write "$report" 2>&1 >/dev/null)"
    assert_contains "$err" "overwriting existing file" "overwrite is announced"
}

test_json() {
    printf '\n[json export]\n'

    local jfile="$WORK/report.json"

    reset_state
    with_mocks system_info >/dev/null 2>&1
    with_mocks cpu_info >/dev/null 2>&1
    with_mocks disk_check >/dev/null 2>&1
    with_mocks memory_info >/dev/null 2>&1
    with_mocks services_check >/dev/null 2>&1
    with_mocks network_check >/dev/null 2>&1

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if report_write_json "$jfile" >/dev/null 2>&1 && [[ -s "$jfile" ]]; then
        pass "report_write_json creates file"
    else
        fail "report_write_json creates file"
    fi
    assert_json_valid "$jfile" "json is valid"
    assert_contains "$(cat "$jfile")" '"tool"' "json has tool section"
    assert_contains "$(cat "$jfile")" '"health_score"' "json has health score"
    assert_contains "$(cat "$jfile")" '"type": "heuristic"' "json marks score heuristic"

    # Numbers must be numbers, missing values must be null.
    assert_contains "$(cat "$jfile")" '"logical_cores": 8' "json numeric logical cores"
    assert_contains "$(cat "$jfile")" '"use_percent": 85' "json numeric disk percent"

    # Empty value renders as null.
    reset_state
    data_set system.hostname ""
    report_write_json "$jfile" >/dev/null 2>&1
    assert_contains "$(cat "$jfile")" '"hostname": null' "json null for empty value"

    # Special characters are escaped and round-trip.
    reset_state
    mark_ran system
    data_set system.hostname 'host"with\slash'
    add_warning WARN $'line with tab\tand newline\nand "quote"'
    report_write_json "$jfile" >/dev/null 2>&1
    assert_json_valid "$jfile" "json valid with special characters"
    assert_contains "$(cat "$jfile")" 'host\"with\\slash' "json escapes quote and backslash"

    if has_cmd python3; then
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["system"]["hostname"] == "host\"with\\slash", d["system"]["hostname"]
assert "\t" in d["warnings"][0]["message"] and "\n" in d["warnings"][0]["message"]
' "$jfile" 2>/dev/null; then
            pass "json special characters round-trip"
        else
            fail "json special characters round-trip"
        fi
    fi

    WARN_COUNT=0; CRIT_COUNT=0
}

# ---------------------------------------------------------------------------
# Tests: CLI flags and output handling.
# ---------------------------------------------------------------------------
test_cli_output() {
    printf '\n[cli output]\n'

    local a="$WORK/a.txt" b="$WORK/b.txt" c="$WORK/c.txt" d="$WORK/d.txt"
    local envout="$WORK/env.txt" cliout="$WORK/cli.txt"

    # 1. --output PATH implies report generation.
    cli --full --no-color --output "$a" >/dev/null 2>&1
    assert_true "--output PATH writes report" test -s "$a"

    # 2. --output=PATH form.
    cli --full --no-color --output="$b" >/dev/null 2>&1
    assert_true "--output=PATH writes report" test -s "$b"

    # 3. --output PATH without --full (report implies diagnostics).
    cli --no-color --output "$c" >/dev/null 2>&1
    assert_true "--output alone writes report" test -s "$c"

    # 4. LDT_OUTPUT environment variable.
    LDT_OUTPUT="$d" cli --full --no-color >/dev/null 2>&1
    assert_true "LDT_OUTPUT env writes report" test -s "$d"

    # 5. CLI --output takes precedence over LDT_OUTPUT.
    LDT_OUTPUT="$envout" cli --full --no-color --output "$cliout" >/dev/null 2>&1
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -s "$cliout" && ! -e "$envout" ]]; then
        pass "CLI --output overrides LDT_OUTPUT"
    else
        fail "CLI --output overrides LDT_OUTPUT"
    fi

    # 6. Path with spaces.
    local spaced="$WORK/dir with spaces"
    cli --full --no-color --output "$spaced/r port.txt" >/dev/null 2>&1
    assert_true "--output handles spaces" test -s "$spaced/r port.txt"
}

test_cli_json() {
    printf '\n[cli json]\n'

    local j="$WORK/cli.json"
    cli --full --json --no-color --output "$j" >/dev/null 2>&1
    assert_true "--json writes report" test -s "$j"
    assert_json_valid "$j" "--json produces valid JSON"

    # Default JSON filename when no output path is given.
    local proj_json="$PROJECT_DIR/reports/linux-diagnostic-report-test.json"
    cli --full --json --no-color --output "$proj_json" >/dev/null 2>&1
    assert_json_valid "$proj_json" "json to project reports dir"
    rm -f "$proj_json"
}

test_cli_colors() {
    printf '\n[cli colors]\n'

    local out
    out="$(cli --full --no-color 2>&1)"
    assert_not_contains "$out" $'\033[' "--no-color emits no ANSI codes"

    # Unit-level: disabled colors yield empty variables.
    colors_init --disable
    assert_eq "" "$C_RED" "colors disabled -> empty"
    colors_init
}

test_cli_invalid() {
    printf '\n[cli invalid args]\n'

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if cli --definitely-unknown >/dev/null 2>&1; then
        fail "unknown flag rejected"
    else
        pass "unknown flag rejected"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if cli --output >/dev/null 2>&1; then
        fail "--output without argument rejected"
    else
        pass "--output without argument rejected"
    fi

    local out
    out="$(cli --help 2>&1)"
    assert_contains "$out" "USAGE" "--help shows usage"
    assert_contains "$out" "--json" "--help documents --json"
    assert_contains "$out" "--temperature" "--help documents --temperature"
}

test_cli_module_selection() {
    printf '\n[cli module selection]\n'

    local out
    out="$(cli --disk --memory --no-color 2>&1)"
    assert_contains "$out" "DISK USAGE" "selection runs disk"
    assert_contains "$out" "MEMORY INFORMATION" "selection runs memory"
    assert_not_contains "$out" "CPU INFORMATION" "selection skips unselected cpu"
    assert_not_contains "$out" "SYSTEM SERVICES" "selection skips unselected services"

    # --version
    out="$(cli --version 2>&1)"
    assert_contains "$out" "Linux Diagnostic Toolkit" "--version output"
}

# ---------------------------------------------------------------------------
# Tests: --no-network-probes CLI flag.
# ---------------------------------------------------------------------------
test_cli_network_flag() {
    printf '\n[cli network probes]\n'

    local out

    # Disabled: no DNS probe output, message present.
    out="$(cli --network --no-network-probes --no-color 2>&1)"
    assert_contains "$out" "probes disabled" "cli --no-network-probes disables probes"
    assert_not_contains "$out" "DNS resolution works" "cli disabled: no DNS probe"
    assert_not_contains "$out" "External connectivity OK" "cli disabled: no ping probe"

    # Default: probes run (mocked, no real traffic).
    out="$(cli --network --no-color 2>&1)"
    assert_contains "$out" "DNS resolution works" "cli default runs DNS probe"

    # Environment equivalent.
    out="$(LDT_NO_NETWORK_PROBES=1 cli --network --no-color 2>&1)"
    assert_contains "$out" "probes disabled" "LDT_NO_NETWORK_PROBES disables probes"

    # Documented in --help.
    out="$(cli --help 2>&1)"
    assert_contains "$out" "--no-network-probes" "help documents --no-network-probes"
    assert_contains "$out" "hardware temperature" "help mentions hardware temperature"
}

# ---------------------------------------------------------------------------
# Tests: missing commands (curated PATH, no optional tools, no network).
# ---------------------------------------------------------------------------
test_missing_commands() {
    printf '\n[missing commands]\n'

    local out rc report="$WORK/min.txt"
    out="$(env PATH="$MINBIN" bash "$PROJECT_DIR/main.sh" --full --no-color --output "$report" 2>&1)"
    rc=$?

    assert_eq "0" "$rc" "runs without optional commands (exit 0)"
    assert_contains "$out" "'df' is not available" "missing df handled in full run"
    assert_true "report still written without optional tools" test -s "$report"
    assert_not_contains "$out" "command not found" "no leaked command failures"

    # Direct checks for the missing-command code paths.
    out="$(PATH="$MINBIN" disk_check 2>&1)"
    assert_contains "$out" "'df' is not available" "disk_check handles missing df"
    out="$(PATH="$MINBIN" _services_systemd 2>&1)"
    assert_contains "$out" "'systemctl' is not available" "services handles missing systemctl"
}

# ---------------------------------------------------------------------------
# Tests: report write errors.
# ---------------------------------------------------------------------------
test_write_errors() {
    printf '\n[write errors]\n'

    local ro="$WORK/readonly"
    mkdir -p "$ro"
    chmod 500 "$ro"

    reset_state
    mark_ran system
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if report_write "$ro/out.txt" >/dev/null 2>&1; then
        fail "report_write fails on unwritable dir"
    else
        pass "report_write fails on unwritable dir"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if cli --full --no-color --output "$ro/out.txt" >/dev/null 2>&1; then
        fail "cli exits non-zero on write error"
    else
        pass "cli exits non-zero on write error"
    fi

    chmod 700 "$ro" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------
printf '=============================================\n'
printf ' Linux Diagnostic Toolkit - Test Suite\n'
printf '=============================================\n'

setup_mocks

test_utils
test_score
test_modules
test_cpu_load
test_systemd
test_temperature
test_battery
test_network_probes
test_missing_files
test_report
test_json
test_cli_output
test_cli_json
test_cli_colors
test_cli_invalid
test_cli_module_selection
test_cli_network_flag
test_missing_commands
test_write_errors

printf '\n=============================================\n'
printf ' Results: %d passed, %d failed (%d assertions)\n' \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_RUN"
printf '=============================================\n'

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
exit 0
