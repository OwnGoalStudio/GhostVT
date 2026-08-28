# iGhostVT Xcode build and jailbreak Debian packaging (roothide, rootless)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/iGhostVT.xcodeproj
SCHEME              := iGhostVT
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/ighostvt-deriveddata
APP_BUNDLE          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/iGhostVT.app
DAEMON_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/ighostvtd
DAEMON_SCHEME       := ighostvtd
PACKAGE_ID          ?= wiki.qaq.ighostvt
BUNDLE_ID           := wiki.qaq.iGhostVT
PROJECT_OBJECT_VERSION := 77

# Which jailbreak layout the .deb is built for. roothide relocates the package
# into the jbroot it picked this boot, so its paths ship unprefixed; a rootless
# bootstrap lives at a fixed /var/jb that every path in the package has to
# name. The binaries are identical — only the layout and the architecture
# label differ.
PACKAGE_FLAVOR      ?= roothide
ifeq ($(PACKAGE_FLAVOR),roothide)
PACKAGE_PREFIX      :=
PACKAGE_ARCHITECTURE ?= iphoneos-arm64e
else ifeq ($(PACKAGE_FLAVOR),rootless)
PACKAGE_PREFIX      := /var/jb
PACKAGE_ARCHITECTURE ?= iphoneos-arm64
else
$(error PACKAGE_FLAVOR must be roothide or rootless, got '$(PACKAGE_FLAVOR)')
endif
CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
BUILD_NUMBER        := $(call xcconfig_setting,CURRENT_PROJECT_VERSION)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
MAC_DAEMON_LOADER   := $(ROOT_DIR)/Scripts/mac-daemon.sh
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/iGhostVT.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/iGhostVTDaemon.entitlements
APPEX_ENTITLEMENTS  := $(ROOT_DIR)/Packaging/iGhostVTWidgets.entitlements
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/wiki.qaq.ighostvtd.plist

XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation

UNSIGNED_XCODEBUILD := $(XCODEBUILD) \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY=""

DEVICE_XCODEBUILD := $(UNSIGNED_XCODEBUILD) \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif
ifeq ($(BUILD_NUMBER),)
$(error CURRENT_PROJECT_VERSION is missing from Configuration/Version.xcconfig)
endif

.PHONY: all help print-version print-build-number print-deb-path set-version check test harness build deb deb-roothide deb-rootless mac-app mac-daemon mac-daemon-uninstall mac-run clean

all: deb

help:
	@echo "iGhostVT:"
	@echo "  build       Build the unsigned iGhostVT.app for iPhoneOS"
	@echo "  deb         Build, ad-hoc sign, and package the .deb (PACKAGE_FLAVOR=$(PACKAGE_FLAVOR))"
	@echo "  deb-roothide  Package for roothide (unprefixed, iphoneos-arm64e)"
	@echo "  deb-rootless  Package for a rootless bootstrap (/var/jb, iphoneos-arm64)"
	@echo "  test        Run the PTY harness"
	@echo "  harness     Run the daemon's PTY spawn tests on macOS"
	@echo "  check       Validate the project and packaging inputs"
	@echo "  mac-run     Build the Mac Catalyst app, load ighostvtd as a LaunchAgent, open the app"
	@echo "  mac-app     Build the Mac Catalyst app only"
	@echo "  mac-daemon  Build ighostvtd for macOS and (re)load it as a per-user LaunchAgent"
	@echo "  mac-daemon-uninstall  Unload and remove the macOS LaunchAgent"
	@echo "  set-version Write VERSION=x.y.z [BUILD=n] into Configuration/Version.xcconfig"
	@echo "  clean       Remove derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3 [BUILD=42]" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)" $(BUILD)

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: iGhostVT.xcodeproj is missing" >&2; exit 66; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION), got '$$objver'" >&2; exit 65; }
	@grep -qE '^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) =' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: versions must live in Configuration/Version.xcconfig, not project.pbxproj — a target-level value shadows the xcconfig and ships the wrong build number" >&2; exit 65; } || true
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@test -x "$(DEB_PACKAGER)" || { echo "error: package-deb.sh is not executable" >&2; exit 66; }
	@test -x "$(VERSION_APPLIER)" || { echo "error: apply-version.sh is not executable" >&2; exit 66; }
	@test -x "$(MAC_DAEMON_LOADER)" || { echo "error: mac-daemon.sh is not executable" >&2; exit 66; }
	@for xcconfig in Version Base Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 1.2.3, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: CURRENT_PROJECT_VERSION must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@plutil -lint "$(ENTITLEMENTS)"
	@plutil -lint "$(DAEMON_ENTITLEMENTS)" "$(APPEX_ENTITLEMENTS)" "$(LAUNCH_DAEMON)"
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :SoftResourceLimits:NumberOfFiles' "$(LAUNCH_DAEMON)")" == "10240" ]] || { echo "error: the daemon and its shells require a 10240 soft file-descriptor limit" >&2; exit 65; }
	@targets="$$(xcodebuild -project "$(PROJECT)" -list)"; \
		grep -F "ighostvtd" <<<"$$targets" >/dev/null || { echo "error: the ighostvtd target is missing from the project" >&2; exit 65; }

# iGhostVTKit is protocol-only since the TCP transport left; the harness is
# the whole suite until it grows tests again.
test: harness

# The daemon's spawn path on the host, where launchd and the mach service are
# out of reach but forkpty/execve, the read loop, exit decoding, and
# TIOCSWINSZ behave exactly as they do on device.
harness:
	@harness_bin="$$(mktemp /tmp/ighostvt-harness.XXXXXX)"; \
	trap 'rm -f "$$harness_bin"' EXIT; \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Shared/iGhostVTProtocol.swift" \
		$$(ls "$(ROOT_DIR)"/iGhostVTDaemon/*.swift | grep -v '/main\.swift$$') \
		"$(ROOT_DIR)/Tests/PTYHarness/main.swift" \
		-o "$$harness_bin"; \
	"$$harness_bin"

build: check test
	XCBUILD_LABEL=build-ios $(DEVICE_XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS" \
		build
	XCBUILD_LABEL=build-daemon $(DEVICE_XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(DAEMON_SCHEME)" \
		-destination "generic/platform=iOS" \
		build

deb: build
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(APPEX_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(PACKAGE_PREFIX)"

# Both layouts share the build; only the packaging step differs, so these are
# the same recipe with the flavour switched.
deb-roothide:
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=roothide deb

deb-rootless:
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=rootless deb

# Mac Catalyst development harness: the whole stack off-device (AGENTS.md,
# "make mac-run"). The app is signed with *no* entitlements — a Catalyst app
# cannot carry the client one — so the daemon authenticates it by uid and
# bundle path, which only a Debug macOS daemon does; that is why the
# configuration is not a knob.
#
# Ad-hoc by default, since that is what every checkout can do. To sign as
# yourself, pass a Developer ID identity — it needs no provisioning profile,
# which an iOS-family binary would otherwise demand before macOS will launch
# it:
#
#   make mac-run MAC_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
MAC_CONFIGURATION   := Debug
MAC_SIGN_IDENTITY   ?= -
MAC_APP_BUNDLE      := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)-maccatalyst/iGhostVT.app
MAC_DAEMON_BINARY   := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)/ighostvtd
MAC_LAUNCH_AGENT    := $(ROOT_DIR)/Packaging/macOS/wiki.qaq.ighostvtd.plist

mac-app:
	XCBUILD_LABEL=build-mac-app $(UNSIGNED_XCODEBUILD) \
		-configuration "$(MAC_CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "platform=macOS,variant=Mac Catalyst" \
		build
	@test -d "$(MAC_APP_BUNDLE)" || { echo "error: $(MAC_APP_BUNDLE) was not built" >&2; exit 66; }
	@# Nested code first (any embedded framework or bundle), then the app.
	@find "$(MAC_APP_BUNDLE)/Contents" -type d \( -name '*.framework' -o -name '*.appex' \) -print0 2>/dev/null \
		| xargs -0 -n1 -I{} codesign --force --sign "$(MAC_SIGN_IDENTITY)" --timestamp=none "{}"
	codesign --force --sign "$(MAC_SIGN_IDENTITY)" --timestamp=none "$(MAC_APP_BUNDLE)"
	@# A bundle rebuilt and re-signed in place can leave LaunchServices with
	@# a stale registration, and `open` then fails with "Launchd job spawn
	@# failed" while running the executable directly works. Re-register it.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(MAC_APP_BUNDLE)"
	@echo "Built and signed $(MAC_APP_BUNDLE)"

mac-daemon:
	XCBUILD_LABEL=build-mac-daemon $(XCODEBUILD) \
		-configuration "$(MAC_CONFIGURATION)" \
		-scheme "$(DAEMON_SCHEME)" \
		-destination "platform=macOS" \
		build
	"$(MAC_DAEMON_LOADER)" install "$(MAC_DAEMON_BINARY)" "$(MAC_LAUNCH_AGENT)"

mac-daemon-uninstall:
	"$(MAC_DAEMON_LOADER)" uninstall

mac-run: mac-daemon mac-app
	open "$(MAC_APP_BUNDLE)"

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
