#include <jni.h>

#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

namespace {

struct TranslationRuntime {
  ctranslate2::Translator translator;
  sentencepiece::SentencePieceProcessor source;
  sentencepiece::SentencePieceProcessor target;

  TranslationRuntime(const std::string& model_path,
                     const std::string& source_spm,
                     const std::string& target_spm,
                     int threads)
      : translator(model_path,
                   ctranslate2::Device::CPU,
                   0,
                   ctranslate2::ComputeType::INT8,
                   1,
                   threads) {
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
    jint threads) {
  try {
    return reinterpret_cast<jlong>(new TranslationRuntime(
        string_from_java(env, model_path),
        string_from_java(env, source_spm),
        string_from_java(env, target_spm),
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
      batch.emplace_back(std::move(pieces));
    }
    ctranslate2::TranslationOptions options;
    options.beam_size = 1;
    options.max_decoding_length = 256;
    const auto translated = runtime->translator.translate_batch(batch, options);
    const auto string_class = env->FindClass("java/lang/String");
    auto output = env->NewObjectArray(count, string_class, nullptr);
    for (jsize i = 0; i < count; ++i) {
      if (translated[i].hypotheses.empty())
        throw std::runtime_error("Local translator returned no hypothesis");
      std::string text;
      const auto status = runtime->target.Decode(translated[i].hypotheses[0], &text);
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
