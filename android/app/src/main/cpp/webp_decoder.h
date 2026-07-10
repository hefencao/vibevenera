#ifndef VENERA_WEBP_DECODER_H
#define VENERA_WEBP_DECODER_H

#include <stdint.h>
#include <stddef.h>
#include "webp_stream_source.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ─── 图片信息 ─── */

/**
 * 获取 WebP 图片基本信息。
 * 返回 1 成功，0 失败。
 * is_animated: 1=动画, 0=静态
 */
int webp_get_info(const uint8_t* data, size_t size,
                  int* width, int* height,
                  int* has_alpha, int* is_animated);

/* ─── 静态图片解码 ─── */

/**
 * 将静态 WebP 图片直接解码到目标分辨率。
 * 返回 malloc 分配的 RGBA buffer（4 bytes/pixel），
 * 调用者必须用 webp_free_buffer() 释放。
 * 失败返回 NULL。
 */
uint8_t* webp_decode_scaled(const uint8_t* data, size_t size,
                            int target_width, int target_height,
                            int* out_width, int* out_height);

/* ─── 动画图片解码 ─── */

/**
 * 不透明句柄，管理 WebPDemuxer + 目标尺寸合成画布。
 */
typedef struct WebPAnimContext WebPAnimContext;
typedef struct WebPAnimStreamContext WebPAnimStreamContext;
typedef struct WebPPlaybackCursor WebPPlaybackCursor;

enum {
    WEBP_CURSOR_OK = 0,
    WEBP_CURSOR_INVALID = -20,
    WEBP_CURSOR_STALE_SOURCE = -21,
    WEBP_CURSOR_SOURCE_FAILED = -22,
    WEBP_CURSOR_ALLOCATION_FAILED = -23,
    WEBP_CURSOR_DECODE_FAILED = -24
};

typedef struct {
    uint64_t source_epoch;
    uint64_t committed_length;
    int32_t canvas_width;
    int32_t canvas_height;
    int32_t target_width;
    int32_t target_height;
    int32_t available_frames;
    int32_t next_frame;
    int32_t loop_count;
    int32_t ready;
    int32_t source_sealed;
    int32_t at_available_end;
    int32_t complete;
    int32_t failed;
    int32_t last_error;
} WebPPlaybackCursorState;

WebPPlaybackCursor* webp_playback_cursor_new(
    WebPSourceContext* source,
    int target_width,
    int target_height);

int webp_playback_cursor_get_state(
    WebPPlaybackCursor* cursor,
    WebPPlaybackCursorState* out_state);

int webp_playback_cursor_get_frames(
    WebPPlaybackCursor* cursor,
    int count,
    int64_t* out_results);

int webp_playback_cursor_restart(WebPPlaybackCursor* cursor);

void webp_playback_cursor_set_thread_limit(
    WebPPlaybackCursor* cursor,
    int use_threads);

void webp_playback_cursor_delete(WebPPlaybackCursor* cursor);

/**
 * 创建动画解码器。
 * 内部使用 WebPDemux 解析 + 逐帧 WebPDecode(scaled)，
 * 在目标尺寸画布上自行合成（blend/dispose）。
 * 
 * @param data            WebP 完整数据
 * @param size            数据大小
 * @param target_width    期望画布宽度
 * @param target_height   期望画布高度
 * @param[out] canvas_w   原始画布宽度
 * @param[out] canvas_h   原始画布高度
 * @param[out] frame_count  总帧数
 * @param[out] loop_count   循环次数（0=无限）
 * @param[out] actual_w     实际目标宽度（保持宽高比后）
 * @param[out] actual_h     实际目标高度（保持宽高比后）
 * @return 上下文句柄，失败返回 NULL
 */
WebPAnimContext* webp_anim_decoder_new(
    const uint8_t* data, size_t size,
    int target_width, int target_height,
    int* canvas_width, int* canvas_height,
    int* frame_count, int* loop_count,
    int* actual_width, int* actual_height);

/**
 * 获取下一帧的合成结果（已在目标分辨率）。
 *
 * 从原生缓冲池获取缓冲区，写入 Premultiplied Alpha RGBA 数据
 *（大小 = target_w * target_h * 4）。调用者必须在 GPU 上传完成后
 * 调用 webp_native_pool_release() 归还缓冲区。
 * 失败或无更多帧时返回 NULL。
 *
 * @param ctx            解码器上下文
 * @param[out] duration_ms  该帧的显示时长（毫秒）
 */
uint8_t* webp_anim_decoder_get_frame(WebPAnimContext* ctx,
                                     int* duration_ms);

/**
 * 批量获取 N 帧，结果写入 out_results 数组。
 * out_results 布局：[addr0, dur0, addr1, dur1, ...]，需预分配 count*2 个 int64_t。
 * 返回实际解码的帧数（可能不足 count，表示动画结束）。
 * 单次 FFI 调用替代 N 次 per-frame 调用，消除 FFI 往返开销。
 */
int webp_anim_decoder_get_frames(WebPAnimContext* ctx, int count,
                                 int64_t* out_results);

/**
 * 是否还有更多帧？
 */
int webp_anim_decoder_has_more(WebPAnimContext* ctx);

/**
 * 重置到第一帧。
 */
void webp_anim_decoder_reset(WebPAnimContext* ctx);

/**
 * 销毁解码器，释放所有资源。
 */
void webp_anim_decoder_delete(WebPAnimContext* ctx);

/**
 * 动态调整动画解码器的 libwebp 内部线程数。
 *
 * @param ctx          解码器句柄
 * @param use_threads  线程数量（0 或 1 表示单线程，2 或 3 表示多线程并发）
 */
void webp_anim_decoder_set_thread_limit(WebPAnimContext* ctx, int use_threads);

/**
 * 返回当前存活的解码器数量（调试内存泄漏）。
 */
int webp_anim_decoder_alive_count(void);

/* ─── 流式动画解码：下载过程中追加字节并解码已完整帧 ─── */

WebPAnimStreamContext* webp_anim_stream_decoder_new(
    int target_width, int target_height);

int webp_anim_stream_decoder_append(
    WebPAnimStreamContext* ctx,
    const uint8_t* data, size_t size,
    int is_final);

void webp_anim_stream_decoder_reset_input(WebPAnimStreamContext* ctx);

void webp_anim_stream_decoder_restart_playback(WebPAnimStreamContext* ctx);

int webp_anim_stream_decoder_get_info(
    WebPAnimStreamContext* ctx,
    int* canvas_width, int* canvas_height,
    int* frame_count, int* loop_count,
    int* actual_width, int* actual_height,
    int* is_animated, int* is_ready, int* is_final);

int webp_anim_stream_decoder_get_frames(
    WebPAnimStreamContext* ctx, int count,
    int64_t* out_results);

void webp_anim_stream_decoder_set_thread_limit(
    WebPAnimStreamContext* ctx, int use_threads);

void webp_anim_stream_decoder_delete(WebPAnimStreamContext* ctx);

/* ─── 帧信息提取（用于并行解码） ─── */

/** 单帧信息 */
typedef struct {
    int x_offset, y_offset;   /* 在画布上的偏移 */
    int width, height;        /* 帧原始尺寸 */
    int dispose_method;       /* 0=DISPOSE_NONE, 1=DISPOSE_BACKGROUND */
    int blend_method;         /* 0=NO_BLEND, 1=BLEND */
    int duration;             /* 毫秒 */
    int has_alpha;
    const uint8_t* data;      /* 帧压缩数据指针 */
    size_t data_size;         /* 帧压缩数据大小 */
} WebPFrameInfo;

/** 帧列表 */
typedef struct {
    int canvas_width, canvas_height;  /* 原始画布尺寸 */
    int frame_count;
    WebPFrameInfo* frames;           /* malloc 分配的数组 */
} WebPFrameList;

/**
 * 提取动画所有帧的信息和压缩数据。
 * 返回的 WebPFrameList 需用 webp_free_frame_list 释放。
 */
WebPFrameList* webp_anim_extract_frames(const uint8_t* data, size_t size);

/**
 * 释放帧列表。
 */
void webp_free_frame_list(WebPFrameList* list);

/**
 * 解码单帧压缩数据到目标尺寸（不做画布合成）。
 * 返回 malloc 分配的 RGBA buffer，调用者需 webp_free_buffer。
 * 输出的尺寸 = frame_width * scale, frame_height * scale。
 */
uint8_t* webp_decode_fragment_scaled(
    const uint8_t* frag_data, size_t frag_size,
    int frag_width, int frag_height,
    int target_width, int target_height,
    int* out_width, int* out_height);

/* ─── 内存管理 ─── */

/**
 * 释放 webp_decode_scaled 返回的 buffer。
 */
void webp_free_buffer(uint8_t* buf);

/* ─── 原生缓冲池（Zero-Copy 管线） ─── */

/**
 * 从缓冲池申请一个空闲的原生缓冲区。
 * 如果池中有闲置 buffer 则直接复用；若无，则动态分配。
 * 线程安全。
 */
uint8_t* webp_native_pool_acquire(size_t size);

/**
 * 归还一个原生缓冲区到池中，标记为可重新分配。
 * 如果 ptr 不在池管理范围内，直接 free()。
 */
void webp_native_pool_release(uint8_t* ptr);

/**
 * 彻底销毁缓冲池，释放所有物理内存。
 */
void webp_native_pool_destroy(void);

/**
 * 获取原生缓冲池使用统计（调试内存泄漏）。
 * 返回写入 buf 的字节数，-1 表示错误。
 */
int webp_native_pool_stats(char* buf, int buf_size);

/**
 * 初始化持久化线程池。
 * 必须在创建任何 WebPAnimDecoder 之前调用一次（幂等）。
 * 注入自定义 WorkerInterface，用 8 个持久化 pthread 替代
 * libwebp 默认的 per-call create/destroy。
 */
void webp_init_native(void);

#ifdef __cplusplus
}
#endif

#endif /* VENERA_WEBP_DECODER_H */
