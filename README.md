# Linux Diagnostic Toolkit

A modular, safe, read-only **CLI utility written in Bash** for diagnosing the
health of a Linux system and producing a structured report in **TXT** or
**JSON**.

It inspects the system, CPU, memory, disks, services, network, CPU
temperature and battery, flags potential problems with color-coded severity,
and writes a timestamped report you can attach to a ticket or keep for later
reference.

> The toolkit never modifies your system: no package installation, no `sudo`,
> no service state changes, no network or power configuration changes.

---

## Table of contents

- [Features](#features)
- [Example terminal output](#example-terminal-output)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Diagnostic scope](#diagnostic-scope)
- [Command-line flags](#command-line-flags)
- [Health Score](#health-score)
- [Example reports](#example-reports)
- [Project structure](#project-structure)
- [How it works](#how-it-works)
- [Privacy & Security](#privacy--security)
- [Testing](#testing)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Features

| Area | What is checked |
|------|-----------------|
| **System** | Distribution, OS version, kernel, architecture, hostname, uptime, init system |
| **CPU** | Model, physical/logical cores, architecture, load average (1/5/15 min), processes |
| **Memory** | Total/used/free/available RAM, swap, usage %, high-usage warnings |
| **Disk** | Mounted filesystems, size/used/available, usage %, inode usage, >80% / >90% alerts |
| **Services** | Init system detection, systemd manager state (incl. `degraded`), active/failed units |
| **Network** | Interfaces and link state, IPv4/IPv6, default route, time-bounded DNS resolution and external reachability (optional) |
| **Temperature** | Hardware temperatures from `/sys/class/thermal` and `/sys/class/hwmon`, configurable thresholds |
| **Battery** | `/sys/class/power_supply` batteries, charge level, charging status, multiple batteries |

Additional highlights:

- **Modular architecture** — one module per diagnostic domain.
- **TXT and JSON reports** — machine-readable JSON export with no hard `jq`
  dependency (plain Bash; `jq`/`python3` are only used by the tests).
- **Per-module selection** — run one or several modules from the CLI.
- **ANSI colors** with automatic disable for non-TTY output and `NO_COLOR`.
- **Heuristic Health Score** with an explicit disclaimer.
- **Graceful degradation** — missing optional tools or sensors never crash the
  tool and are reported as `UNKNOWN` / `UNAVAILABLE`, never as `OK`.
- **No external dependencies** beyond standard Linux utilities.

---

## Example terminal output

> The following is anonymised sample output (hostname, addresses, CPU model and
> kernel are illustrative placeholders).

```
+======================================================+
|            LINUX DIAGNOSTIC TOOLKIT                  |
|                 System Analyzer                      |
+======================================================+

[1] Full system diagnostics
[2] Disk diagnostics
[3] CPU diagnostics
[4] Memory diagnostics
[5] Services diagnostics
[6] Network diagnostics
[7] System information
[8] Hardware temperatures
[9] Battery diagnostics
[10] Generate diagnostic report
[11] Exit

Select an option: 1

--------------------------------------------------------------
2. SYSTEM INFORMATION
--------------------------------------------------------------
  Distribution: ExampleOS 1.0
  OS Version: 1.0
  Kernel: 6.6.0-generic
  Architecture: x86_64
  Hostname: workstation-01
  Uptime: 1 day, 2 hours, 40 minutes
  Init system: systemd

--------------------------------------------------------------
3. CPU INFORMATION
--------------------------------------------------------------
  Model: Example CPU @ 2.40GHz
  Architecture: x86_64
  Physical cores: 4
  Logical cores: 8
  Load average: 1m=0.42  5m=0.31  15m=0.28
  Processes: 1/321 (runnable/total)
CPU load is within expected range.

--------------------------------------------------------------
4. MEMORY INFORMATION
--------------------------------------------------------------
  Total RAM: 15.50 GiB
  Used RAM: 5.10 GiB
  Free RAM: 6.20 GiB
  Available RAM: 10.40 GiB
  RAM usage: 33%
  Swap usage: 0%
Memory usage is normal (33%).

--------------------------------------------------------------
7. NETWORK
--------------------------------------------------------------
Interface eth0: state=UP  IPv4=10.0.0.42/24
  Default route: default via 10.0.0.1 dev eth0
  DNS servers: 10.0.0.1
DNS resolution works (resolved example.com).
External connectivity OK.

+-----------------------------------+
|        DIAGNOSTIC SUMMARY         |
+-----------------------------------+
| System status       : OK          |
| Disk usage          : OK          |
| Memory usage        : OK          |
| Services            : OK          |
| Network             : OK          |
| Temperature         : AVAILABLE   |
| Battery             : NOT PRESENT |
+-----------------------------------+
| Health Score        : 100/100     |
+-----------------------------------+
```

---

## Requirements

- **Bash 4.0+**
- Standard Linux utilities (all optional, detected at runtime):
  `df`, `ip`, `getent`, `ping`, `free`, `nproc`, `systemctl`, `uname`,
  `uptime`.
- No root privileges. No third-party packages.

The toolkit runs fine even if several optional tools are missing or if there
are no temperature sensors / battery — it prints a clear notice and continues.

---

## Installation

```bash
# Clone the repository
git clone https://github.com/makar-ne-robot/Linux-Diagnostic-Toolkit.git
cd Linux-Diagnostic-Toolkit

# Make the entry points executable
chmod +x main.sh tests/test.sh
```

No build step is required. Optionally, add it to your `PATH`:

```bash
ln -s "$PWD/main.sh" ~/.local/bin/ldt
ldt --full
```

---

## Usage

Run the interactive menu:

```bash
./main.sh
```

Run a full diagnostic without the menu:

```bash
./main.sh --full
```

Run diagnostics and write a report:

```bash
./main.sh --report                 # TXT report into ./reports/
./main.sh --json                   # JSON report into ./reports/
./main.sh --full --output ./my-report.txt
./main.sh --full --json --output ./report.json
./main.sh --full --no-network-probes
```

The toolkit can be launched from **any working directory** — it always resolves
its own location, so relative module paths never break. By default reports are
written to `./reports/`, created automatically if missing.

---

## Diagnostic scope

Run only the modules you are interested in (they can be combined):

```bash
./main.sh --disk
./main.sh --cpu
./main.sh --memory
./main.sh --network
./main.sh --services
./main.sh --system
./main.sh --temperature
./main.sh --battery

# Combined
./main.sh --disk --memory
./main.sh --cpu --temperature
./main.sh --disk --network --services
```

Each selected module runs independently; unselected modules are not executed.
Module selection can be combined with report generation, e.g.
`./main.sh --disk --network --json --output ./net.json`.

---

## Command-line flags

| Flag | Description |
|------|-------------|
| `--full` | Run the complete diagnostic suite in non-interactive mode. |
| `--system`, `--cpu`, `--memory`, `--disk`, `--services`, `--network`, `--temperature`, `--battery` | Run only the named module(s). Can be combined. |
| `--report` | Write a TXT report. |
| `--json` | Write a JSON report (implies `--report`). |
| `--output PATH` | Write the report to `PATH` (implies `--report`). If `PATH` is a directory, the default timestamped filename is created inside it. Paths with spaces are supported. |
| `--output=PATH` | Same as above, `=` form. |
| `--no-network-probes` | Skip the external DNS (`example.com`) and ICMP (`1.1.1.1`) probes; local interface/address/route diagnostics still run. |
| `--no-color` | Disable ANSI colored output. |
| `-h`, `--help` | Show help and exit. |
| `-v`, `--version` | Show version and exit. |

Notes:

- Supplying `--output PATH` (or `--json`) automatically enables report
  generation, so `./main.sh --full --output report.txt` creates the report.
- An existing target file is **never overwritten silently**: a notice is
  printed to stderr before writing.
- External network probes require a safe timeout (`timeout`). If it is not
  available, the probes are skipped and reported as `skipped`/`UNKNOWN` rather
  than being run unbounded.

Environment variables:

| Variable | Effect |
|----------|--------|
| `NO_COLOR` | If set to any non-empty value, colors are disabled. |
| `LDT_OUTPUT` | Default report path; overridden by `--output`. |
| `LDT_NO_NETWORK_PROBES` | Set to `1` to skip external network probes. |
| `LDT_TEMP_WARN` | Temperature warning threshold in °C (default `75`). |
| `LDT_TEMP_CRIT` | Temperature critical threshold in °C (default `90`). |

Exit codes: `0` on success, `2` for invalid CLI usage, `1` for report-write
failures.

---

## Health Score

The toolkit reports a **heuristic** health score from `100` down to `0`:

- every `WARNING` finding costs `5` points;
- every `CRITICAL` finding costs `20` points;
- informational messages do not affect the score.

The score maps to one of four statuses: `HEALTHY`, `WARNING`, `CRITICAL`, or
`UNKNOWN` (when no diagnostic data could be collected). Per-area statuses use
the same vocabulary, and areas that could not be evaluated are shown as
`UNKNOWN` / `UNAVAILABLE` rather than `OK`.

The **Network** area is conservative: it reports `OK` only when the required
checks actually ran and found no problem. A probe that could not be performed
(missing `getent`/`ping`/`timeout`, or probes disabled) is treated as
unverified and yields `UNKNOWN`; a probe that ran and failed yields `WARNING`.

> Health Score is a heuristic indicator based on detected diagnostic warnings.
> It is not an objective measurement of hardware health or overall system
> reliability.

---

## Example reports

### TXT

Reports are saved as `linux-diagnostic-report-YYYY-MM-DD_HH-MM-SS.txt`:

```
==============================================================================
                  Linux Diagnostic Toolkit - DIAGNOSTIC REPORT
                            version 1.0.0
==============================================================================
Generated : 2026-01-01 12:00:00 UTC
Hostname  : workstation-01
Kernel    : Linux 6.6.0-generic
Tool      : Linux Diagnostic Toolkit 1.0.0

--------------------------------------------------------------
4. MEMORY INFORMATION
--------------------------------------------------------------
  Total RAM: 15.50 GiB
  Used RAM: 5.10 GiB
  Available RAM: 10.40 GiB
  RAM usage: 33%
Memory usage is normal (33%).

==============================================================================
10. WARNINGS
==============================================================================
[WARNING]  Filesystem / is 83% full.

==============================================================================
11. OVERALL ASSESSMENT
==============================================================================
Informational : 0
Warnings      : 1
Critical      : 0
Health Score  : 95/100 (heuristic)
Status        : WARNING

Note: Health Score is a heuristic indicator based on detected diagnostic
warnings. It is not an objective measurement of hardware health or overall
system reliability.

Result: Minor issues detected. Review the warnings above.
```

The report sections are:

1. Header and generation date
2. System information
3. CPU information
4. Memory information
5. Disk usage
6. System services
7. Network
8. Hardware temperatures
9. Battery
10. Warnings (INFO / WARNING / CRITICAL)
11. Overall assessment (status + heuristic health score)

### JSON

`--json` writes a structured document (saved as
`linux-diagnostic-report-YYYY-MM-DD_HH-MM-SS.json`):

```json
{
  "tool": { "name": "Linux Diagnostic Toolkit", "version": "1.0.0" },
  "timestamp": "2026-01-01T12:00:00Z",
  "system": { "distribution": "ExampleOS 1.0", "kernel": "6.6.0-generic" },
  "cpu": { "logical_cores": 8, "load_average": { "1min": 0.42 } },
  "memory": { "total_kb": 16252928, "usage_percent": 33 },
  "disk": { "filesystems": [ { "mount": "/", "use_percent": 83 } ] },
  "services": { "manager_state": "running", "failed": 0 },
  "network": {
    "probes_enabled": true,
    "dns_resolution": true,
    "dns_probe": "ok",
    "external_reachable": true,
    "external_probe": "ok"
  },
  "temperature": { "available": true, "sensors": [] },
  "battery": { "available": false, "batteries": [] },
  "warnings": [ { "level": "WARN", "message": "Filesystem / is 83% full." } ],
  "health_score": {
    "score": 95,
    "type": "heuristic",
    "status": "WARNING",
    "explanation": "Health Score is a heuristic indicator ..."
  }
}
```

Numeric values are emitted as JSON numbers, missing values as `null`, strings
are escaped, and list data is emitted as JSON arrays.

---

## Project structure

```
Linux-Diagnostic-Toolkit/
├── main.sh              # CLI entry point, argument parsing, menu
├── modules/
│   ├── system.sh        # distribution, kernel, uptime
│   ├── disk.sh          # space + inode usage
│   ├── cpu.sh           # model, cores, load average
│   ├── memory.sh        # RAM and swap
│   ├── services.sh      # init system / systemd units
│   ├── network.sh       # interfaces, routes, DNS, connectivity
│   ├── temperature.sh   # thermal / hwmon sensors
│   └── battery.sh       # power_supply batteries
├── lib/
│   ├── colors.sh        # ANSI color handling
│   ├── utils.sh         # shared helpers + structured data store
│   └── report.sh        # TXT + JSON assembly, summary, health score
├── reports/             # generated reports (.gitkeep kept)
├── tests/
│   └── test.sh          # isolated test suite with mock commands
├── .github/
│   └── workflows/
│       └── ci.yml       # bash -n + ShellCheck + tests
├── README.md
├── LICENSE
└── .gitignore
```

---

## How it works

Each module exposes a single public function (`system_info`, `cpu_info`,
`memory_info`, `disk_check`, `services_check`, `network_check`,
`temperature_check`, `battery_check`). Modules feed two sinks in
`lib/utils.sh`:

- **Human-readable text** — `emit_*` prints a colored line and appends the
  plain version to the report buffer.
- **Structured data** — `data_set KEY VALUE` (and list arrays such as
  `DISK_ROWS`) record machine-readable findings used by the JSON exporter, the
  summary box and the health score.

`lib/report.sh` then assembles either the TXT document, the JSON document, or
the terminal summary box from these shared sources, so TXT and JSON never
diverge.

---

## Privacy & Security

**What is collected.** Diagnostics are read from local, read-only sources:
`/proc`, `/etc/os-release`, `/etc/resolv.conf`, `df`, `ip`, systemd unit
state, and `/sys` (thermal, hwmon, power_supply).

**External network requests.** When network probes are enabled (the default),
the toolkit sends a small amount of traffic off the machine:

- a single **DNS lookup** for `example.com` (via `getent`), and
- a single **ICMP echo** (one packet) to `1.1.1.1` (via `ping`).

Both probes are time-bounded and are skipped automatically when a safe timeout
mechanism (`timeout`) is unavailable. They can be disabled entirely with
`--no-network-probes` (or `LDT_NO_NETWORK_PROBES=1`), which keeps local
interface, address and route diagnostics but performs **no** external DNS or
ICMP traffic. When probes are disabled, the report records the probe state as
`disabled` rather than `ok`.

**What may appear in a report.** Reports are saved locally and can contain
potentially sensitive or identifying information, including:

- the **hostname**;
- **local IP addresses**, the default route and DNS servers;
- **filesystem/device names** and mount points;
- the list of **system services** and any failed units;
- CPU model, kernel version and OS details.

**Where reports are stored.** By default in `./reports/` inside the project
directory (created automatically). Use `--output` / `LDT_OUTPUT` to choose
another location. Reports are only written when you request them (`--report`,
`--json` or `--output`); they are never uploaded anywhere.

**Before sharing a report.** Review it and redact anything you consider
sensitive — in particular the hostname and local IP addresses.

**What the toolkit does not do.** The toolkit does not modify system
configuration, install packages, or change service states. It performs limited
network connectivity checks and writes reports only when requested. It never
runs `sudo`, never restarts services, never changes network or power settings,
and never scans third-party devices. Only safe, single-shot diagnostic requests
are used.

---

## Testing

The test suite is self-contained, isolated and read-only — it never modifies
the system and never requires internet access:

```bash
bash tests/test.sh
```

Key properties:

- External commands (`df`, `ip`, `systemctl`, `getent`, `ping`, `free`,
  `nproc`) are replaced with **mock scripts** placed first on `PATH`, giving
  deterministic results and no real network access.
- sysfs inputs (meminfo, os-release, thermal, hwmon, power_supply) are
  redirected through `LDT_*` overrides, so temperature and battery logic is
  tested against controlled fixtures.
- A curated `PATH` missing all optional tools verifies graceful degradation.
- Network probes are exercised with self-contained mock `PATH`s covering every
  combination of `timeout` / `getent` / `ping` / `ip` availability, DNS
  failure, unreachable target and the `--no-network-probes` option — without
  sending any real traffic.
- The suite covers CLI flags (`--output`, `--output=`, `LDT_OUTPUT`,
  precedence, `--no-color`, `--json`, `--no-network-probes`, module selection,
  invalid arguments), report write errors, missing files/commands, systemd
  `running` / `degraded` states, fractional CPU-load comparison, temperature
  threshold validation, TXT and JSON generation (including special characters
  and `null` handling).

Static analysis with [ShellCheck](https://www.shellcheck.net/):

```bash
shellcheck -x -S style main.sh lib/*.sh modules/*.sh tests/test.sh
```

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

1. `bash -n` syntax check of all Bash files;
2. ShellCheck;
3. `bash tests/test.sh`.

The workflow uses minimal permissions (`contents: read`), a job timeout, does
not require root and performs no real network checks.

---

## Compatibility

- **Tested on:** Arch Linux (Bash 5.3).
- **Expected to work on:** Debian, Ubuntu, Fedora, openSUSE, RHEL and other
  systemd-based and non-systemd distributions.
- **Init systems:** full service detail on systemd; other init systems are
  detected and handled gracefully.
- **Bash 4.0+** is required.

---

## Troubleshooting

**Colors are not showing.** Output is not a terminal (piped/redirected), or
`NO_COLOR`/`--no-color` is set. That is intentional.

**`--output` did not create a file in older versions.** Fixed: `--output`
(and `--json`) now imply `--report` automatically.

**"No non-loopback network interfaces found."** The check relies on `ip` or
`/sys/class/net`. Install `iproute2` if missing. The toolkit does not change
network settings.

**"Temperature information unavailable."** No readable sensors were found in
`/sys/class/thermal` or `/sys/class/hwmon`. This is normal on many systems
(especially VMs) and is **not** treated as a fault.

**"Invalid temperature thresholds."** `LDT_TEMP_WARN` / `LDT_TEMP_CRIT` must be
finite numbers with the warning value strictly below the critical value.
Temperature readings are shown but are not classified as normal while the
configuration is invalid.

**Network shows `UNKNOWN`.** A required probe could not be performed — for
example `getent`, `ping` or `timeout` is missing, or probes were disabled with
`--no-network-probes`. `UNKNOWN` means "not verified", not "failed".

**Network probes hang or you are offline.** External probes are time-bounded;
if `timeout` is unavailable they are skipped. Use `--no-network-probes` to run
local-only network diagnostics.

**"No battery detected."** The machine has no battery (e.g. a desktop) or
`/sys/class/power_supply` exposes none. This is **not** treated as a fault.

**"Detailed service inspection is only supported on systemd."** The detected
init system is not systemd; service state is reported generically.

**systemd shows `degraded`.** This is a real unit state and is now reported
correctly (some failed unit is present). The toolkit never restarts anything.

**Report not written.** Ensure the target directory is writable. Use
`--output` to choose a path, e.g. `--output /tmp/report.txt`. Errors are
printed to stderr and the exit code is non-zero.

---

## License

Released under the [MIT License](LICENSE).
