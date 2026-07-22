#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
from dataclasses import dataclass
from pathlib import Path

import ctranslate2
import sentencepiece as spm
from huggingface_hub import hf_hub_download, snapshot_download

from convert_marian import convert_model


@dataclass(frozen=True)
class ModelSpec:
    pair: str
    repository: str
    revision: str
    source: str
    target: str
    name: str
    prefix_tokens: tuple[str, ...]
    sample: str
    expected: tuple[str, ...]


SMALL100_REPOSITORY = "alirezamsh/small100"
SMALL100_REVISION = "8ab680e26a596d2e3d2d2d17ae0f68df1037328c"
HYMT_REPOSITORY = "AngelSlim/Hy-MT1.5-1.8B-2bit-GGUF"
HYMT_REVISION = "ef3a410f443c23a155e563814defc5a933a3a35c"
HYMT_FILE = "Hy-MT1.5-1.8B-2bit.gguf"
HYMT_SHA256 = "46e587d917fc4f6f5bda602f10c4a53da8840240355824bcc0e227559c9cba3e"
LEGACY_MODELS = {
    spec.pair: spec
    for spec in (
        ModelSpec(
            "ja-en",
            "Helsinki-NLP/opus-mt-ja-en",
            "0770961a39ba6bd66305b149c3f4110bcafca2e6",
            "ja", "en", "OPUS-MT Japanese English INT8", (),
            "また明日よろしくね", ("tomorrow",),
        ),
        ModelSpec(
            "ko-en",
            "Helsinki-NLP/opus-mt-ko-en",
            "e42d1f41b66194e6d10512f8a27bebc1f4f5097e",
            "ko", "en", "OPUS-MT Korean English INT8", (),
            "내일 다시 만나요", ("tomorrow",),
        ),
        ModelSpec(
            "en-zh",
            "Helsinki-NLP/opus-mt-en-zh",
            "408d9bc410a388e1d9aef112a2daba955b945255",
            "en", "zh-CN", "OPUS-MT English Simplified Chinese INT8",
            (">>cmn_Hans<<",), "I will see you tomorrow.", ("明天",),
        ),
    )
}


def file_digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(4 * 1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def build_hymt(output_root: Path, cache: Path) -> Path:
    source = Path(hf_hub_download(
        repo_id=HYMT_REPOSITORY,
        filename=HYMT_FILE,
        revision=HYMT_REVISION,
        cache_dir=cache,
    ))
    digest = file_digest(source)
    if digest != HYMT_SHA256:
        raise RuntimeError(f"Hy-MT SHA-256 mismatch: {digest}")
    output = output_root / "hy-mt1.5-1.8b-2bit"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    shutil.copyfile(source, output / "model.gguf")
    manifest = {
        "schemaVersion": 5,
        "engine": "llama.cpp-hymt",
        "id": "hy-mt1.5-1.8b-2bit",
        "version": HYMT_REVISION[:12],
        "displayName": "Hy-MT1.5-1.8B 2-bit",
        "sourceLanguages": ["ja", "ko"],
        "targetLanguage": "zh-CN",
        "license": "Tencent Hunyuan Community License",
        "sourcePrefixTokens": [],
        "sourceEosToken": "",
        "targetPrefixTokens": [],
        "beamSize": 1,
        "promptTemplate": (
            "将以下文本翻译为{target_language}，"
            "注意只需要输出翻译后的结果，不要额外解释：\n\n{text}"
        ),
        "contextSize": 1024,
        "maxOutputTokens": 64,
        "sourceUrl": (
            f"https://huggingface.co/{HYMT_REPOSITORY}/tree/{HYMT_REVISION}"
        ),
        "files": {"model.gguf": digest},
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return output


def translate(model_path: Path, text: str) -> str:
    manifest = json.loads(
        (model_path / "manifest.json").read_text(encoding="utf-8"),
    )
    source = spm.SentencePieceProcessor(model_file=str(model_path / "source.spm"))
    target = spm.SentencePieceProcessor(model_file=str(model_path / "target.spm"))
    tokens = (
        list(manifest["sourcePrefixTokens"])
        + source.encode(text, out_type=str)
        + [manifest["sourceEosToken"]]
    )
    target_prefix = manifest["targetPrefixTokens"]
    options = {
        "beam_size": manifest["beamSize"],
        "max_decoding_length": 256,
    }
    if target_prefix:
        options["target_prefix"] = [target_prefix]
    result = ctranslate2.Translator(
        str(model_path), device="cpu",
    ).translate_batch([tokens], **options)[0]
    if not result.hypotheses or len(result.hypotheses[0]) >= 256:
        raise RuntimeError("Smoke test did not terminate")
    pieces = result.hypotheses[0]
    if target_prefix:
        if pieces[:len(target_prefix)] != target_prefix:
            raise RuntimeError("Target prefix was not preserved")
        pieces = pieces[len(target_prefix):]
    return target.decode(pieces).strip()


def build_small100(output_root: Path, cache: Path) -> Path:
    source = Path(snapshot_download(
        SMALL100_REPOSITORY,
        revision=SMALL100_REVISION,
        local_dir=cache / "small100",
        allow_patterns=[
            "config.json", "generation_config.json", "model.safetensors",
            "sentencepiece.bpe.model", "special_tokens_map.json",
            "tokenizer_config.json", "vocab.json",
        ],
    ))
    output = output_root / "small100-ja-ko-zh"
    if output.exists():
        shutil.rmtree(output)
    convert_model(
        str(source), output, "small100-ja-ko-zh-int8",
        SMALL100_REVISION[:12],
        "SMaLL-100 Japanese Korean Chinese INT8",
        ("ja", "ko"), "zh-CN", "MIT",
        source_prefix_tokens=("__zh__",),
        source_eos_token="</s>",
        target_prefix_tokens=("__zh__",),
        beam_size=5,
        source_tokenizer="sentencepiece.bpe.model",
        target_tokenizer="sentencepiece.bpe.model",
        source_url=(
            f"https://huggingface.co/{SMALL100_REPOSITORY}/tree/"
            f"{SMALL100_REVISION}"
        ),
    )
    cases = (
        ("あの", lambda value: any(word in value for word in
          ("那个", "那個", "请问", "請問", "嗯", "呃", "喂"))),
        ("何を\nですか？", lambda value: "什么" in value or "什麼" in value),
        (
            "혹시 비가 오면 어떻게 하죠? 아, 그리고 렌터카는 미리 예약하는 게 좋을 것 같아요.",
            lambda value: "雨" in value and "租" in value,
        ),
    )
    for source_text, valid in cases:
        translated = translate(output, source_text)
        if not valid(translated):
            raise RuntimeError(
                f"SMaLL-100 smoke test failed: {source_text!r} -> {translated!r}",
            )
        print(f"small100: {source_text!r} -> {translated}")
    return output


def build_legacy(
    output_root: Path,
    cache: Path,
    pairs: list[str],
) -> None:
    built = {}
    for pair in pairs:
        spec = LEGACY_MODELS[pair]
        source = Path(snapshot_download(
            spec.repository,
            revision=spec.revision,
            local_dir=cache / pair,
            allow_patterns=[
                "config.json", "generation_config.json", "pytorch_model.bin",
                "source.spm", "target.spm", "tokenizer_config.json",
                "vocab.json", "README.md", "metadata.json",
            ],
        ))
        output = output_root / pair
        if output.exists():
            shutil.rmtree(output)
        convert_model(
            str(source), output, f"helsinki-opus-mt-{pair}-int8",
            spec.revision[:12], spec.name, spec.source, spec.target,
            "Apache-2.0", source_prefix_tokens=spec.prefix_tokens,
            source_eos_token="</s>", beam_size=4,
            source_url=(
                f"https://huggingface.co/{spec.repository}/tree/{spec.revision}"
            ),
        )
        translated = translate(output, spec.sample)
        if not any(value.lower() in translated.lower() for value in spec.expected):
            raise RuntimeError(
                f"{pair} smoke test failed: {spec.sample!r} -> {translated!r}",
            )
        print(f"{pair}: {spec.sample} -> {translated}")
        built[pair] = output
    if built.keys() >= LEGACY_MODELS.keys():
        for pair in ("ja-en", "ko-en"):
            english = translate(built[pair], LEGACY_MODELS[pair].sample)
            translated = translate(built["en-zh"], english)
            if "明天" not in translated:
                raise RuntimeError(f"{pair}>en-zh smoke test failed: {translated!r}")
            print(f"{pair}>en-zh: {LEGACY_MODELS[pair].sample} -> {translated}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build Venera's verified local translation model set",
    )
    parser.add_argument("--output", type=Path, default=Path("curated_models"))
    parser.add_argument("--cache", type=Path, default=Path(".model_cache"))
    parser.add_argument("--small100", action="store_true")
    parser.add_argument("--legacy-opus", action="store_true")
    parser.add_argument("--pairs", nargs="+", choices=LEGACY_MODELS)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    build_hymt(args.output, args.cache)
    if args.small100:
        build_small100(args.output, args.cache)
    if args.legacy_opus or args.pairs:
        build_legacy(args.output, args.cache, args.pairs or list(LEGACY_MODELS))


if __name__ == "__main__":
    main()
