# animegame Native Localify Kit

LiveContainer Tweaks 환경에서 사용할 수 있는 native iOS dylib 빌드 키트입니다.

## 포함 파일

- `build_macos.sh`: macOS/Xcode 기반 iOS arm64 dylib 빌드 스크립트
- `animegame_native_localify.mm`: native IL2CPP hook 구현
- `make_translation_blob.py`: `g.js`의 `translation_default`를 native blob으로 변환
- `manifest.json`: 현재 키트 메타데이터

## 별도 준비 파일

`g.js`는 크기가 커서 저장소에 포함하지 않습니다. 빌드할 때 이 폴더 안에 직접 넣어주세요.

```text
animegame_Native_Localify_Kit/g.js
```

## 빌드

```bash
cd animegame_Native_Localify_Kit
export IOS_CERTID=-
bash ./build_macos.sh
```

결과물:

```text
out/animegame_Native_Localify.dylib
```

LiveContainer Tweaks 폴더에는 빌드된 dylib 하나만 넣고 실행하면 됩니다.

## 로그

실행 후 앱 샌드박스 내부에 로그가 기록됩니다.

```text
Documents/hso_native_localify.log
```

주요 확인 문자열:

```text
[HSO_NATIVE] pointer-hooked
[HSO_NATIVE] resolved UnityEngine.TextAsset::get_text icall
[HSO_NATIVE] icall-cache-hooked TextAsset.get_text
[HSO_NATIVE] TEXT_ID asset
```
