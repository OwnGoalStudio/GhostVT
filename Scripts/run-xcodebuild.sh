#!/usr/bin/env bash

set -u -o pipefail

label="${XCBUILD_LABEL:-xcodebuild}"
raw_log="$(mktemp -t "ighostty-${label//\//_}.raw.XXXXXX.log")"
log="$(mktemp -t "ighostty-${label//\//_}.XXXXXX.log")"
trap 'rm -f "$raw_log" "$log"' EXIT

if xcodebuild "$@" >"$raw_log" 2>&1; then
    xcode_status=0
else
    xcode_status=$?
fi

perl -pe 's/\r/\n/g; s/\x08//g; s/\x04//g' "$raw_log" >"$log"

if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify --disable-colored-output --disable-logging <"$log"
else
    cat "$log"
fi

error_pattern='(^|[[:space:]])error:|^\*\* (BUILD|TEST|ARCHIVE|CLEAN|ANALYZE) FAILED \*\*|^Testing failed:|^Failing tests:'
errors_in_log=0
if grep -En "$error_pattern" "$log" >/dev/null 2>&1; then
    errors_in_log=1
fi

if [[ "$xcode_status" -ne 0 || "$errors_in_log" -ne 0 ]]; then
    echo "error: [$label] xcodebuild failed (exit=$xcode_status, errors_in_log=$errors_in_log)" >&2
    if [[ "$errors_in_log" -ne 0 ]]; then
        grep -En "$error_pattern" "$log" | head -40 >&2 || true
    fi
    if [[ "$xcode_status" -ne 0 ]]; then
        exit "$xcode_status"
    fi
    exit 1
fi
