# Linux Diagnostic Toolkit

A modular, safe, read-only **CLI utility written in Bash** for diagnosing the
health of a Linux system and producing a structured plain-text report.

It inspects the system, CPU, memory, disks, services and network, flags
potential problems with color-coded severity, and writes a timestamped report
you can attach to a ticket or keep for later reference.

> The toolkit never modifies your system: no package installation, no `sudo`,
> no service state changes, no network reconfiguration.

---

## Table of contents

- [Features](#features)
- [Screenshot](#screenshot)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Command-line flags](#command-line-flags)
- [Example report](#example-report)
- [Project structure](#project-structure)
- [How it works](#how-it-works)
- [Testing](#testing)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Features

| Area | What is checked |
|------|-----------------|
| **System** | Distribution, OS version, kernel, architecture, hostname, uptime, init system |
| **CPU** | Model, physical/logical cores, architecture, load average (1/5/15 min), running processes |
| **Memory** | Total/used/free/available RAM, swap usage, usage percentage, high-usage warnings |
| **Disk** | Mounted filesystems, size/used/available, usage %, inode usage, >80% / >90% alerts |
| **Services** | Init system detection, systemd active/failed units, `systemd` overall state |
| **Network** | Interfaces and link state, IPv4/IPv6 addresses, default route, DNS servers/resolution, external reachability |

Additional highlights:

- **Modular architecture** — one module per diagnostic domain.
- **ANSI colors** with automatic disable for non-TTY output and `NO_COLOR`.
- **TXT reports** with a timestamped filename, a warnings section and a
  health score.
- **Non-interactive flags** for scripting (`--full`, `--report`, `--output`).
- **Graceful degradation** — missing optional tools never crash the tool.
- **No external dependencies** beyond standard Linux utilities.

---

## Screenshot

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
[8] Generate diagnostic report
[9] Exit

Select an option: 1

--------------------------------------------------------------
2. SYSTEM INFORMATION
--------------------------------------------------------------
  Distribution: Arch Linux
  OS Version: rolling
  Kernel: 7.2.14-arch1-1
  Architecture: x86_64
  Hostname: thinkpad-x390
  Uptime: 1 day, 32 minutes
  Init system: systemd

--------------------------------------------------------------
3. CPU INFORMATION
--------------------------------------------------------------
  Model: Intel(R) Core(TM) i5-8265U CPU @ 1.60GHz
  Architecture: x86_64
  Physical cores: 4
  Logical cores: 8
  Load average: 1m=1.27  5m=1.11  15m=0.72
  Processes: 1/998 (runnable/total)
CPU load is within expected range.

--------------------------------------------------------------
4. MEMORY INFORMATION
--------------------------------------------------------------
  Total RAM: 7.44 GiB
  Used RAM: 3.41 GiB
  Free RAM: 2.33 GiB
  Available RAM: 4.03 GiB
  RAM usage: 45%
  Total swap: 3.72 GiB
  Used swap: 0.00 KiB
  Swap usage: 0%
Memory usage is normal (45%).

--------------------------------------------------------------
5. DISK USAGE
--------------------------------------------------------------
  Filesystem                 Size(1K)   Used(1K)  Avail(1K)   Use%  Mounted on
  /dev/nvme0n1p2             32716560   23008248    8014208    75%  /
  /dev/nvme0n1p3            210961996   68574776  131598152    35%  /home
  /dev/nvme0n1p1              1046512      68572     977940     7%  /boot
Checked 3 filesystem(s).

--------------------------------------------------------------
7. NETWORK
--------------------------------------------------------------
Interface wlp0s20f3: state=UP  IPv4=192.168.1.107/24
  Default route: default via 192.168.1.1 dev wlp0s20f3
  DNS servers: 192.168.1.1
DNS resolution works (resolved example.com).
External connectivity OK (ping 1.1.1.1).
```

---

## Requirements

- **Bash 4.0+**
- Standard Linux utilities (all optional, detected at runtime):
  `df`, `ip`, `getent`, `ping`, `free`, `nproc`, `systemctl`, `uname`,
  `uptime`.
- No root privileges. No third-party packages.

The toolkit runs fine even if several of the optional tools are missing — it
prints a clear notice and continues.

---

## Installation

```bash
# Clone the repository
git clone https://github.com/your-user/linux-diagnostic-toolkit.git
cd linux-diagnostic-toolkit

# Make the entry point executable
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

Run diagnostics and write a report file:

```bash
./main.sh --report
```

Combine flags:

```bash
./main.sh --full --report
./main.sh --full --no-color
./main.sh --full --output ./my-report.txt
```

The toolkit can be launched from **any working directory** — it always resolves
its own location, so relative module paths never break. By default reports are
written to `./reports/`, created automatically if missing.

---

## Command-line flags

| Flag | Description |
|------|-------------|
| `--full` | Run the complete diagnostic suite in non-interactive mode. |
| `--report` | Run diagnostics and write a plain-text (`.txt`) report. |
| `--no-color` | Disable ANSI colored output. |
| `--output PATH` | Write the report to `PATH`. If `PATH` is a directory, the default timestamped filename is used inside it. |
| `-h`, `--help` | Show help and exit. |
| `-v`, `--version` | Show version and exit. |

Environment variables:

| Variable | Effect |
|----------|--------|
| `NO_COLOR` | If set to any non-empty value, colors are disabled. |
| `LDT_OUTPUT` | Alternative way to specify the report output path. |

Exit codes: `0` on success, `2` for invalid CLI usage, `1` for report-write
failures.

---

## Example report

Reports are saved as `linux-diagnostic-report-YYYY-MM-DD_HH-MM-SS.txt`:

```
==============================================================================
                  Linux Diagnostic Toolkit - DIAGNOSTIC REPORT
                            version 1.0.0
==============================================================================
Generated : 2026-11-09 16:37:24 MSK
Hostname  : thinkpad-x390
Kernel    : Linux 7.2.14-arch1-1
Tool      : Linux Diagnostic Toolkit 1.0.0

--------------------------------------------------------------
4. MEMORY INFORMATION
--------------------------------------------------------------
  Total RAM: 7.44 GiB
  Used RAM: 3.41 GiB
  Available RAM: 4.03 GiB
  RAM usage: 45%
  Swap usage: 0%
Memory usage is normal (45%).
...
==============================================================================
8. WARNINGS
==============================================================================
[WARNING]  Filesystem / is 83% full.

==============================================================================
9. OVERALL ASSESSMENT
==============================================================================
Warnings : 1
Critical : 0
Health   : 95/100 (GOOD)

Result: System appears healthy. No action required.
```

The report always follows the same structure:

1. Header and generation date
2. System information
3. CPU information
4. Memory information
5. Disk usage
6. System services
7. Network
8. Warnings
9. Overall assessment (health score)

---

## Project structure

```
linux-diagnostic-toolkit/
├── main.sh              # CLI entry point, argument parsing, menu
├── modules/
│   ├── system.sh        # distribution, kernel, uptime
│   ├── disk.sh          # space + inode usage
│   ├── cpu.sh           # model, cores, load average
│   ├── memory.sh        # RAM and swap
│   ├── services.sh      # init system / systemd units
│   └── network.sh       # interfaces, routes, DNS, connectivity
├── lib/
│   ├── colors.sh        # ANSI color handling
│   ├── utils.sh         # shared helpers + output buffer
│   └── report.sh        # report assembly and scoring
├── reports/             # generated reports (.gitkeep kept)
├── tests/
│   └── test.sh          # self-contained test suite
├── README.md
├── LICENSE
└── .gitignore
```

---

## How it works

Each module exposes a single public function (`system_info`, `cpu_info`,
`memory_info`, `disk_check`, `services_check`, `network_check`). Modules emit
output through helpers in `lib/utils.sh`:

- `emit_*` prints a colored line **and** appends the plain version to an
  in-memory report buffer.
- `add_warning WARN|CRIT "message"` records findings used for the warnings
  section and the health score.

`lib/report.sh` then assembles the header, buffered body, warnings and score
into the final `.txt` file. This keeps terminal output and file output in sync
without duplicating logic.

---

## Testing

The test suite is self-contained and never modifies the system:

```bash
bash tests/test.sh
```

It covers utility helpers, scoring logic, each diagnostic module, graceful
handling of missing files/commands, report generation and every CLI flag.

Static analysis with [ShellCheck](https://www.shellcheck.net/):

```bash
shellcheck -x -S style main.sh lib/*.sh modules/*.sh tests/test.sh
```

---

## Compatibility

- **Tested on:** Arch Linux (Bash 5.3).
- **Expected to work on:** Debian, Ubuntu, Fedora, openSUSE, RHEL and other
  systemd-based and non-systemd distributions.
- **Init systems:** full service detail on systemd; other init systems are
  detected and handled gracefully.
- **Bash 4.0+** is required (uses arrays, `declare -n`-free indirect expansion
  and process substitution).

---

## Troubleshooting

**Colors are not showing.**
Output is not a terminal (piped/redirected), or `NO_COLOR`/`--no-color` is set.
That is intentional.

**"No non-loopback network interfaces found."**
The check relies on `ip` or `/sys/class/net`. Install `iproute2` if missing.
The toolkit does not change network settings.

**"DNS resolution appears to be failing." / "External connectivity check failed."**
The machine may be offline, ICMP may be blocked, or DNS is misconfigured. These
are informational warnings; the toolkit does not attempt to fix anything.

**"Detailed service inspection is only supported on systemd."**
The detected init system is not systemd. Service state is reported
generically.

**Report not written.**
Ensure the target directory is writable. Use `--output` to choose a path, e.g.
`--output /tmp/report.txt`. Errors are printed to stderr.

**`df` output looks empty.**
Some minimal containers expose no real filesystems; the tool reports this as a
warning instead of failing.

---

## License

Released under the [MIT License](LICENSE).
