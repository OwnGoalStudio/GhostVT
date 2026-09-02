#!/bin/bash
# Create (or update) a GitHub Release from already-built packages.
#
#   publish-release.sh <tag> <asset> [<asset> ...]
#
# The three platform jobs (roothide .deb, rootless .deb, macOS zip) each
# produce their own artifact. This is the merge step: the tag must already
# exist on the remote, and every file given here is attached to that tag's
# GitHub Release. A machine that was not the one that built a given package
# can still publish — it only needs the files.
#
# Retries on transient API failures. `gh release view` is what decides
# create vs upload, so a 503 is not mistaken for "the release already exists".
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 65
}

command -v gh >/dev/null || die "gh is required"

tag="${1:-}"
shift || true
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must look like v1.2.3 (got '$tag')"
[[ "$#" -ge 1 ]] || die "usage: $0 <tag> <asset> [<asset> ...]"

assets=()
for asset in "$@"; do
    [[ -f "$asset" ]] || die "not a file: $asset"
    assets+=("$asset")
done

repo="${GITHUB_REPOSITORY:-}"
repo_flag=()
if [[ -n "$repo" ]]; then
    repo_flag=(-R "$repo")
fi

echo "==> publishing ${#assets[@]} asset(s) to $tag"
for attempt in 1 2 3 4 5; do
    # `${arr[@]+"${arr[@]}"}`: an empty array is an unbound variable under
    # bash 3.2's `set -u`, which is what /bin/bash is on a Mac.
    if gh release view ${repo_flag[@]+"${repo_flag[@]}"} "$tag" >/dev/null 2>&1; then
        gh release upload ${repo_flag[@]+"${repo_flag[@]}"} "$tag" "${assets[@]}" --clobber && exit 0
    else
        gh release create ${repo_flag[@]+"${repo_flag[@]}"} "$tag" \
            --title "iGhostVT $tag" \
            --generate-notes \
            "${assets[@]}" && exit 0
    fi
    echo "publish attempt ${attempt} failed; retrying in 20s" >&2
    sleep 20
done

die "could not publish $tag after 5 attempts"
