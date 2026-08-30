#!/bin/bash
# Replaces /Applications/iGhostVT.app with the macOS zip from a GitHub Release.
#
#   mac-update-from-github.sh [tag]
#
# Tag defaults to the latest release. The zip CI attaches is ad-hoc, so
# Gatekeeper quarantine has to come off; a live helper pins Background Task
# Management to the old cdhash, so the running app has to quit and the old
# agent has to go *before* the bundle is swapped. The harness LaunchAgent
# (`make mac-run`) shares the label `wiki.qaq.ighostvtd` — leaving it loaded
# is the usual kSMErrorInvalidSignature after an install.
#
# Privileged steps (delete + copy into /Applications) go through sudo, which
# on this machine is Touch ID. Unprivileged: download, xattr, quit, bootout.
set -euo pipefail

repo="${GITHUB_REPOSITORY:-OwnGoalStudio/GhostVT}"
dest="/Applications/iGhostVT.app"
label="wiki.qaq.ighostvtd"
bundle_id="wiki.qaq.iGhostVT"
digest_key="MacLaunchAgent.registeredHelperDigest"
domain="gui/$(id -u)"
harness_plist="$HOME/Library/LaunchAgents/$label.plist"

die() {
    echo "error: $*" >&2
    exit 65
}

command -v gh >/dev/null || die "gh is required"
command -v ditto >/dev/null || die "ditto is required"
command -v sudo >/dev/null || die "sudo is required"

tag="${1:-}"
if [[ -z "$tag" ]]; then
    tag="$(gh release view -R "$repo" --json tagName --jq .tagName)"
    [[ -n "$tag" ]] || die "could not resolve the latest GitHub release of $repo"
fi
version="${tag#v}"
asset="iGhostVT-${version}-macos.zip"

echo "==> authenticating as root (Touch ID)"
sudo -v || die "sudo authentication failed"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-update.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

echo "==> downloading $repo $tag ($asset)"
gh release download "$tag" -R "$repo" -p "$asset" -D "$workdir"
zip="$workdir/$asset"
test -f "$zip" || die "release $tag has no $asset"

# Quarantine on the zip would land on the extracted tree. provenance/macl
# cannot be stripped (SIP); the copy into /Applications below drops xattrs.
echo "==> clearing xattrs on the zip"
xattr -cr "$zip"

echo "==> extracting"
ditto -x -k "$zip" "$workdir"
app="$workdir/iGhostVT.app"
test -d "$app" || die "the zip did not contain iGhostVT.app"
test -x "$app/Contents/MacOS/iGhostVT" || die "the app binary is missing"
test -x "$app/Contents/MacOS/ighostvtd" || die "the helper is missing"
test -f "$app/Contents/Library/LaunchAgents/$label.plist" \
    || die "the bundled agent plist is missing"
xattr -cr "$app"

echo "==> quitting the installed app"
# Path-scoped: a plain killall iGhostVT would also take down the Simulator.
osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -f "$dest/Contents/MacOS/iGhostVT" >/dev/null || break
    sleep 0.25
done
if pgrep -f "$dest/Contents/MacOS/iGhostVT" >/dev/null; then
    echo "    force-quitting (a dialog was probably up)"
    pkill -f "$dest/Contents/MacOS/iGhostVT" || true
    sleep 0.5
fi

echo "==> unloading $label"
launchctl bootout "$domain/$label" 2>/dev/null || true
rm -f "$harness_plist"
pkill -x ighostvtd 2>/dev/null || true
pkill -x ighostvtd-io 2>/dev/null || true
defaults delete "$bundle_id" "$digest_key" 2>/dev/null || true

echo "==> replacing $dest"
# One sudo so Touch ID fires once more at most. ditto without xattrs is
# what actually drops SIP-protected provenance the unzip could not.
sudo /bin/bash -c '
    set -euo pipefail
    dest="$1"
    src="$2"
    owner="$3"
    rm -rf "$dest"
    ditto --norsrc --noextattr --noqtn "$src" "$dest"
    xattr -cr "$dest"
    chown -R "$owner:staff" "$dest"
' bash "$dest" "$app" "$(id -un)"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$dest"
fi

echo "==> launching"
open "$dest"

echo "installed $tag at $dest"
echo "allow the helper in Login Items if macOS asks; the app registers it on launch"
