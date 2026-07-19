#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a Hugging Face Marian model into a Venera local model",
    )
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--source-language", required=True)
    parser.add_argument("--target-language", required=True)
    parser.add_argument("--license", required=True)
    args = parser.parse_args()

    converter = shutil.which("ct2-transformers-converter")
    if converter is None:
        raise RuntimeError(
            "ct2-transformers-converter is missing; install ctranslate2, "
            "transformers and sentencepiece",
        )
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            converter,
            "--model",
            args.model,
            "--output_dir",
            str(args.output),
            "--quantization",
            "int8",
            "--copy_files",
            "source.spm",
            "target.spm",
            "--force",
        ],
        check=True,
    )
    required = {"model.bin", "config.json", "source.spm", "target.spm"}
    names = {path.name for path in args.output.iterdir() if path.is_file()}
    if not required.issubset(names):
        raise RuntimeError(f"Converted model is incomplete: {sorted(required - names)}")
    vocabulary = {"shared_vocabulary.json"}
    if not vocabulary.issubset(names):
        vocabulary = {"source_vocabulary.json", "target_vocabulary.json"}
    if not vocabulary.issubset(names):
        raise RuntimeError("Converted model has no CTranslate2 vocabulary")
    package_files = sorted(required | vocabulary)
    manifest = {
        "schemaVersion": 1,
        "engine": "ctranslate2-marian",
        "id": args.id,
        "version": args.version,
        "displayName": args.name,
        "sourceLanguage": args.source_language,
        "targetLanguage": args.target_language,
        "license": args.license,
        "files": {
            name: digest(args.output / name)
            for name in package_files
        },
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
