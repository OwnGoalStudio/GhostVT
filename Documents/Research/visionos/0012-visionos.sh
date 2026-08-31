#!/bin/bash
# visionOS: teach the build system and the Darwin runtime switches that the
# `visionos` OS tag is the iOS shape — UIView + CAMetalLayer, no PTY, no home
# directory — so `-Dtarget=aarch64-visionos` builds the same libghostty iOS gets.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"
if grep -q 'LIBGHOSTTY_SPM_VISIONOS_PATCH' src/build/MetallibStep.zig; then echo "[+] visionos patch already applied"; exit 0; fi

# 1. MetallibStep: xros / xrsimulator SDKs and the -mtargetos flag (the Metal
#    compiler has no -mxros-version-min; it takes -mtargetos=xros<ver>[-simulator]).
perl -0pi -e '
s/(    const sdk = switch \(opts\.target\.result\.os\.tag\) \{\n        \.macos => "macosx",\n        \.ios => switch \(opts\.target\.result\.abi\) \{\n[^}]*\},\n)/$1        \/\/ LIBGHOSTTY_SPM_VISIONOS_PATCH\n        .visionos => switch (opts.target.result.abi) {\n            .simulator => "xrsimulator",\n            else => "xros",\n        },\n/;
s/    const platform_version_arg = switch \(opts\.target\.result\.os\.tag\) \{\n        \.macos => "-mmacos-version-min",\n        \.ios => switch \(opts\.target\.result\.abi\) \{\n            \.simulator => "-mios-simulator-version-min",\n            else => "-mios-version-min",\n        \},\n        else => null,\n    \};\n//;
s/(    else switch \(opts\.target\.result\.os\.tag\) \{\n        \.macos => "10\.14",\n        \.ios => "11\.0",\n)/$1        .visionos => "1.0",\n/;
s/    if \(platform_version_arg\) \|arg\| \{\n        run_ir\.addArgs\(&\.\{b\.fmt\(\n            "\{s\}=\{s\}",\n            \.\{ arg, min_version \},\n        \)\}\);\n    \}\n/    const version_flag: ?[]const u8 = switch (opts.target.result.os.tag) {\n        .macos => b.fmt("-mmacos-version-min={s}", .{min_version}),\n        .ios => switch (opts.target.result.abi) {\n            .simulator => b.fmt("-mios-simulator-version-min={s}", .{min_version}),\n            else => b.fmt("-mios-version-min={s}", .{min_version}),\n        },\n        .visionos => switch (opts.target.result.abi) {\n            .simulator => b.fmt("-mtargetos=xros{s}-simulator", .{min_version}),\n            else => b.fmt("-mtargetos=xros{s}", .{min_version}),\n        },\n        else => null,\n    };\n    if (version_flag) |arg| run_ir.addArgs(&.{arg});\n/;
' src/build/MetallibStep.zig
grep -q 'xrsimulator' src/build/MetallibStep.zig && grep -q 'version_flag' src/build/MetallibStep.zig || { echo "[!] MetallibStep patch failed"; exit 1; }
echo "[+] patched MetallibStep.zig"

# 2. Config.zig: a minimum OS version for visionOS, and the iOS defaults.
perl -0pi -e 's/(        \.ios => \.\{ \.semver = \.\{\n            \.major = \d+,\n            \.minor = \d+,\n            \.patch = \d+,\n        \} \},\n)/$1\n        \/\/ visionOS 1.0 is the first release; nothing here needs newer.\n        .visionos => .{ .semver = .{\n            .major = 1,\n            .minor = 0,\n            .patch = 0,\n        } },\n/' src/build/Config.zig
perl -pi -e 's/^(\s+)\.macos, \.ios => (break :sentry true,|true,)$/$1.macos, .ios, .visionos => $2/' src/build/Config.zig
grep -q '\.visionos => \.{ \.semver' src/build/Config.zig || { echo "[!] Config.zig patch failed"; exit 1; }
echo "[+] patched Config.zig"

# 3. Runtime switches: visionOS takes the iOS arm everywhere.
perl -pi -e 's/^(\s+)\.macos, \.ios => \{\},/$1.macos, .ios, .visionos => {},/; s/^(\s+)\.ios => \.shared,/$1.ios, .visionos => .shared,/; s/^(\s+)\.ios => \{$/$1.ios, .visionos => {/; s/builtin\.os\.tag == \.ios\)/(builtin.os.tag == .ios or builtin.os.tag == .visionos))/g' src/renderer/Metal.zig
perl -pi -e 's/builtin\.os\.tag == \.ios\)/(builtin.os.tag == .ios or builtin.os.tag == .visionos))/g' src/renderer/metal/IOSurfaceLayer.zig
perl -pi -e 's/builtin\.os\.tag != \.ios\)/(builtin.os.tag != .ios and builtin.os.tag != .visionos))/g' src/font/shaper/coretext.zig
perl -pi -e 's/^(\s+)\.ios => NullPty,/$1.ios, .visionos => NullPty,/' src/pty.zig
perl -pi -e 's/^(\s+)\.ios => true,/$1.ios, .visionos => true,/' src/os/desktop.zig
perl -pi -e 's/^(\s+)\.ios => null,/$1.ios, .visionos => null,/; s/^(\s+)\.ios => return path,/$1.ios, .visionos => return path,/' src/os/homedir.zig
perl -pi -e 's/^(\s+)\.ios => return error\.Unimplemented,/$1.ios, .visionos => return error.Unimplemented,/' src/os/open.zig
perl -pi -e 's/^(\s+)\.ios => error\{BufferTooSmall\},/$1.ios, .visionos => error{BufferTooSmall},/' src/config/theme.zig
perl -pi -e 's/^(\s+)\.ios, \.macos => 4, \/\/ mac/$1.ios, .visionos, .macos => 4, \/\/ mac/' src/input/keycodes.zig
perl -pi -e 's/^(\s+)\.ios, \.tvos, \.watchos => false,/$1.ios, .visionos, .tvos, .watchos => false,/' src/cli/tui.zig
perl -pi -e 's/^(\s+)\.freebsd, \.ios, \.macos => \{/$1.freebsd, .ios, .visionos, .macos => {/' src/Command.zig
perl -pi -e 's/^(\s+)\.ios => error\.XcodeiOSSDKNotFound,/$1.ios => error.XcodeiOSSDKNotFound,\n$1.visionos => error.XcodeVisionOSSDKNotFound,/' pkg/apple-sdk/build.zig
for f in src/renderer/Metal.zig src/renderer/metal/IOSurfaceLayer.zig src/font/shaper/coretext.zig src/pty.zig src/os/desktop.zig src/os/homedir.zig src/os/open.zig src/config/theme.zig src/input/keycodes.zig src/cli/tui.zig src/Command.zig pkg/apple-sdk/build.zig; do grep -q visionos "$f" || { echo "[!] $f: visionos arm missing"; exit 1; }; done
echo "[+] all visionos patches applied"

# 4. build.zig: libghostty-vt.dylib is not part of the XCFramework; skip it on
#    visionOS (its libc++ sub-compilation fails there under Zig 0.15.2).
perl -0pi -e 's/    libghostty_vt_shared\.install\(b\.getInstallStep\(\)\);\n/    if (config.target.result.os.tag != .visionos) libghostty_vt_shared.install(b.getInstallStep());\n/' build.zig
grep -q 'os.tag != .visionos) libghostty_vt_shared' build.zig || { echo "[!] build.zig vt install patch failed"; exit 1; }
echo "[+] patched build.zig"
