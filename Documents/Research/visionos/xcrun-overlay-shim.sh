#!/bin/bash
if [ "$1" = "--sdk" ] && [ "$2" = "macosx" ] && [ "$3" = "--show-sdk-path" ]; then echo "/private/tmp/claude-501/-Users-qaq-Documents-GitHub-iGhostVT/34c8ec20-e9f5-44bb-a88c-63faaff05605/scratchpad/MacOSX27.0-arm64.sdk"; exit 0; fi
exec /usr/bin/xcrun "$@"
