# animegame Native Localify Kit

This is a native iOS dylib build kit intended for use with LiveContainer Tweaks.

## Included Files

- `build_macos.sh`: macOS/Xcode build script for an iOS arm64 dylib
- `animegame_native_localify.mm`: native IL2CPP hook implementation
- `make_translation_blob.py`: converts `translation_default` from `g.js` into a native binary blob
- `manifest.json`: metadata for the current kit

## Required Local File

`g.js` is not committed to this repository because it is large. Place it in this directory before building:

```text
animegame_Native_Localify_Kit/g.js
```

## Build

```bash
cd animegame_Native_Localify_Kit
export IOS_CERTID=-
bash ./build_macos.sh
```

Output:

```text
out/animegame_Native_Localify.dylib
```

Put only the built dylib into the LiveContainer Tweaks folder, then run the app with JIT enabled.

## Logs

Runtime logs are written inside the app sandbox:

```text
Documents/hso_native_localify.log
```

Useful log markers:

```text
[HSO_NATIVE] pointer-hooked
[HSO_NATIVE] resolved UnityEngine.TextAsset::get_text icall
[HSO_NATIVE] icall-cache-hooked TextAsset.get_text
[HSO_NATIVE] TEXT_ID asset
```

## Notes

The repository intentionally excludes IPA files, built dylibs, logs, zip archives, and local build outputs. Keep those files local.
