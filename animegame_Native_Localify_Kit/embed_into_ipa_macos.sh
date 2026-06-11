#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  bash ./embed_into_ipa_macos.sh <input.ipa> [dylib] [output.ipa]

Examples:
  bash ./embed_into_ipa_macos.sh ~/Downloads/app.ipa
  bash ./embed_into_ipa_macos.sh ~/Downloads/app.ipa ./out/animegame_Native_Localify.dylib ./out/app_localify.ipa

Requirements:
  - macOS
  - unzip, zip, otool
  - optool or insert_dylib for adding LC_LOAD_DYLIB
  - codesign, usually provided by Xcode command line tools
USAGE
}

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  usage
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
INPUT_IPA="$1"
DYLIB_PATH="${2:-$ROOT/out/animegame_Native_Localify.dylib}"
OUTPUT_IPA="${3:-}"
LOAD_PATH="${LOAD_PATH:-@rpath/animegame_Native_Localify.dylib}"
EMBED_NAME="animegame_Native_Localify.dylib"

if [ ! -f "$INPUT_IPA" ]; then
  echo "Input IPA not found: $INPUT_IPA" >&2
  exit 1
fi

if [ ! -f "$DYLIB_PATH" ]; then
  echo "Dylib not found: $DYLIB_PATH" >&2
  echo "Build it first with: bash ./build_macos.sh" >&2
  exit 1
fi

if [ -z "$OUTPUT_IPA" ]; then
  input_dir="$(cd "$(dirname "$INPUT_IPA")" && pwd)"
  input_base="$(basename "$INPUT_IPA" .ipa)"
  OUTPUT_IPA="$input_dir/${input_base}_animegame_embed.ipa"
else
  output_dir="$(dirname "$OUTPUT_IPA")"
  mkdir -p "$output_dir"
  OUTPUT_IPA="$(cd "$output_dir" && pwd)/$(basename "$OUTPUT_IPA")"
fi

if ! command -v unzip >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then
  echo "unzip and zip are required" >&2
  exit 1
fi

if ! command -v otool >/dev/null 2>&1; then
  echo "otool is required" >&2
  exit 1
fi

PATCHER=""
if command -v optool >/dev/null 2>&1; then
  PATCHER="optool"
elif command -v insert_dylib >/dev/null 2>&1; then
  PATCHER="insert_dylib"
else
  echo "Need optool or insert_dylib to add LC_LOAD_DYLIB" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$INPUT_IPA" -d "$TMP"
APP_DIR="$(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [ -z "$APP_DIR" ]; then
  echo "Could not find Payload/*.app inside IPA" >&2
  exit 1
fi

PLIST_BUDDY="/usr/libexec/PlistBuddy"
if [ ! -x "$PLIST_BUDDY" ]; then
  echo "PlistBuddy not found at $PLIST_BUDDY" >&2
  exit 1
fi

EXEC_NAME="$($PLIST_BUDDY -c 'Print :CFBundleExecutable' "$APP_DIR/Info.plist")"
MAIN_EXEC="$APP_DIR/$EXEC_NAME"
if [ ! -f "$MAIN_EXEC" ]; then
  echo "Main executable not found: $MAIN_EXEC" >&2
  exit 1
fi

mkdir -p "$APP_DIR/Frameworks"
cp "$DYLIB_PATH" "$APP_DIR/Frameworks/$EMBED_NAME"
chmod 755 "$APP_DIR/Frameworks/$EMBED_NAME"

echo "App: $APP_DIR"
echo "Executable: $EXEC_NAME"
echo "Embedded dylib: Frameworks/$EMBED_NAME"
echo "Load path: $LOAD_PATH"

if otool -l "$MAIN_EXEC" | grep -F "$LOAD_PATH" >/dev/null 2>&1; then
  echo "Load command already exists; skipping Mach-O patch"
else
  case "$PATCHER" in
    optool)
      optool install -c load -p "$LOAD_PATH" -t "$MAIN_EXEC"
      ;;
    insert_dylib)
      insert_dylib --all-yes "$LOAD_PATH" "$MAIN_EXEC" "$MAIN_EXEC.patched"
      mv "$MAIN_EXEC.patched" "$MAIN_EXEC"
      chmod 755 "$MAIN_EXEC"
      ;;
  esac
fi

if ! otool -l "$MAIN_EXEC" | grep -F "$LOAD_PATH" >/dev/null 2>&1; then
  echo "Failed to verify LC_LOAD_DYLIB for $LOAD_PATH" >&2
  exit 1
fi

CODESIGN="${CODESIGN:-$(xcrun --find codesign 2>/dev/null || command -v codesign || true)}"
if [ -n "$CODESIGN" ]; then
  find "$APP_DIR/Frameworks" -type f \( -name '*.dylib' -o -perm -111 \) -print0 | while IFS= read -r -d '' item; do
    "$CODESIGN" -f -s "${IOS_CERTID:--}" "$item" >/dev/null 2>&1 || "$CODESIGN" -f -s - "$item"
  done

  find "$APP_DIR/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0 | while IFS= read -r -d '' item; do
    "$CODESIGN" -f -s "${IOS_CERTID:--}" "$item" >/dev/null 2>&1 || "$CODESIGN" -f -s - "$item"
  done

  "$CODESIGN" -f -s "${IOS_CERTID:--}" "$APP_DIR" >/dev/null 2>&1 || "$CODESIGN" -f -s - "$APP_DIR"
else
  echo "codesign not found; output IPA may need signing by your sideloading tool"
fi

rm -f "$OUTPUT_IPA"
(
  cd "$TMP"
  zip -qry "$OUTPUT_IPA" Payload
)

echo "Output: $OUTPUT_IPA"
