#!/usr/bin/env bash

# Writes the marketing version (and optionally the build number) into
# Configuration/Version.xcconfig, the single source of truth consumed by the
# Xcode project, the Debian control file, and the packaged .deb file name.

set -Eeuo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
    echo "usage: $0 <version> [build-number]" >&2
    exit 64
fi

version="${1#v}"
build_number="${2:-}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: version must look like 1.2.3 (got '$1')" >&2
    exit 64
}
if [[ -n "$build_number" ]]; then
    [[ "$build_number" =~ ^[0-9]+$ ]] || {
        echo "error: build number must be a positive integer (got '$build_number')" >&2
        exit 64
    }
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
version_config="$root_dir/Configuration/Version.xcconfig"
[[ -f "$version_config" ]] || { echo "error: missing $version_config" >&2; exit 66; }

read_setting() {
    awk -F= -v key="$1" '
        $1 ~ "^[[:space:]]*"key"[[:space:]]*$" { gsub(/[[:space:]]/, "", $2); print $2; exit }
    ' "$version_config"
}

[[ -n "$build_number" ]] || build_number="$(read_setting CURRENT_PROJECT_VERSION)"
[[ -n "$build_number" ]] || { echo "error: CURRENT_PROJECT_VERSION is missing from Version.xcconfig" >&2; exit 65; }

updated="$(mktemp "${TMPDIR:-/tmp}/ighostvt-version.XXXXXX")"
trap 'rm -f "$updated"' EXIT

awk -v version="$version" -v build="$build_number" '
    /^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ { print "MARKETING_VERSION = " version; seen_version = 1; next }
    /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/ { print "CURRENT_PROJECT_VERSION = " build; seen_build = 1; next }
    { print }
    END {
        if (!seen_version || !seen_build) { exit 1 }
    }
' "$version_config" >"$updated" || {
    echo "error: Version.xcconfig must define MARKETING_VERSION and CURRENT_PROJECT_VERSION" >&2
    exit 65
}

# A content copy, not ditto: ditto would carry mktemp's 0600 onto the
# checked-in file, and the destination's own mode must survive.
cat "$updated" >"$version_config"

echo "MARKETING_VERSION = $version"
echo "CURRENT_PROJECT_VERSION = $build_number"
