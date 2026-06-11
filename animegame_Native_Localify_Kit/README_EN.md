# animegame Native Localify Kit

This is a native iOS dylib build kit intended for use with LiveContainer Tweaks.

## Included Files

- `build_macos.sh`: macOS/Xcode build script for an iOS arm64 dylib
- `embed_into_ipa_macos.sh`: copies the built dylib into an IPA's `Frameworks` directory and adds the load command
- `animegame_native_localify.mm`: native IL2CPP hook implementation
- `make_translation_blob.py`: converts `translation_default` from `g.js` into a native binary blob
- `manifest.json`: metadata for the current kit

## Required Local File

`g.js` is not committed to this repository because it is large. Place it in this directory before building:

```text
animegame_Native_Localify_Kit/g.js
```

## Build The Dylib

```bash
cd animegame_Native_Localify_Kit
export IOS_CERTID=-
bash ./build_macos.sh
```

Output:

```text
out/animegame_Native_Localify.dylib
```

## LiveContainer Tweaks Mode

Put only the built dylib into the LiveContainer Tweaks folder, then run the app with JIT enabled.

## IPA Frameworks Embedding Mode

You can also embed the built dylib into `Payload/*.app/Frameworks/` inside an IPA and add an `LC_LOAD_DYLIB` command to the main executable.

Required tool:

```text
optool or insert_dylib
```

Basic usage:

```bash
bash ./embed_into_ipa_macos.sh /path/to/input.ipa
```

To explicitly choose the dylib and output IPA:

```bash
bash ./embed_into_ipa_macos.sh /path/to/input.ipa ./out/animegame_Native_Localify.dylib ./out/input_animegame_embed.ipa
```

This mode modifies the IPA and requires signing again. LiveContainer or your sideloading tool may need to re-sign the app.

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
