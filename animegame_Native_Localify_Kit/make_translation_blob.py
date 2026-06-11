#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


MAGIC = b"HSONTR1\0"


def find_translation_object(source: str) -> str:
    marker = "var translation_default = "
    start = source.find(marker)
    if start < 0:
        raise SystemExit("Could not find translation_default in g.js")

    start += len(marker)
    while start < len(source) and source[start].isspace():
        start += 1
    if start >= len(source) or source[start] != "{":
        raise SystemExit("translation_default is not an object literal")

    depth = 0
    in_string = False
    escaped = False
    quote = ""

    for index in range(start, len(source)):
        ch = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                in_string = False
            continue

        if ch == '"' or ch == "'":
            in_string = True
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]

    raise SystemExit("Could not find end of translation_default object")


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract translation_default from g.js into a compact binary blob")
    parser.add_argument("g_js", type=Path)
    parser.add_argument("blob", type=Path)
    parser.add_argument("assembly", type=Path)
    args = parser.parse_args()

    source = args.g_js.read_text("utf-8")
    object_text = find_translation_object(source)
    data = json.loads(object_text)
    if not isinstance(data, dict):
        raise SystemExit("translation_default did not decode as a JSON object")

    args.blob.parent.mkdir(parents=True, exist_ok=True)
    args.assembly.parent.mkdir(parents=True, exist_ok=True)

    items = sorted(((str(k), str(v)) for k, v in data.items()), key=lambda item: item[0])
    with args.blob.open("wb") as out:
        out.write(MAGIC)
        out.write(struct.pack("<I", len(items)))
        for key, value in items:
            key_bytes = key.encode("utf-8")
            value_bytes = value.encode("utf-8")
            out.write(struct.pack("<II", len(key_bytes), len(value_bytes)))
            out.write(key_bytes)
            out.write(value_bytes)

    blob_path = str(args.blob.resolve()).replace("\\", "/").replace('"', '\\"')
    blob_hash = hashlib.sha256(args.blob.read_bytes()).hexdigest()
    args.assembly.write_text(f"""; hso translation blob sha256 {blob_hash}
.section __DATA,__const
.p2align 3
.globl _hso_translation_blob
.globl _hso_translation_blob_end
_hso_translation_blob:
.incbin "{blob_path}"
_hso_translation_blob_end:
.byte 0
""", "utf-8")

    print(f"Extracted {len(items)} translation entries")
    print(f"Blob: {args.blob} ({args.blob.stat().st_size} bytes)")
    print(f"Assembly: {args.assembly}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
