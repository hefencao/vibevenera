cmake_minimum_required(VERSION 3.16)
project(venera_webp C)

# ============================================================
# libwebp 源码路径 — 修改此变量指向你的 libwebp 目录
# ============================================================
set(LIBWEBP_PATH "D:/work/Source/libwebp" CACHE PATH "Path to libwebp source tree")

# ============================================================
# 编译选项
# ============================================================
# 启用 NEON SIMD 优化（arm64-v8a 强制可用）
if(ANDROID_ABI STREQUAL "arm64-v8a")
    add_definitions(-DWEBP_HAVE_NEON)
endif()

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

# NEON SIMD 优化（arm64-v8a）
if(ANDROID_ABI STREQUAL "arm64-v8a")
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

    # libwebp 解码器
    ${WEBP_DEC_SOURCES}
    ${WEBP_DSP_SOURCES}
    ${WEBP_UTILS_SOURCES}
    ${WEBP_DEMUX_SOURCES}
)

# 链接 Android log 库
target_link_libraries(venera_webp log)

# 输出库名为 libvenera_webp.so
set_target_properties(venera_webp PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
)
