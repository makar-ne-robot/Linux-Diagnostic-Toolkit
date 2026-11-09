#!/usr/bin/env bash
#
# modules/disk.sh - Disk space and inode usage analysis.
#
# Uses `df` in POSIX (-P) mode for stable, parseable columns. Pseudo
# filesystems (tmpfs, devtmpfs, overlay, ...) are excluded where the local df
# supports -x, with a graceful fallback otherwise.

# Pseudo filesystem types excluded from the main listing.
_DISK_EXCLUDES=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x ramfs -x sysfs -x proc)

# _df_space - print `df -P` output for real filesystems.
_df_space() {
    if df -P "${_DISK_EXCLUDES[@]}" >/dev/null 2>&1; then
        df -P "${_DISK_EXCLUDES[@]}" 2>/dev/null
    else
        df -P 2>/dev/null
    fi
}

# _df_inode - print `df -Pi` output for real filesystems.
_df_inode() {
    if df -Pi "${_DISK_EXCLUDES[@]}" >/dev/null 2>&1; then
        df -Pi "${_DISK_EXCLUDES[@]}" 2>/dev/null
    else
        df -Pi 2>/dev/null
    fi
}

# disk_check - run the disk diagnostic.
disk_check() {
    section "5. DISK USAGE"
    mark_ran disk

    if ! has_cmd df; then
        emit_warn "'df' is not available; disk diagnostics skipped."
        add_warning WARN "Disk diagnostics unavailable (df command missing)."
        return 0
    fi

    local header
    header="$(printf '%-24s %10s %10s %10s %6s  %s' 'Filesystem' 'Size(1K)' 'Used(1K)' 'Avail(1K)' 'Use%' 'Mounted on')"
    emit_muted "  $header"

    local line fs size used avail usepct mount
    local fs_count=0
    while IFS= read -r line; do
        # Skip the df header line.
        case "$line" in
            Filesystem*) continue ;;
        esac
        read -r fs size used avail usepct mount <<< "$line"
        [[ -z "$mount" ]] && continue
        fs_count=$(( fs_count + 1 ))

        local row
        row="$(printf '%-24s %10s %10s %10s %6s  %s' "$fs" "$size" "$used" "$avail" "$usepct" "$mount")"

        local pct="${usepct%\%}"
        DISK_ROWS+=("$fs|$size|$used|$avail|$pct|$mount")
        if is_number "$pct" && (( pct >= 90 )); then
            emit_err "  $row"
            add_warning CRIT "Filesystem $mount is ${usepct} full."
        elif is_number "$pct" && (( pct >= 80 )); then
            emit_warn "  $row"
            add_warning WARN "Filesystem $mount is ${usepct} full."
        else
            emit "" "  $row"
        fi
    done < <(_df_space)

    if (( fs_count == 0 )); then
        emit_warn "No mounted filesystems were reported."
        add_warning WARN "No filesystem usage information available."
    else
        emit_ok "Checked $fs_count filesystem(s)."
    fi

    # ------------------------------------------------------------------
    # Inode usage
    # ------------------------------------------------------------------
    emit "" ""
    emit C_BOLD "  Inode usage:"
    local fs_i usepct_i mount_i
    while IFS= read -r line; do
        case "$line" in
            Filesystem*) continue ;;
        esac
        # shellcheck disable=SC2086
        read -r fs_i _ _ _ usepct_i mount_i <<< "$line"
        [[ -z "$mount_i" ]] && continue
        # Some pseudo filesystems report "-" for inode usage.
        [[ "$usepct_i" == "-" ]] && continue
        local pct_i="${usepct_i%\%}"
        INODE_ROWS+=("$fs_i|$pct_i|$mount_i")
        local row_i
        row_i="$(printf '%-24s %6s  %s' "$fs_i" "$usepct_i" "$mount_i")"
        if is_number "$pct_i" && (( pct_i >= 90 )); then
            emit_err "  $row_i"
            add_warning CRIT "Inode usage on $mount_i is ${usepct_i}."
        elif is_number "$pct_i" && (( pct_i >= 80 )); then
            emit_warn "  $row_i"
            add_warning WARN "Inode usage on $mount_i is ${usepct_i}."
        else
            emit "" "  $row_i"
        fi
    done < <(_df_inode)
}
