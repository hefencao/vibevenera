#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def convert_model(
    model: str,
    output: Path,
    model_id: str,
    version: str,
    name: str,
    source_language: str,
    target_language: str,
    license_name: str,
    revision: str | None = None,
    source_prefix: str = "",
    source_eos_token: str = "</s>",
    source_url: str = "",
) -> None:
    try:
        from ctranslate2.converters import TransformersConverter
    except ImportError as error:
        raise RuntimeError(
            "Install ctranslate2, transformers, torch and sentencepiece",
        ) from error
    TransformersConverter(
        model,
        copy_files=["source.spm", "target.spm"],
        revision=revision,
    ).convert(str(output), quantization="int8", force=True)
    required = {"model.bin", "config.json", "source.spm", "target.spm"}
    names = {path.name for path in output.iterdir() if path.is_file()}
    if not required.issubset(names):
        raise RuntimeError(f"Converted model is incomplete: {sorted(required - names)}")
    vocabulary = {"shared_vocabulary.json"}
    if not vocabulary.issubset(names):
        vocabulary = {"source_vocabulary.json", "target_vocabulary.json"}
    if not vocabulary.issubset(names):
        raise RuntimeError("Converted model has no CTranslate2 vocabulary")
    package_files = sorted(required | vocabulary)
    manifest = {
        "schemaVersion": 2,
        "engine": "ctranslate2-marian",
        "id": model_id,
        "version": version,
        "displayName": name,
        "sourceLanguage": source_language,
        "targetLanguage": target_language,
        "license": license_name,
        "sourcePrefix": source_prefix,
        "sourceEosToken": source_eos_token,
        "sourceUrl": source_url,
        "files": {name: digest(output / name) for name in package_files},
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


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
    parser.add_argument("--revision")
    parser.add_argument("--source-prefix", default="")
    parser.add_argument("--source-eos-token", default="</s>")
    parser.add_argument("--source-url", default="")
    args = parser.parse_args()
    convert_model(
        args.model,
        args.output,
        args.id,
        args.version,
        args.name,
        args.source_language,
        args.target_language,
        args.license,
        args.revision,
        args.source_prefix,
        args.source_eos_token,
        args.source_url,
    )


if __name__ == "__main__":
    main()
