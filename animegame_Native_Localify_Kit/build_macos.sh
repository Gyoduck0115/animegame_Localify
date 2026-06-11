#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
OUT="$ROOT/out"
mkdir -p "$BUILD" "$OUT"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Xcode command line tools are required" >&2
  exit 1
fi

python3 "$ROOT/make_translation_blob.py" "$ROOT/g.js" "$BUILD/hso_translation_blob.bin" "$BUILD/hso_translation_blob.S"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANGXX="$(xcrun --sdk iphoneos --find clang++)"
CODESIGN="$(xcrun --find codesign 2>/dev/null || command -v codesign || true)"

"$CLANGXX" \
  -target arm64-apple-ios13.0 \
  -isysroot "$SDK" \
  -std=c++17 \
  -stdlib=libc++ \
  -fvisibility=hidden \
  -Os \
  -dynamiclib \
  "$ROOT/animegame_native_localify.mm" \
  "$BUILD/hso_translation_blob.S" \
  -install_name "@rpath/animegame_Native_Localify.dylib" \
  -o "$OUT/animegame_Native_Localify.dylib"

if [ -n "$CODESIGN" ]; then
  "$CODESIGN" -f -s "${IOS_CERTID:--}" "$OUT/animegame_Native_Localify.dylib" >/dev/null 2>&1 || \
    "$CODESIGN" -f -s - "$OUT/animegame_Native_Localify.dylib"
fi

if command -v lipo >/dev/null 2>&1; then
  lipo -info "$OUT/animegame_Native_Localify.dylib"
fi

echo "Output: $OUT/animegame_Native_Localify.dylib"
