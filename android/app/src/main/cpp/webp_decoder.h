#ifndef VENERA_WEBP_DECODER_H
#define VENERA_WEBP_DECODER_H

#include <stdint.h>
#include <stddef.h>

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
 * 使用双缓冲：返回指向 output buffer 的指针（Straight Alpha RGBA，
 * 大小 = target_w * target_h * 4）。该指针在接下来两次调用内有效。
 * 失败或无更多帧时返回 NULL。
 *
 * @param ctx            解码器上下文
 * @param[out] duration_ms  该帧的显示时长（毫秒）
 */
uint8_t* webp_anim_decoder_get_frame(WebPAnimContext* ctx,
                                     int* duration_ms);

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

#ifdef __cplusplus
}
#endif

#endif /* VENERA_WEBP_DECODER_H */
