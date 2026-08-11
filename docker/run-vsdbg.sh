#!/bin/sh
set -eu

if [ -n "${VSDBG_TARGET_TMPDIR:-}" ]; then
    TMPDIR=$VSDBG_TARGET_TMPDIR
    export TMPDIR
    exec /vsdbg/vsdbg "$@"
fi

target_tmpdir_file=${VSDBG_TARGET_TMPDIR_FILE:-/diag/vsdbg-target-tmpdir}
if [ -r "$target_tmpdir_file" ]; then
    IFS= read -r TMPDIR < "$target_tmpdir_file"
    if [ -z "$TMPDIR" ]; then
        echo "The vsdbg target temp directory file is empty: $target_tmpdir_file" >&2
        exit 42
    fi

    export TMPDIR
    exec /vsdbg/vsdbg "$@"
fi

for process_dir in /proc/[0-9]*; do
    [ -r "$process_dir/environ" ] || continue

    target_tmp=/tmp
    tmp_entry=$({ tr '\000' '\n' < "$process_dir/environ"; } 2>/dev/null | grep -m 1 '^TMPDIR=' || true)
    if [ -n "$tmp_entry" ]; then
        target_tmp=${tmp_entry#TMPDIR=}
    fi

    case "$target_tmp" in
        /*) ;;
        *) target_tmp=/tmp ;;
    esac

    for socket in "$process_dir/root$target_tmp"/dotnet-diagnostic-*-socket; do
        [ -S "$socket" ] || continue

        TMPDIR=${socket%/*}
        export TMPDIR
        exec /vsdbg/vsdbg "$@"
    done
done

echo "No accessible .NET diagnostic socket was found for vsdbg." >&2
echo "Set VSDBG_TARGET_TMPDIR or write the target path to $target_tmpdir_file if automatic discovery is ambiguous." >&2
exit 42
