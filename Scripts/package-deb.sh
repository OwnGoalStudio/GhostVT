#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "$#" -ne 12 ]]; then
    echo "usage: $0 <app> <daemon> <control> <app-entitlements> <daemon-entitlements> <appex-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <install-prefix>" >&2
    exit 64
fi

app_bundle="$1"
daemon_binary="$2"
control_template="$3"
app_entitlements="$4"
daemon_entitlements="$5"
appex_entitlements="$6"
launch_plist="$7"
output_deb="$8"
package_id="$9"
version="${10}"
architecture="${11}"
# Empty for roothide, which installs into the jbroot it picked this boot, and
# "/var/jb" for a rootless bootstrap, which has to be named in every path the
# package ships — including the ones inside the launch daemon and the
# maintainer scripts.
install_prefix="${12}"

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" \
    "$appex_entitlements" "$launch_plist"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
[[ "$install_prefix" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || { echo "error: invalid install prefix" >&2; exit 64; }

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.iGhostty && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with — refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/ighostty-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
app_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/ighostty-app-entitlements.XXXXXX.plist")"
daemon_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/ighostty-daemon-entitlements.XXXXXX.plist")"
appex_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/ighostty-appex-entitlements.XXXXXX.plist")"
trap 'rm -rf "$staging"; rm -f "$temporary_deb" "$app_signed_entitlements" "$daemon_signed_entitlements" "$appex_signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_root="$staging$install_prefix"
installed_app="$installed_root/Applications/iGhostty.app"
installed_daemon="$installed_root/usr/libexec/ighosttyd"
installed_plist="$installed_root/Library/LaunchDaemons/wiki.qaq.ighosttyd.plist"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$app_bundle" "$installed_app"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
sed -e "s|@PREFIX@|$install_prefix|g" "$launch_plist" >"$installed_plist"
# The daemon recovers its install root by stripping this suffix off its own
# executable path, so the plist has to launch it by the path it is installed
# at — a mismatch and every bootstrap path it derives is wrong.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/ighosttyd" ]] || {
    echo "error: the launch daemon does not point at the installed ighosttyd" >&2
    exit 65
}
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon"
chmod 0644 "$installed_plist"

# Ghostty's shell integration, which is what makes a session report its title,
# its working directory, and its command boundaries. libghostty-spm already
# ships the scripts inside the app's resource bundle; the package installs a
# second copy the daemon owns, because the daemon is what points a new shell
# at them and it should not have to know the app bundle's internal layout to
# do it. Missing scripts are not fatal: the daemon checks before injecting,
# and the app falls back to inferring a title from what the user types.
installed_integration="$installed_root/usr/share/ighostty/shell-integration"
integration_source="$(/usr/bin/find "$installed_app" -type d -name shell-integration -print -quit)"
if [[ -n "$integration_source" ]]; then
    mkdir -p "$(dirname "$installed_integration")"
    /usr/bin/ditto "$integration_source" "$installed_integration"
    # The session runs as mobile, so every script has to be readable by it.
    chmod -R a+rX "$installed_integration"
else
    echo "warning: no shell-integration in the app bundle; sessions will report no title" >&2
fi

ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"
ldid -e "$installed_daemon" >"$daemon_signed_entitlements"

# App extensions are separate Mach-Os with their own signature, so Xcode's is
# as useless to us as the app's and the system refuses to load an appex whose
# signature does not verify. Sign every one the app ships.
shopt -s nullglob
appexes=("$installed_app/PlugIns"/*.appex)
shopt -u nullglob
for appex in "${appexes[@]}"; do
    appex_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
    [[ -f "$appex/$appex_executable" ]] || {
        echo "error: appex $(basename "$appex") has no executable" >&2
        exit 65
    }
    rm -rf "$appex/_CodeSignature"
    ldid -S"$appex_entitlements" -Cadhoc "$appex/$appex_executable"
done

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}

require_false() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == false ]] || {
        echo "error: signed executable is missing entitlement: $key = false" >&2
        exit 65
    }
}

# The privilege-granting entitlements the app and its extensions must not
# carry. Three of these remove the data container, which silently moves
# UserDefaults — preferences and the daemon session ledger — out to the shared
# ~/Library/Preferences; the rest either weaken the sandbox or, in
# `platform-application`'s case, tighten it in ways that then demand still more
# entitlements to undo. Absence is the assertion: `container-required=false`
# *is* the switch, so checking for `false` would pass the very thing it means
# to catch.
#
# If a device test proves one of these is genuinely required (see the ladder in
# Packaging/iGhostty.entitlements), remove it from this list in the same commit
# that adds it to the entitlements — deliberately, and with the symptom that
# forced it written down.
require_unprivileged() {
    local plist="$1"
    local label="$2"
    local key
    for key in platform-application \
        com.apple.private.security.no-sandbox \
        com.apple.private.security.no-container \
        com.apple.private.security.container-required \
        com.apple.private.security.storage.AppDataContainers \
        com.apple.private.skip-library-validation \
        com.apple.security.iokit-user-client-class; do
        [[ -z "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" ]] || {
            echo "error: $label must stay sandboxed and unprivileged: remove $key" >&2
            exit 65
        }
    done
}

# The app's only capability is reaching the daemon: the client entitlement the
# daemon authenticates against, and the mach-lookup exception for the service
# name. Everything privileged happens in ighosttyd, so the app asks for nothing
# else — and the check below is what keeps that true.
require_true "$app_signed_entitlements" wiki.qaq.ighostty.client
require_unprivileged "$app_signed_entitlements" "the app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.ighostty.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}

for entitlement in platform-application com.apple.private.security.no-sandbox; do
    require_true "$daemon_signed_entitlements" "$entitlement"
done
require_false "$daemon_signed_entitlements" com.apple.private.security.container-required

# Spawning belongs to the daemon alone: fail the build if the app ever picks
# up the client entitlement's counterpart on the daemon side by mistake.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :wiki.qaq.ighostty.client' "$daemon_signed_entitlements" 2>/dev/null || true)" != true ]] || {
    echo "error: the daemon must not carry the client entitlement" >&2
    exit 65
}

# Every appex is a second process running under the app's bundle id prefix and
# none of its privileges. The daemon authenticates peers by their binary, so an
# extension carrying the client entitlement would be an entrance nobody
# designed — check what was actually signed, not what the file asked for.
for appex in "${appexes[@]}"; do
    appex_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
    ldid -e "$appex/$appex_executable" >"$appex_signed_entitlements"
    require_unprivileged "$appex_signed_entitlements" "$(basename "$appex")"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :wiki.qaq.ighostty.client' "$appex_signed_entitlements" 2>/dev/null || true)" != true ]] || {
        echo "error: $(basename "$appex") must not carry the client entitlement" >&2
        exit 65
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name' "$appex_signed_entitlements" 2>/dev/null || true)" != *ighostty* ]] || {
        echo "error: $(basename "$appex") must not reach the daemon's mach service" >&2
        exit 65
    }
done

installed_size="$(du -sk "$installed_root/Applications" "$installed_root/usr" "$installed_root/Library" | awk '{total += $1} END {print total}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    "$control_template" >"$debian/control"

packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
for script in postinst prerm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$packaging_root/DEBIAN/$script" >"$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm"

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
grep -F ".$install_prefix/Applications/iGhostty.app/$app_executable" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/libexec/ighosttyd" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Library/LaunchDaemons/wiki.qaq.ighosttyd.plist" <<<"$contents" >/dev/null
[[ -z "$integration_source" ]] || grep -F ".$install_prefix/usr/share/ighostty/shell-integration/zsh/.zshenv" <<<"$contents" >/dev/null

mv -f "$temporary_deb" "$output_deb"
echo "Packaged iGhostty: $output_deb"
shasum -a 256 "$output_deb"
