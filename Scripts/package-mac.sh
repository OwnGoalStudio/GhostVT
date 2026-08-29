#!/bin/bash
# Stages, signs, and zips the distributable macOS build of iGhostVT.
#
#   package-mac.sh <app-bundle> <daemon-binary> <agent-plist> \
#                  <app-entitlements> <daemon-entitlements> \
#                  <output-zip> <version> <sign-identity> [notary-profile]
#
# The contract is the one Scripts/package-deb.sh already established: xcodebuild
# produces *unsigned* products and the packager is the only thing that signs.
# That is why the iOS app target must never carry CODE_SIGN_ENTITLEMENTS — the
# device package and this one need different entitlements from the same build.
#
# What comes out is a single app bundle carrying its own helper:
#
#   iGhostVT.app/Contents/MacOS/iGhostVT                    Catalyst GUI
#   iGhostVT.app/Contents/MacOS/ighostvtd                   the only forking process
#   iGhostVT.app/Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist
#
# Neither Mach-O is sandboxed, and that is not a shortcut. Background Task
# Management on macOS 14.2 and later refuses to let a sandboxed app register an
# unsandboxed SMAppService job, and the helper cannot be sandboxed because it
# forkpty/execves the user's shell — every command would inherit the container.
# Hardened Runtime (--options runtime) is applied to both instead.
set -euo pipefail

app_bundle="${1:?usage: $0 <app-bundle> <daemon> <agent-plist> <app-ents> <daemon-ents> <output-zip> <version> <identity> [notary-profile]}"
daemon_binary="${2:?missing daemon binary}"
agent_plist="${3:?missing agent plist}"
app_entitlements="${4:?missing app entitlements}"
daemon_entitlements="${5:?missing daemon entitlements}"
output_zip="${6:?missing output zip}"
version="${7:?missing version}"
sign_identity="${8:?missing signing identity}"
notary_profile="${9:-}"

# The bundled agent is looked up by file name through
# SMAppService.agent(plistName:); MacLaunchAgent.swift names the same file.
agent_plist_name="wiki.qaq.ighostvtd.plist"
# The lowest macOS that can run any of this: SMAppService and BundleProgram are
# 13.0, and so is the daemon's own deployment target. A Catalyst app built for
# iOS 15 otherwise advertises macOS 12, where first launch would register
# nothing and the terminal would never connect.
minimum_system_version="13.0"

die() {
    echo "error: $*" >&2
    exit 65
}

test -d "$app_bundle" || die "$app_bundle is not an app bundle"
test -f "$daemon_binary" || die "$daemon_binary was not built"
test -f "$agent_plist" || die "$agent_plist is missing"
test -f "$app_entitlements" || die "$app_entitlements is missing"
test -f "$daemon_entitlements" || die "$daemon_entitlements is missing"
command -v codesign >/dev/null || die "codesign is required"
command -v ditto >/dev/null || die "ditto is required"

# The sandbox keys must not be here. This is cheap and the failure it prevents
# is expensive: a sandboxed app registers its agent, Background Task Management
# rejects it, and the only symptom is a terminal that never opens.
for entitlements in "$app_entitlements" "$daemon_entitlements"; do
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements" >/dev/null 2>&1; then
        die "$entitlements declares com.apple.security.app-sandbox; see the header of this script"
    fi
done

staging="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-mac-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

staged_app="$staging/$(basename "$app_bundle")"
ditto "$app_bundle" "$staged_app"

# xcodebuild leaves nothing signed (CODE_SIGNING_ALLOWED=NO), but a rebuilt
# bundle can still carry a stale seal from an earlier local `make mac-app`.
rm -rf "$staged_app/Contents/_CodeSignature"

echo "==> staging the helper"
install -m 0755 "$daemon_binary" "$staged_app/Contents/MacOS/ighostvtd"
install -d -m 0755 "$staged_app/Contents/Library/LaunchAgents"
install -m 0644 "$agent_plist" "$staged_app/Contents/Library/LaunchAgents/$agent_plist_name"
plutil -lint "$staged_app/Contents/Library/LaunchAgents/$agent_plist_name" >/dev/null

info_plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum_system_version" "$info_plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum_system_version" "$info_plist"

# codesign hands the entitlements file to AMFI's XML parser, which fails on a
# comment ("AMFIUnserializeXML: syntax error"). The checked-in files carry the
# reasoning for what is *not* in them, which is the part worth keeping, so they
# are normalized through plutil here — same keys, comments dropped — instead of
# being stripped of their explanation in the repo.
normalized_entitlements() {
    local source="$1" destination="$staging/$(basename "$1")"
    plutil -convert xml1 -o "$destination" "$source" \
        || die "$source is not a readable property list"
    echo "$destination"
}
app_entitlements="$(normalized_entitlements "$app_entitlements")"
daemon_entitlements="$(normalized_entitlements "$daemon_entitlements")"

echo "==> signing as ${sign_identity} (hardened runtime)"
# Ad-hoc signatures cannot be timestamped; a real identity should be, because a
# timestamp is what keeps the signature valid after the certificate expires.
timestamp_flag="--timestamp"
if [[ "$sign_identity" == "-" ]]; then
    timestamp_flag="--timestamp=none"
fi

sign() {
    local target="$1"
    shift
    codesign --force --sign "$sign_identity" --options runtime "$timestamp_flag" "$@" "$target"
}

# Inside out: every nested Mach-O has to be sealed before the bundle that
# contains it, or the outer signature seals a file that is about to change.
while IFS= read -r -d '' nested; do
    echo "    nested: ${nested#"$staged_app"/}"
    sign "$nested"
done < <(find "$staged_app/Contents" \
    \( -name '*.framework' -o -name '*.appex' -o -name '*.bundle' -o -name '*.dylib' \) \
    -print0 2>/dev/null)

# The helper carries its own entitlements: it is a separate Mach-O with a
# separate designated requirement, and PeerAuthenticator's macOS branch reads
# that signature to decide who may open a session.
sign "$staged_app/Contents/MacOS/ighostvtd" --entitlements "$daemon_entitlements"
sign "$staged_app" --entitlements "$app_entitlements"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$staged_app"
codesign --display --entitlements - "$staged_app/Contents/MacOS/ighostvtd" >/dev/null

if [[ "$sign_identity" == "-" ]]; then
    # Gatekeeper will refuse an ad-hoc bundle that arrived with a quarantine
    # bit, so there is no point asserting otherwise here. Say it plainly
    # instead — this is the line a person reads before wondering why macOS
    # called the download damaged.
    echo "    ad-hoc signed: recipients must run"
    echo "    xattr -dr com.apple.quarantine /Applications/iGhostVT.app"
else
    spctl --assess --type execute --verbose=2 "$staged_app" || \
        echo "    note: spctl rejected the bundle; it needs notarization before distribution" >&2
fi

mkdir -p "$(dirname "$output_zip")"
rm -f "$output_zip"
# ditto, not zip: it is the archiver Apple's own notarization path expects, and
# it preserves the symlinks and extended attributes a signed bundle needs.
ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$output_zip"

if [[ -n "$notary_profile" && "$sign_identity" != "-" ]]; then
    echo "==> notarizing with keychain profile ${notary_profile}"
    xcrun notarytool submit "$output_zip" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$staged_app"
    rm -f "$output_zip"
    ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$output_zip"
    echo "    stapled"
elif [[ -n "$notary_profile" ]]; then
    echo "    note: notarization skipped; an ad-hoc signature cannot be notarized" >&2
fi

echo "==> iGhostVT $version"
echo "    $output_zip"
ls -lh "$output_zip" | awk '{ print "    " $5 }'
