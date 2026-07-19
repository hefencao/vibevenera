cmake_minimum_required(VERSION 3.16)
project(venera_webp C CXX)

# ============================================================
# libwebp 源码路径
# 支持通过 -DLIBWEBP_PATH=... 指定，或自动从常见位置查找。
# ============================================================
set(LIBWEBP_PATH "$ENV{LIBWEBP_PATH}" CACHE PATH "Path to libwebp source tree")
if(NOT LIBWEBP_PATH)
    set(_candidate_paths
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../libwebp"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../../libwebp"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../libwebp"
        "${CMAKE_CURRENT_SOURCE_DIR}/../libwebp"
        "D:/work/Source/libwebp"
    )
    foreach(_candidate IN LISTS _candidate_paths)
        if(EXISTS "${_candidate}/src/webp/decode.h")
            set(LIBWEBP_PATH "${_candidate}")
            break()
        endif()
    endforeach()
endif()

if(NOT EXISTS "${LIBWEBP_PATH}/src/webp/decode.h")
    message(FATAL_ERROR "libwebp source tree not found. Set LIBWEBP_PATH or place libwebp under a supported path.")
endif()

# ============================================================
# 编译选项
# ============================================================
# 启用 NEON SIMD 优化（arm64-v8a 强制可用，armeabi-v7a 需 -mfpu=neon）
if(ANDROID_ABI STREQUAL "arm64-v8a" OR ANDROID_ABI STREQUAL "armeabi-v7a")
    add_definitions(-DWEBP_HAVE_NEON)
    if(ANDROID_ABI STREQUAL "armeabi-v7a")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mfpu=neon")
    endif()
endif()

# 启用 libwebp 多线程解码（pthread）
add_definitions(-DWEBP_USE_THREAD)

# 注：不使用 -fvisibility=hidden，因为 Dart FFI 需要符号可见

# 包含路径
include_directories(
    ${LIBWEBP_PATH}          # 使 #include "src/webp/decode.h" 等正常工作
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# ============================================================
# libwebp 解码器源文件
# ============================================================

# src/dec/ — 全部必需
set(WEBP_DEC_SOURCES
    ${LIBWEBP_PATH}/src/dec/alpha_dec.c
    ${LIBWEBP_PATH}/src/dec/buffer_dec.c
    ${LIBWEBP_PATH}/src/dec/frame_dec.c
    ${LIBWEBP_PATH}/src/dec/idec_dec.c
    ${LIBWEBP_PATH}/src/dec/io_dec.c
    ${LIBWEBP_PATH}/src/dec/quant_dec.c
    ${LIBWEBP_PATH}/src/dec/tree_dec.c
    ${LIBWEBP_PATH}/src/dec/vp8_dec.c
    ${LIBWEBP_PATH}/src/dec/vp8l_dec.c
    ${LIBWEBP_PATH}/src/dec/webp_dec.c
)

# src/dsp/ — 仅解码必需
set(WEBP_DSP_SOURCES
    ${LIBWEBP_PATH}/src/dsp/cpu.c
    ${LIBWEBP_PATH}/src/dsp/dec.c
    ${LIBWEBP_PATH}/src/dsp/dec_clip_tables.c
    ${LIBWEBP_PATH}/src/dsp/alpha_processing.c
    ${LIBWEBP_PATH}/src/dsp/filters.c
    ${LIBWEBP_PATH}/src/dsp/lossless.c
    ${LIBWEBP_PATH}/src/dsp/rescaler.c
    ${LIBWEBP_PATH}/src/dsp/upsampling.c
    ${LIBWEBP_PATH}/src/dsp/yuv.c
)

# NEON SIMD 优化（arm64-v8a / armeabi-v7a）
if(ANDROID_ABI STREQUAL "arm64-v8a" OR ANDROID_ABI STREQUAL "armeabi-v7a")
    list(APPEND WEBP_DSP_SOURCES
        ${LIBWEBP_PATH}/src/dsp/alpha_processing_neon.c
        ${LIBWEBP_PATH}/src/dsp/dec_neon.c
        ${LIBWEBP_PATH}/src/dsp/filters_neon.c
        ${LIBWEBP_PATH}/src/dsp/lossless_neon.c
        ${LIBWEBP_PATH}/src/dsp/rescaler_neon.c
        ${LIBWEBP_PATH}/src/dsp/upsampling_neon.c
        ${LIBWEBP_PATH}/src/dsp/yuv_neon.c
    )
endif()

# x86 SIMD 优化（x86_64 SSE2/SSE41）
if(ANDROID_ABI STREQUAL "x86_64")
    list(APPEND WEBP_DSP_SOURCES
        ${LIBWEBP_PATH}/src/dsp/alpha_processing_sse2.c
        ${LIBWEBP_PATH}/src/dsp/alpha_processing_sse41.c
        ${LIBWEBP_PATH}/src/dsp/dec_sse2.c
        ${LIBWEBP_PATH}/src/dsp/dec_sse41.c
        ${LIBWEBP_PATH}/src/dsp/filters_sse2.c
        ${LIBWEBP_PATH}/src/dsp/lossless_sse2.c
        ${LIBWEBP_PATH}/src/dsp/lossless_sse41.c
        ${LIBWEBP_PATH}/src/dsp/rescaler_sse2.c
        ${LIBWEBP_PATH}/src/dsp/upsampling_sse2.c
        ${LIBWEBP_PATH}/src/dsp/upsampling_sse41.c
        ${LIBWEBP_PATH}/src/dsp/yuv_sse2.c
        ${LIBWEBP_PATH}/src/dsp/yuv_sse41.c
    )
endif()

# src/utils/ — 仅解码必需
set(WEBP_UTILS_SOURCES
    ${LIBWEBP_PATH}/src/utils/bit_reader_utils.c
    ${LIBWEBP_PATH}/src/utils/color_cache_utils.c
    ${LIBWEBP_PATH}/src/utils/filters_utils.c
    ${LIBWEBP_PATH}/src/utils/huffman_utils.c
    ${LIBWEBP_PATH}/src/utils/palette.c
    ${LIBWEBP_PATH}/src/utils/quant_levels_dec_utils.c
    ${LIBWEBP_PATH}/src/utils/rescaler_utils.c
    ${LIBWEBP_PATH}/src/utils/random_utils.c
    ${LIBWEBP_PATH}/src/utils/thread_utils.c
    ${LIBWEBP_PATH}/src/utils/utils.c
)

# src/demux/ — 动画支持
set(WEBP_DEMUX_SOURCES
    ${LIBWEBP_PATH}/src/demux/demux.c
    ${LIBWEBP_PATH}/src/demux/anim_decode.c
)

# ============================================================
# 构建共享库
# ============================================================
add_library(venera_webp SHARED
    # 我们的 C 封装层
    webp_decoder.c
    webp_stream_source.c
    webp_texture_blit.c    # 动图 native texture 零拷贝 blit（JNI + ANativeWindow）

    # libwebp 解码器
    ${WEBP_DEC_SOURCES}
    ${WEBP_DSP_SOURCES}
    ${WEBP_UTILS_SOURCES}
    ${WEBP_DEMUX_SOURCES}
)

# 链接 Android log 库 + android（ANativeWindow）供 native texture blit 使用
target_link_libraries(venera_webp log android)

# 输出库名为 libvenera_webp.so
set_target_properties(venera_webp PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
)

# Optional on-device comic translation runtime. Build distributions set these
# roots to prebuilt Android CTranslate2 and SentencePiece packages. Keeping the
# runtime optional preserves normal builds while the model files remain
# user-installed data rather than APK assets.
set(CTRANSLATE2_ROOT "$ENV{CTRANSLATE2_ROOT}" CACHE PATH "CTranslate2 Android package")
set(SENTENCEPIECE_ROOT "$ENV{SENTENCEPIECE_ROOT}" CACHE PATH "SentencePiece Android package")
set(_ctranslate2_lib "${CTRANSLATE2_ROOT}/lib/${ANDROID_ABI}/libctranslate2.so")
set(_sentencepiece_lib "${SENTENCEPIECE_ROOT}/lib/${ANDROID_ABI}/libsentencepiece.so")
if(EXISTS "${CTRANSLATE2_ROOT}/include/ctranslate2/translator.h" AND
   EXISTS "${SENTENCEPIECE_ROOT}/include/sentencepiece_processor.h" AND
   EXISTS "${_ctranslate2_lib}" AND EXISTS "${_sentencepiece_lib}")
    add_library(ctranslate2 SHARED IMPORTED)
    set_target_properties(ctranslate2 PROPERTIES IMPORTED_LOCATION "${_ctranslate2_lib}")
    add_library(sentencepiece SHARED IMPORTED)
    set_target_properties(sentencepiece PROPERTIES IMPORTED_LOCATION "${_sentencepiece_lib}")
    add_library(venera_translation SHARED comic_translation.cpp)
    target_compile_features(venera_translation PRIVATE cxx_std_17)
    target_include_directories(venera_translation PRIVATE
        "${CTRANSLATE2_ROOT}/include"
        "${SENTENCEPIECE_ROOT}/include"
    )
    target_link_libraries(venera_translation ctranslate2 sentencepiece log)
    set_target_properties(venera_translation PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    )
else()
    message(STATUS "CTranslate2/SentencePiece Android packages not set; local translation disabled")
endif()
