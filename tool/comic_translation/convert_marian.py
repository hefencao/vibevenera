#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
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
    source_languages: str | tuple[str, ...] | list[str],
    target_language: str,
    license_name: str,
    revision: str | None = None,
    source_prefix_tokens: tuple[str, ...] | list[str] = (),
    source_eos_token: str = "</s>",
    target_prefix_tokens: tuple[str, ...] | list[str] = (),
    beam_size: int = 4,
    source_tokenizer: str = "source.spm",
    target_tokenizer: str = "target.spm",
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
        copy_files=sorted({source_tokenizer, target_tokenizer}),
        revision=revision,
    ).convert(str(output), quantization="int8", force=True)
    for source_name, target_name in (
        (source_tokenizer, "source.spm"),
        (target_tokenizer, "target.spm"),
    ):
        source_path = output / source_name
        target_path = output / target_name
        if source_path != target_path:
            shutil.copy2(source_path, target_path)
    for name in {source_tokenizer, target_tokenizer} - {"source.spm", "target.spm"}:
        (output / name).unlink()
    required = {"model.bin", "config.json", "source.spm", "target.spm"}
    names = {path.name for path in output.iterdir() if path.is_file()}
    if not required.issubset(names):
        raise RuntimeError(f"Converted model is incomplete: {sorted(required - names)}")
    vocabulary = {"shared_vocabulary.json"}
    if not vocabulary.issubset(names):
        vocabulary = {"source_vocabulary.json", "target_vocabulary.json"}
    if not vocabulary.issubset(names):
        raise RuntimeError("Converted model has no CTranslate2 vocabulary")
    source_vocabulary_path = output / (
        "shared_vocabulary.json"
        if "shared_vocabulary.json" in vocabulary
        else "source_vocabulary.json"
    )
    target_vocabulary_path = output / (
        "shared_vocabulary.json"
        if "shared_vocabulary.json" in vocabulary
        else "target_vocabulary.json"
    )
    def tokens(path: Path) -> set[str]:
        data = json.loads(path.read_text(encoding="utf-8"))
        return set(data if isinstance(data, list) else data.keys())
    missing_source = (
        set(source_prefix_tokens) |
        ({source_eos_token} if source_eos_token else set())
    ) - tokens(source_vocabulary_path)
    if missing_source:
        raise RuntimeError(
            f"Source control tokens are absent from vocabulary: {sorted(missing_source)}",
        )
    missing_target = set(target_prefix_tokens) - tokens(target_vocabulary_path)
    if missing_target:
        raise RuntimeError(
            f"Target prefix tokens are absent from vocabulary: {sorted(missing_target)}",
        )
    package_files = sorted(required | vocabulary)
    manifest = {
        "schemaVersion": 5,
        "engine": "ctranslate2-seq2seq",
        "id": model_id,
        "version": version,
        "displayName": name,
        "sourceLanguages": (
            [source_languages] if isinstance(source_languages, str)
            else list(source_languages)
        ),
        "targetLanguage": target_language,
        "license": license_name,
        "sourcePrefixTokens": list(source_prefix_tokens),
        "sourceEosToken": source_eos_token,
        "targetPrefixTokens": list(target_prefix_tokens),
        "beamSize": beam_size,
        "promptTemplate": "",
        "contextSize": 0,
        "maxOutputTokens": 0,
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
    parser.add_argument("--source-language", required=True, action="append")
    parser.add_argument("--target-language", required=True)
    parser.add_argument("--license", required=True)
    parser.add_argument("--revision")
    parser.add_argument("--source-prefix-token", action="append", default=[])
    parser.add_argument("--source-eos-token", default="</s>")
    parser.add_argument("--target-prefix-token", action="append", default=[])
    parser.add_argument("--beam-size", type=int, default=4)
    parser.add_argument("--source-tokenizer", default="source.spm")
    parser.add_argument("--target-tokenizer", default="target.spm")
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
        args.source_prefix_token,
        args.source_eos_token,
        args.target_prefix_token,
        args.beam_size,
        args.source_tokenizer,
        args.target_tokenizer,
        args.source_url,
    )


if __name__ == "__main__":
    main()
