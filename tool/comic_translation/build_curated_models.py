#!/usr/bin/env python3
import argparse
import shutil
from dataclasses import dataclass
from pathlib import Path

import ctranslate2
import sentencepiece as spm
from huggingface_hub import snapshot_download

from convert_marian import convert_model


@dataclass(frozen=True)
class ModelSpec:
    pair: str
    repository: str
    revision: str
    source: str
    target: str
    name: str
    prefix: str
    sample: str
    expected: tuple[str, ...]


MODELS = {
    spec.pair: spec
    for spec in (
        ModelSpec(
            "ja-en",
            "Helsinki-NLP/opus-mt-ja-en",
            "0770961a39ba6bd66305b149c3f4110bcafca2e6",
            "ja",
            "en",
            "OPUS-MT Japanese English INT8",
            "",
            "また明日よろしくね",
            ("tomorrow",),
        ),
        ModelSpec(
            "ko-en",
            "Helsinki-NLP/opus-mt-ko-en",
            "e42d1f41b66194e6d10512f8a27bebc1f4f5097e",
            "ko",
            "en",
            "OPUS-MT Korean English INT8",
            "",
            "내일 다시 만나요",
            ("tomorrow",),
        ),
        ModelSpec(
            "en-zh",
            "Helsinki-NLP/opus-mt-en-zh",
            "408d9bc410a388e1d9aef112a2daba955b945255",
            "en",
            "zh-CN",
            "OPUS-MT English Simplified Chinese INT8",
            ">>cmn_Hans<< ",
            "I will see you tomorrow.",
            ("明天",),
        ),
    )
}


def translate(model_path: Path, spec: ModelSpec, text: str) -> str:
    source = spm.SentencePieceProcessor(model_file=str(model_path / "source.spm"))
    target = spm.SentencePieceProcessor(model_file=str(model_path / "target.spm"))
    tokens = source.encode(spec.prefix + text, out_type=str) + ["</s>"]
    result = ctranslate2.Translator(str(model_path), device="cpu").translate_batch(
        [tokens], beam_size=2, max_decoding_length=128,
    )[0]
    if not result.hypotheses or len(result.hypotheses[0]) >= 128:
        raise RuntimeError(f"{spec.pair} smoke test did not terminate")
    return target.decode(result.hypotheses[0]).strip()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build Venera's verified local translation model set",
    )
    parser.add_argument("--output", type=Path, default=Path("curated_models"))
    parser.add_argument("--cache", type=Path, default=Path(".model_cache"))
    parser.add_argument("--pairs", nargs="+", choices=MODELS, default=list(MODELS))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    built = {}
    for pair in args.pairs:
        spec = MODELS[pair]
        source = Path(snapshot_download(
            spec.repository,
            revision=spec.revision,
            local_dir=args.cache / pair,
            allow_patterns=[
                "config.json",
                "generation_config.json",
                "pytorch_model.bin",
                "source.spm",
                "target.spm",
                "tokenizer_config.json",
                "vocab.json",
                "README.md",
                "metadata.json",
            ],
        ))
        output = args.output / pair
        if output.exists():
            shutil.rmtree(output)
        convert_model(
            str(source),
            output,
            f"helsinki-opus-mt-{pair}-int8",
            spec.revision[:12],
            spec.name,
            spec.source,
            spec.target,
            "Apache-2.0",
            source_prefix=spec.prefix,
            source_eos_token="</s>",
            source_url=f"https://huggingface.co/{spec.repository}/tree/{spec.revision}",
        )
        translated = translate(output, spec, spec.sample)
        if not any(value.lower() in translated.lower() for value in spec.expected):
            raise RuntimeError(
                f"{pair} smoke test failed: {spec.sample!r} -> {translated!r}",
            )
        print(f"{pair}: {spec.sample} -> {translated}")
        built[pair] = output
    if built.keys() >= MODELS.keys():
        chinese = MODELS["en-zh"]
        for pair in ("ja-en", "ko-en"):
            english = translate(built[pair], MODELS[pair], MODELS[pair].sample)
            translated = translate(built["en-zh"], chinese, english)
            if "明天" not in translated:
                raise RuntimeError(f"{pair}>en-zh smoke test failed: {translated!r}")
            print(f"{pair}>en-zh: {MODELS[pair].sample} -> {translated}")
        for source, expected in (
            ("いえいえ", "问题"),
            ("…じゃあ\n食べ終わった\nところで", "吃"),
        ):
            english = translate(built["ja-en"], MODELS["ja-en"], source)
            translated = translate(built["en-zh"], chinese, english)
            if expected not in translated:
                raise RuntimeError(
                    f"ja-en-zh dialogue smoke test failed: "
                    f"{source!r} -> {english!r} -> {translated!r}",
                )
            print(f"ja-en-zh dialogue: {source!r} -> {translated}")


if __name__ == "__main__":
    main()
