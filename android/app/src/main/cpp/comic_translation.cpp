#include <jni.h>

#include <algorithm>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

namespace {

ctranslate2::ReplicaPoolConfig pool_config(int threads) {
  ctranslate2::ReplicaPoolConfig config;
  config.num_threads_per_replica = threads;
  return config;
}

struct TranslationRuntime {
  ctranslate2::Translator translator;
  sentencepiece::SentencePieceProcessor source;
  sentencepiece::SentencePieceProcessor target;
  std::vector<std::string> source_prefix_tokens;
  std::string source_eos_token;
  std::vector<std::string> target_prefix_tokens;
  size_t beam_size;

  TranslationRuntime(const std::string& model_path,
                     const std::string& source_spm,
                     const std::string& target_spm,
                     std::vector<std::string> source_prefix_tokens,
                     std::string source_eos_token,
                     std::vector<std::string> target_prefix_tokens,
                     size_t beam_size,
                     int threads)
      : translator(model_path,
                   ctranslate2::Device::CPU,
                   ctranslate2::ComputeType::INT8,
                   {0},
                   false,
                   pool_config(threads)),
        source_prefix_tokens(std::move(source_prefix_tokens)),
        source_eos_token(std::move(source_eos_token)),
        target_prefix_tokens(std::move(target_prefix_tokens)),
        beam_size(beam_size) {
    const auto source_status = source.Load(source_spm);
    if (!source_status.ok())
      throw std::runtime_error(source_status.ToString());
    const auto target_status = target.Load(target_spm);
    if (!target_status.ok())
      throw std::runtime_error(target_status.ToString());
  }
};

std::string string_from_java(JNIEnv* env, jstring value) {
  const char* raw = env->GetStringUTFChars(value, nullptr);
  if (!raw) throw std::runtime_error("Cannot read Java string");
  std::string result(raw);
  env->ReleaseStringUTFChars(value, raw);
  return result;
}

std::vector<std::string> strings_from_java(JNIEnv* env, jobjectArray values) {
  const auto count = env->GetArrayLength(values);
  std::vector<std::string> result;
  result.reserve(count);
  for (jsize i = 0; i < count; ++i) {
    auto value = static_cast<jstring>(env->GetObjectArrayElement(values, i));
    result.emplace_back(string_from_java(env, value));
    env->DeleteLocalRef(value);
  }
  return result;
}

void throw_java(JNIEnv* env, const std::exception& error) {
  const auto exception = env->FindClass("java/lang/IllegalStateException");
  env->ThrowNew(exception, error.what());
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_github_wgh136_venera_LocalTranslationNative_create(
    JNIEnv* env,
    jobject,
    jstring model_path,
    jstring source_spm,
    jstring target_spm,
    jobjectArray source_prefix_tokens,
    jstring source_eos_token,
    jobjectArray target_prefix_tokens,
    jint beam_size,
    jint threads) {
  try {
    return reinterpret_cast<jlong>(new TranslationRuntime(
        string_from_java(env, model_path),
        string_from_java(env, source_spm),
        string_from_java(env, target_spm),
        strings_from_java(env, source_prefix_tokens),
        string_from_java(env, source_eos_token),
        strings_from_java(env, target_prefix_tokens),
        beam_size,
        threads));
  } catch (const std::exception& error) {
    throw_java(env, error);
    return 0;
  }
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_github_wgh136_venera_LocalTranslationNative_translate(
    JNIEnv* env,
    jobject,
    jlong handle,
    jobjectArray texts) {
  try {
    auto* runtime = reinterpret_cast<TranslationRuntime*>(handle);
    if (!runtime) throw std::runtime_error("Local translation handle is null");
    const auto count = env->GetArrayLength(texts);
    std::vector<std::vector<std::string>> batch;
    batch.reserve(count);
    for (jsize i = 0; i < count; ++i) {
      auto text = static_cast<jstring>(env->GetObjectArrayElement(texts, i));
      std::vector<std::string> pieces;
      const auto status = runtime->source.Encode(string_from_java(env, text), &pieces);
      env->DeleteLocalRef(text);
      if (!status.ok()) throw std::runtime_error(status.ToString());
      pieces.insert(pieces.begin(),
                    runtime->source_prefix_tokens.begin(),
                    runtime->source_prefix_tokens.end());
      if (!runtime->source_eos_token.empty())
        pieces.emplace_back(runtime->source_eos_token);
      batch.emplace_back(std::move(pieces));
    }
    ctranslate2::TranslationOptions options;
    options.beam_size = runtime->beam_size;
    options.max_decoding_length = 256;
    const auto translated = runtime->target_prefix_tokens.empty()
        ? runtime->translator.translate_batch(batch, options)
        : runtime->translator.translate_batch(
              batch,
              std::vector<std::vector<std::string>>(
                  count, runtime->target_prefix_tokens),
              options);
    const auto string_class = env->FindClass("java/lang/String");
    auto output = env->NewObjectArray(count, string_class, nullptr);
    for (jsize i = 0; i < count; ++i) {
      if (translated[i].hypotheses.empty())
        throw std::runtime_error("Local translator returned no hypothesis");
      auto pieces = translated[i].hypotheses[0];
      if (!runtime->target_prefix_tokens.empty()) {
        if (pieces.size() < runtime->target_prefix_tokens.size() ||
            !std::equal(runtime->target_prefix_tokens.begin(),
                        runtime->target_prefix_tokens.end(),
                        pieces.begin())) {
          throw std::runtime_error("Local translator omitted target prefix");
        }
        pieces.erase(pieces.begin(),
                     pieces.begin() + runtime->target_prefix_tokens.size());
      }
      std::string text;
      const auto status = runtime->target.Decode(pieces, &text);
      if (!status.ok()) throw std::runtime_error(status.ToString());
      auto value = env->NewStringUTF(text.c_str());
      env->SetObjectArrayElement(output, i, value);
      env->DeleteLocalRef(value);
    }
    return output;
  } catch (const std::exception& error) {
    throw_java(env, error);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_github_wgh136_venera_LocalTranslationNative_destroy(
    JNIEnv*,
    jobject,
    jlong handle) {
  delete reinterpret_cast<TranslationRuntime*>(handle);
}
