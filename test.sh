#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
libraries=()
while IFS= read -r path; do libraries+=("$path"); done < <(find .build/whisper -name '*.a' -type f)
swiftc -swift-version 5 -DTESTING -O -parse-as-library -module-cache-path .build/swift-cache \
    -import-objc-header Sources/WhisperBridge.h Sources/*.swift \
    Tests/Checks.swift .build/WhisperBridge.o "${libraries[@]}" \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework Security -framework Accelerate -framework Metal -framework MetalKit -lc++ \
    -o .build/checks
.build/checks "$@"
