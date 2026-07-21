#include <jni.h>
#include <android/log.h>

#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#include <ggml-backend.h>
#include <llama.h>

namespace {

constexpr char kBos[] = "<｜hy_begin▁of▁sentence｜>";
constexpr char kUser[] = "<｜hy_User｜>";
constexpr char kAssistant[] = "<｜hy_Assistant｜>";

std::once_flag backend_once;

void initialize_backend() {
  llama_log_set([](ggml_log_level level, const char* message, void*) {
    if (level >= GGML_LOG_LEVEL_WARN && level <= GGML_LOG_LEVEL_ERROR) {
      __android_log_write(
          level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN,
          "Venera",
          message);
    }
  }, nullptr);
  llama_backend_init();
  ggml_backend_load_all();
}

struct ModelDeleter {
  void operator()(llama_model* value) const { llama_model_free(value); }
};

struct ContextDeleter {
  void operator()(llama_context* value) const { llama_free(value); }
};

struct SamplerDeleter {
  void operator()(llama_sampler* value) const { llama_sampler_free(value); }
};

struct HyMtRuntime {
  std::unique_ptr<llama_model, ModelDeleter> model;
  std::unique_ptr<llama_context, ContextDeleter> context;
  const llama_vocab* vocab;
  int context_size;
  int max_output_tokens;
  int threads;

  HyMtRuntime(
      const std::string& model_path,
      int context_size,
      int max_output_tokens,
      int threads)
      : context_size(context_size),
        max_output_tokens(max_output_tokens),
        threads(threads) {
    std::call_once(backend_once, initialize_backend);
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;
    model.reset(llama_model_load_from_file(model_path.c_str(), model_params));
    if (!model) throw std::runtime_error("Cannot load Hy-MT GGUF model");
    vocab = llama_model_get_vocab(model.get());
    auto context_params = llama_context_default_params();
    context_params.n_ctx = context_size;
    context_params.n_batch = context_size;
    context_params.n_threads = threads;
    context_params.n_threads_batch = threads;
    context_params.no_perf = true;
    context.reset(llama_init_from_model(model.get(), context_params));
    if (!context) throw std::runtime_error("Cannot create Hy-MT context");
  }

  std::vector<llama_token> tokenize(const std::string& text) const {
    const int count = llama_tokenize(
        vocab, text.data(), text.size(), nullptr, 0, false, true);
    if (count >= 0) throw std::runtime_error("Hy-MT tokenizer size failed");
    std::vector<llama_token> tokens(-count);
    const int written = llama_tokenize(
        vocab, text.data(), text.size(), tokens.data(), tokens.size(), false, true);
    if (written != static_cast<int>(tokens.size()))
      throw std::runtime_error("Hy-MT tokenization failed");
    return tokens;
  }

  std::string detokenize(const std::vector<llama_token>& tokens) const {
    if (tokens.empty()) return {};
    const int count = llama_detokenize(
        vocab, tokens.data(), tokens.size(), nullptr, 0, true, false);
    if (count >= 0) throw std::runtime_error("Hy-MT detokenizer size failed");
    std::string text(-count, '\0');
    const int written = llama_detokenize(
        vocab, tokens.data(), tokens.size(), text.data(), text.size(), true, false);
    if (written < 0) throw std::runtime_error("Hy-MT detokenization failed");
    text.resize(written);
    return text;
  }

  std::string translate(const std::string& instruction) {
    const auto prompt = std::string(kBos) + kUser + instruction + kAssistant;
    auto prompt_tokens = tokenize(prompt);
    if (static_cast<int>(prompt_tokens.size()) + max_output_tokens > context_size)
      throw std::runtime_error("Hy-MT prompt exceeds model context");
    llama_memory_clear(llama_get_memory(context.get()), true);
    if (llama_decode(
        context.get(),
        llama_batch_get_one(prompt_tokens.data(), prompt_tokens.size())) != 0) {
      throw std::runtime_error("Hy-MT prompt decoding failed");
    }
    auto params = llama_sampler_chain_default_params();
    params.no_perf = true;
    std::unique_ptr<llama_sampler, SamplerDeleter> sampler(
        llama_sampler_chain_init(params));
    llama_sampler_chain_add(
        sampler.get(), llama_sampler_init_penalties(64, 1.05f, 0.0f, 0.0f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.6f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(0));
    std::vector<llama_token> output;
    for (int i = 0; i < max_output_tokens; ++i) {
      const auto token = llama_sampler_sample(sampler.get(), context.get(), -1);
      if (llama_vocab_is_eog(vocab, token)) return detokenize(output);
      output.push_back(token);
      auto next = token;
      if (llama_decode(
          context.get(), llama_batch_get_one(&next, 1)) != 0) {
        throw std::runtime_error("Hy-MT token decoding failed");
      }
    }
    throw std::runtime_error("Hy-MT output reached the token limit");
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
Java_com_github_wgh136_venera_LocalHyMtNative_create(
    JNIEnv* env,
    jobject,
    jstring model_path,
    jint context_size,
    jint max_output_tokens,
    jint threads) {
  try {
    return reinterpret_cast<jlong>(new HyMtRuntime(
        string_from_java(env, model_path),
        context_size,
        max_output_tokens,
        threads));
  } catch (const std::exception& error) {
    throw_java(env, error);
    return 0;
  }
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_github_wgh136_venera_LocalHyMtNative_translate(
    JNIEnv* env,
    jobject,
    jlong handle,
    jobjectArray texts) {
  try {
    auto* runtime = reinterpret_cast<HyMtRuntime*>(handle);
    if (!runtime) throw std::runtime_error("Hy-MT handle is null");
    const auto count = env->GetArrayLength(texts);
    const auto string_class = env->FindClass("java/lang/String");
    auto output = env->NewObjectArray(count, string_class, nullptr);
    for (jsize i = 0; i < count; ++i) {
      auto text = static_cast<jstring>(env->GetObjectArrayElement(texts, i));
      const auto translated = runtime->translate(string_from_java(env, text));
      env->DeleteLocalRef(text);
      auto value = env->NewStringUTF(translated.c_str());
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
Java_com_github_wgh136_venera_LocalHyMtNative_destroy(
    JNIEnv*,
    jobject,
    jlong handle) {
  delete reinterpret_cast<HyMtRuntime*>(handle);
}
