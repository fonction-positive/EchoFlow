#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/vendor build
vendor="$PWD/.build/vendor/whisper.cpp-1.8.3"
if [ ! -f "$vendor/include/whisper.h" ]; then
    curl -fL --retry 2 https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.3.tar.gz -o .build/vendor/whisper.tar.gz
    tar -xzf .build/vendor/whisper.tar.gz -C .build/vendor
fi
cp Sources/DecoderValidation.h "$vendor/src/DecoderValidation.h"
if patch --batch --forward --dry-run --silent -d "$vendor" -p1 < Patches/whisper-1.8.3-validation.patch; then
    patch --batch --forward --silent -d "$vendor" -p1 < Patches/whisper-1.8.3-validation.patch
else
    patch --batch --dry-run --silent -R -d "$vendor" -p1 < Patches/whisper-1.8.3-validation.patch
fi
cmake -S "$vendor" -B .build/whisper -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build .build/whisper --config Release -j 6
clang++ -std=c++17 -O2 -mmacosx-version-min=15.0 -I "$vendor/include" -I "$vendor/ggml/include" \
    -c Sources/WhisperBridge.cpp -o .build/WhisperBridge.o
app="${LIVE_TRANSLATE_APP:-$PWD/build/EchoFlow.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Silero-VAD-LICENSE.txt "$app/Contents/Resources/"
# Remove model resources left by older builds; models now live in Application Support.
rm -f "$app/Contents/Resources/ggml-large-v3-turbo.bin" "$app/Contents/Resources/ggml-silero-v6.2.0.bin"
cp "$vendor/LICENSE" "$app/Contents/Resources/Whisper-LICENSE.txt"
libraries=()
while IFS= read -r path; do libraries+=("$path"); done < <(find .build/whisper -name '*.a' -type f)
swiftc -swift-version 5 -O -parse-as-library -module-cache-path .build/swift-cache \
    -import-objc-header Sources/WhisperBridge.h Sources/*.swift .build/WhisperBridge.o "${libraries[@]}" \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework Security \
    -framework Accelerate -framework Metal -framework MetalKit -lc++ \
    -o "$app/Contents/MacOS/LiveTranslate"
codesign --force --sign - "$app"
printf '\nBuilt: %s\n' "$app"
