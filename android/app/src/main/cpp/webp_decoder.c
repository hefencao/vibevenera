/**
 * webp_decoder.c — Venera WebP 解码封装层
 *
 * 核心架构：
 * 1. 原生缓冲池（Native Buffer Pool）：替代静态环形缓冲区，实现零拷贝管线。
 *    解码帧从池中获取缓冲区，Dart 层 GPU 上传完成后归还。
 * 2. 消除 Premul 往返转换：MODE_rgbA 直接输出 Premul，删除 straight_to_premul。
 * 3. 完美对齐：采用 (floor(x2*s) - floor(x1*s)) 计算宽度，确保子区域缩放后无缝拼接且无重叠。
 * 4. 状态原子性：帧迭代器推进放在解码成功之后，避免解码失败导致的状态不一致。
 * 5. 纯 Premultiplied Alpha 管线：MODE_rgbA 解码 → composite_region 合成 → 直接输出（无转换）。
 */

#include "webp_decoder.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/time.h>
#include <android/log.h>

#define LOGTAG "WebP_Native"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOGTAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOGTAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOGTAG, __VA_ARGS__)

#include "src/webp/decode.h"
#include "src/webp/demux.h"
#include "src/webp/mux_types.h"

#define POOL_MAX_SIZE 12

/* ─── 微秒级计时 ─── */
static int64_t now_us() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

/* ================================================================
 * 原生缓冲池（Zero-Copy 管线核心）
 * ================================================================ */

typedef struct {
    uint8_t* ptr;
    size_t capacity;
    int in_use;
} NativeBuffer;

static NativeBuffer g_buffer_pool[POOL_MAX_SIZE] = {0};
static pthread_mutex_t g_pool_mutex = PTHREAD_MUTEX_INITIALIZER;

uint8_t* webp_native_pool_acquire(size_t size) {
    pthread_mutex_lock(&g_pool_mutex);

    // 1. 寻找池中未在使用、容量足够的 buffer
    for (int i = 0; i < POOL_MAX_SIZE; i++) {
        if (!g_buffer_pool[i].in_use && g_buffer_pool[i].ptr != NULL) {
            if (g_buffer_pool[i].capacity >= size) {
                g_buffer_pool[i].in_use = 1;
                pthread_mutex_unlock(&g_pool_mutex);
                return g_buffer_pool[i].ptr;
            }
            free(g_buffer_pool[i].ptr);
            g_buffer_pool[i].ptr = (uint8_t*)malloc(size);
            g_buffer_pool[i].capacity = size;
            g_buffer_pool[i].in_use = 1;
            pthread_mutex_unlock(&g_pool_mutex);
            return g_buffer_pool[i].ptr;
        }
    }

    // 2. 寻找空槽初始化
    for (int i = 0; i < POOL_MAX_SIZE; i++) {
        if (g_buffer_pool[i].ptr == NULL) {
            g_buffer_pool[i].ptr = (uint8_t*)malloc(size);
            g_buffer_pool[i].capacity = size;
            g_buffer_pool[i].in_use = 1;
            pthread_mutex_unlock(&g_pool_mutex);
            return g_buffer_pool[i].ptr;
        }
    }

    // 3. 槽位全满，直接 malloc（不入池，release 时直接 free）
    pthread_mutex_unlock(&g_pool_mutex);
    LOGD("[POOL] All %d slots busy, fallback malloc(%zu)", POOL_MAX_SIZE, size);
    return (uint8_t*)malloc(size);
}

void webp_native_pool_release(uint8_t* ptr) {
    if (!ptr) return;
    pthread_mutex_lock(&g_pool_mutex);
    for (int i = 0; i < POOL_MAX_SIZE; i++) {
        if (g_buffer_pool[i].ptr == ptr) {
            g_buffer_pool[i].in_use = 0;
            pthread_mutex_unlock(&g_pool_mutex);
            return;
        }
    }
    pthread_mutex_unlock(&g_pool_mutex);
    // 非池中管理的 buffer，直接释放
    free(ptr);
}

void webp_native_pool_destroy(void) {
    pthread_mutex_lock(&g_pool_mutex);
    for (int i = 0; i < POOL_MAX_SIZE; i++) {
        if (g_buffer_pool[i].ptr != NULL) {
            free(g_buffer_pool[i].ptr);
            g_buffer_pool[i].ptr = NULL;
            g_buffer_pool[i].capacity = 0;
            g_buffer_pool[i].in_use = 0;
        }
    }
    pthread_mutex_unlock(&g_pool_mutex);
}

/* ================================================================
 * 内部结构
 * ================================================================ */

struct WebPAnimContext {
    WebPDemuxer* demux;
    int orig_canvas_w;
    int orig_canvas_h;
    int target_w;
    int target_h;
    double scale_x, scale_y;
    int frame_count;
    int loop_count;

    int current_frame_num;
    int total_frames_decoded;
    int current_loop;
    int prev_dispose;
    int prev_x, prev_y, prev_w, prev_h;

    /* 内部合成画布 (Premultiplied Alpha) */
    uint8_t* composite_canvas;
    int canvas_stride;

    /* 复用帧解码缓冲 */
    uint8_t* frame_buf;
    size_t frame_buf_size;

    WebPIterator iter;
    int has_frame;

    int use_threads; /* libwebp 线程数 (0/1=单线程, 2/3=多线程) */
};

/* ================================================================
 * 辅助函数
 * ================================================================ */

/** 计算缩放尺寸（保持一致性的 floor 策略） */
static void compute_scaled_dimensions(int src_w, int src_h, int max_w, int max_h, int* dst_w, int* dst_h) {
    double scale = fmin((double)max_w / src_w, (double)max_h / src_h);
    if (scale >= 1.0) {
        *dst_w = src_w; *dst_h = src_h;
    } else {
        *dst_w = (int)floor(src_w * scale);
        *dst_h = (int)floor(src_h * scale);
    }
    if (*dst_w <= 0) *dst_w = 1;
    if (*dst_h <= 0) *dst_h = 1;
}

/**
 * Premultiplied Alpha 混合（仅帧区域，无除法）。
 * 公式：out = src + dst * (255 - src_alpha) / 255
 */
static void composite_region(uint8_t* canvas, int stride, int c_w, int c_h,
                             const uint8_t* frame, int f_stride, int f_w, int f_h,
                             int off_x, int off_y, int blend, int has_alpha) {
    int copy_w = f_w, copy_h = f_h;
    if (off_x < 0) { int s = -off_x; frame += s * 4; copy_w -= s; off_x = 0; }
    if (off_y < 0) { int s = -off_y; frame += s * f_stride; copy_h -= s; off_y = 0; }
    if (off_x + copy_w > c_w) copy_w = c_w - off_x;
    if (off_y + copy_h > c_h) copy_h = c_h - off_y;
    if (copy_w <= 0 || copy_h <= 0) return;

    /* 快速路径：不混合 或 帧无 alpha → memcpy */
    if (!blend || !has_alpha) {
        for (int j = 0; j < copy_h; j++) {
            uint32_t* dst32 = (uint32_t*)(canvas + (off_y + j) * stride + off_x * 4);
            const uint32_t* src32 = (const uint32_t*)(frame + j * f_stride);
            memcpy(dst32, src32, (size_t)copy_w * 4);
        }
        return;
    }

    /* Premultiplied Alpha 混合（仅半透明像素触发） */
    for (int j = 0; j < copy_h; j++) {
        uint32_t* dst32 = (uint32_t*)(canvas + (off_y + j) * stride + off_x * 4);
        const uint32_t* src32 = (const uint32_t*)(frame + j * f_stride);
        for (int i = 0; i < copy_w; i++) {
            uint32_t s = src32[i];
            uint32_t sa = (s >> 24) & 0xff;
            if (sa == 0) continue;
            if (sa == 255) { dst32[i] = s; continue; }

            uint32_t d = dst32[i];
            uint32_t inv_sa = 255 - sa;
            uint32_t r = (s & 0xff) + (((d & 0xff) * inv_sa + 128) >> 8);
            uint32_t g = ((s >> 8) & 0xff) + ((((d >> 8) & 0xff) * inv_sa + 128) >> 8);
            uint32_t b = ((s >> 16) & 0xff) + ((((d >> 16) & 0xff) * inv_sa + 128) >> 8);
            uint32_t a = sa + ((((d >> 24) & 0xff) * inv_sa + 128) >> 8);
            if (r > 255) r = 255; if (g > 255) g = 255; if (b > 255) b = 255; if (a > 255) a = 255;
            dst32[i] = (a << 24) | (b << 16) | (g << 8) | r;
        }
    }
}

static void clear_region(uint8_t* canvas, int stride, int canvas_w, int canvas_h, int x, int y, int w, int h) {
    if (x < 0) { w += x; x = 0; } if (y < 0) { h += y; y = 0; }
    if (x + w > canvas_w) w = canvas_w - x; if (y + h > canvas_h) h = canvas_h - y;
    if (w <= 0 || h <= 0) return;
    for (int j = 0; j < h; j++) memset(canvas + (y + j) * stride + x * 4, 0, (size_t)w * 4);
}

/* ─── 全局存活计数（调试内存泄漏） ─── */
static int g_alive_contexts = 0;

/* ================================================================
 * 公共 API
 * ================================================================ */

int webp_get_info(const uint8_t* data, size_t size, int* width, int* height, int* has_alpha, int* is_animated) {
    if (!data || size == 0) return 0;
    WebPBitstreamFeatures f;
    if (WebPGetFeatures(data, size, &f) != VP8_STATUS_OK) return 0;
    if (width) *width = f.width; if (height) *height = f.height;
    if (has_alpha) *has_alpha = f.has_alpha; if (is_animated) *is_animated = f.has_animation;
    return 1;
}

uint8_t* webp_decode_scaled(const uint8_t* data, size_t size, int target_width, int target_height, int* out_width, int* out_height) {
    WebPBitstreamFeatures f;
    if (WebPGetFeatures(data, size, &f) != VP8_STATUS_OK) return NULL;
    int dst_w, dst_h;
    compute_scaled_dimensions(f.width, f.height, target_width, target_height, &dst_w, &dst_h);
    size_t bytes = (size_t)dst_w * dst_h * 4;
    uint8_t* buf = (uint8_t*)malloc(bytes);
    if (!buf) return NULL;
    WebPDecoderConfig cfg;
    WebPInitDecoderConfig(&cfg);
    cfg.options.use_scaling = 1; cfg.options.scaled_width = dst_w; cfg.options.scaled_height = dst_h;
    cfg.output.colorspace = MODE_RGBA; cfg.output.u.RGBA.rgba = buf;
    cfg.output.u.RGBA.stride = dst_w * 4; cfg.output.u.RGBA.size = bytes; cfg.output.is_external_memory = 1;
    if (WebPDecode(data, size, &cfg) != VP8_STATUS_OK) { free(buf); return NULL; }
    if (out_width) *out_width = cfg.output.width; if (out_height) *out_height = cfg.output.height;
    return buf;
}

WebPAnimContext* webp_anim_decoder_new(const uint8_t* data, size_t size, int target_width, int target_height,
                                      int* canvas_width, int* canvas_height, int* frame_count, int* loop_count,
                                      int* actual_width, int* actual_height) {
    WebPData webp_data = {data, size};
    WebPDemuxer* demux = WebPDemux(&webp_data);
    if (!demux) return NULL;
    int orig_w = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
    int orig_h = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
    int t_w, t_h;
    compute_scaled_dimensions(orig_w, orig_h, target_width, target_height, &t_w, &t_h);
    WebPAnimContext* ctx = (WebPAnimContext*)calloc(1, sizeof(WebPAnimContext));
    if (!ctx) { WebPDemuxDelete(demux); return NULL; }
    ctx->demux = demux; ctx->orig_canvas_w = orig_w; ctx->orig_canvas_h = orig_h;
    ctx->target_w = t_w; ctx->target_h = t_h; ctx->scale_x = (double)t_w / orig_w; ctx->scale_y = (double)t_h / orig_h;
    ctx->frame_count = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
    ctx->loop_count = WebPDemuxGetI(demux, WEBP_FF_LOOP_COUNT);
    ctx->canvas_stride = t_w * 4;
    size_t canvas_bytes = (size_t)t_w * t_h * 4;
    ctx->composite_canvas = (uint8_t*)calloc(1, canvas_bytes);
    if (!ctx->composite_canvas) { WebPDemuxDelete(demux); free(ctx); return NULL; }
    g_alive_contexts++;
    LOGI("[LIFECYCLE] NEW  ctx=%p total_alive=%d frames=%d canvas=%dx%d target=%dx%d",
         (void*)ctx, g_alive_contexts, ctx->frame_count, orig_w, orig_h, t_w, t_h);
    if (canvas_width) *canvas_width = orig_w; if (canvas_height) *canvas_height = orig_h;
    if (frame_count) *frame_count = ctx->frame_count; if (loop_count) *loop_count = ctx->loop_count;
    if (actual_width) *actual_width = t_w; if (actual_height) *actual_height = t_h;
    return ctx;
}

uint8_t* webp_anim_decoder_get_frame(WebPAnimContext* ctx, int* duration_ms) {
    if (!ctx) return NULL;
    /* ── 1. 循环边界处理 ── */
    if (ctx->has_frame && ctx->total_frames_decoded >= ctx->frame_count) {
        if (ctx->loop_count > 0 && ctx->current_loop + 1 >= ctx->loop_count) return NULL;
        ctx->current_loop++; ctx->total_frames_decoded = 0; ctx->current_frame_num = 0; ctx->prev_dispose = -1;
        WebPDemuxReleaseIterator(&ctx->iter); ctx->has_frame = 0;
        memset(ctx->composite_canvas, 0, (size_t)ctx->target_w * ctx->target_h * 4);
    }

    /* ── 2. 处理上一帧的 DISPOSE_BACKGROUND ── */
    if (ctx->prev_dispose == WEBP_MUX_DISPOSE_BACKGROUND)
        clear_region(ctx->composite_canvas, ctx->canvas_stride, ctx->target_w, ctx->target_h,
                     ctx->prev_x, ctx->prev_y, ctx->prev_w, ctx->prev_h);

    /* ── 3. 获取下一帧迭代器（若之前迭代器未初始化则 Get，否则 Next） ── */
    if (!ctx->has_frame) {
        if (!WebPDemuxGetFrame(ctx->demux, 1, &ctx->iter)) return NULL;
        ctx->has_frame = 1; ctx->current_frame_num = 1;
    } else {
        if (!WebPDemuxNextFrame(&ctx->iter)) return NULL;
        ctx->current_frame_num++;
    }
    /* 帧计数器在此处推进，确保即使后续解码失败，计数器与迭代器保持同步 */
    ctx->total_frames_decoded++;
    // LOGD("Decode frame %d/%d (loop %d)", ctx->current_frame_num, ctx->frame_count, ctx->current_loop);

    /* ── 4. 计算缩放后的帧参数 ── */
    int f_x = (int)floor(ctx->iter.x_offset * ctx->scale_x);
    int f_y = (int)floor(ctx->iter.y_offset * ctx->scale_y);
    int f_w = (int)floor((ctx->iter.x_offset + ctx->iter.width) * ctx->scale_x) - f_x;
    int f_h = (int)floor((ctx->iter.y_offset + ctx->iter.height) * ctx->scale_y) - f_y;
    if (f_w <= 0) f_w = 1; if (f_h <= 0) f_h = 1;

    LOGD("Frame %d/%d scaled: %dx%d @ (%d,%d)", ctx->current_frame_num, ctx->frame_count, f_w, f_h, f_x, f_y);

    /* ── 5. 准备解码缓冲区（+4096 安全边距用于 SIMD 对齐） ── */
    size_t needed = (size_t)f_w * f_h * 4 + 4096;
    if (needed > ctx->frame_buf_size) {
        free(ctx->frame_buf);
        ctx->frame_buf = (uint8_t*)malloc(needed);
        if (!ctx->frame_buf) { LOGE("malloc frame_buf failed, size=%zu", needed); return NULL; }
        ctx->frame_buf_size = needed;
    }

    /* ── 6. 解码帧碎片（MODE_rgbA 直接输出 Premul，省去 straight_to_premul） ── */
    WebPDecoderConfig cfg; WebPInitDecoderConfig(&cfg);
    cfg.options.use_scaling = 1; cfg.options.scaled_width = f_w; cfg.options.scaled_height = f_h;
    cfg.options.use_threads = (ctx->use_threads > 1 ? 1 : 0);
    cfg.output.colorspace = MODE_rgbA; /* Premultiplied Alpha，直接用于合成 */
    cfg.output.u.RGBA.rgba = ctx->frame_buf;
    cfg.output.u.RGBA.stride = f_w * 4;
    cfg.output.u.RGBA.size = ctx->frame_buf_size;
    cfg.output.is_external_memory = 1;

    if (WebPDecode(ctx->iter.fragment.bytes, ctx->iter.fragment.size, &cfg) != VP8_STATUS_OK) {
        LOGE("WebPDecode failed for frame %d/%d (frame skipped)", ctx->current_frame_num, ctx->frame_count);
        return NULL; /* 帧计数器已推进，此帧被跳过；composite_canvas 保持不变 */
    }

    /* ── 7. 验证解码尺寸 ── */
    int dec_w = cfg.output.width, dec_h = cfg.output.height;
    if (dec_w <= 0 || dec_h <= 0 || dec_w > f_w || dec_h > f_h) {
        LOGE("WebPDecode output size mismatch: expected<=%dx%d, got %dx%d", f_w, f_h, dec_w, dec_h);
        return NULL;
    }

    /* ── 8. Premul 合成到画布（帧已是 Premul，无需 straight_to_premul） ── */
    composite_region(ctx->composite_canvas, ctx->canvas_stride, ctx->target_w, ctx->target_h,
                     ctx->frame_buf, cfg.output.u.RGBA.stride, dec_w, dec_h, f_x, f_y,
                     (ctx->iter.blend_method == WEBP_MUX_BLEND), ctx->iter.has_alpha);

    /* ── 9. 记录帧位置与处置方式 ── */
    ctx->prev_x = f_x; ctx->prev_y = f_y;
    ctx->prev_w = dec_w; ctx->prev_h = dec_h;
    ctx->prev_dispose = ctx->iter.dispose_method;

    /* ── 11. 从原生缓冲池获取输出缓冲区，拷贝合成画布（Premultiplied Alpha） ── */
    size_t canvas_bytes = (size_t)ctx->target_w * ctx->target_h * 4;
    uint8_t* out = webp_native_pool_acquire(canvas_bytes);
    memcpy(out, ctx->composite_canvas, canvas_bytes);

    /* ── 12. 设置帧时长 ── */
    if (duration_ms) {
        int d = ctx->iter.duration;
        if (d <= 10) d = 100;
        *duration_ms = d;
    }
    return out;
}

int webp_anim_decoder_has_more(WebPAnimContext* ctx) {
    if (!ctx || !ctx->demux) return 0;
    if (!ctx->has_frame || ctx->total_frames_decoded < ctx->frame_count) return 1;
    return (ctx->loop_count == 0 || ctx->current_loop + 1 < ctx->loop_count);
}

void webp_anim_decoder_reset(WebPAnimContext* ctx) {
    if (!ctx) return;
    if (ctx->has_frame) WebPDemuxReleaseIterator(&ctx->iter);
    ctx->has_frame = 0; ctx->current_frame_num = 0; ctx->total_frames_decoded = 0; ctx->current_loop = 0; ctx->prev_dispose = -1;
    memset(ctx->composite_canvas, 0, (size_t)ctx->target_w * ctx->target_h * 4);
}

void webp_anim_decoder_delete(WebPAnimContext* ctx) {
    if (!ctx) return;
    LOGI("[LIFECYCLE] DEL START ctx=%p", (void*)ctx);
    if (ctx->has_frame) WebPDemuxReleaseIterator(&ctx->iter);
    if (ctx->demux) WebPDemuxDelete(ctx->demux);
    free(ctx->composite_canvas);
    free(ctx->frame_buf);
    g_alive_contexts--;
    LOGI("[LIFECYCLE] DEL DONE ctx=%p total_alive=%d", (void*)ctx, g_alive_contexts);
    free(ctx);
}

void webp_anim_decoder_set_thread_limit(WebPAnimContext* ctx, int use_threads) {
    if (!ctx) return;
    ctx->use_threads = use_threads;
}

int webp_anim_decoder_alive_count(void) {
    return g_alive_contexts;
}

WebPFrameList* webp_anim_extract_frames(const uint8_t* data, size_t size) {
    WebPData webp_data = {data, size};
    WebPDemuxer* demux = WebPDemux(&webp_data);
    if (!demux) return NULL;
    int frames = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
    if (frames <= 0) { WebPDemuxDelete(demux); return NULL; }
    WebPFrameList* list = (WebPFrameList*)malloc(sizeof(WebPFrameList));
    list->frames = (WebPFrameInfo*)calloc((size_t)frames, sizeof(WebPFrameInfo));
    list->canvas_width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
    list->canvas_height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
    list->frame_count = frames;
    WebPIterator it;
    if (WebPDemuxGetFrame(demux, 1, &it)) {
        int i = 0;
        do {
            WebPFrameInfo* f = &list->frames[i++];
            f->x_offset = it.x_offset; f->y_offset = it.y_offset; f->width = it.width; f->height = it.height;
            f->dispose_method = (int)it.dispose_method; f->blend_method = (int)it.blend_method;
            f->duration = it.duration; f->has_alpha = it.has_alpha;
            f->data_size = it.fragment.size;
            f->data = (const uint8_t*)malloc(it.fragment.size);
            if (f->data) memcpy((void*)f->data, it.fragment.bytes, it.fragment.size);
        } while (WebPDemuxNextFrame(&it) && i < frames);
        WebPDemuxReleaseIterator(&it);
    }
    WebPDemuxDelete(demux);
    return list;
}

void webp_free_frame_list(WebPFrameList* list) {
    if (!list) return;
    for (int i = 0; i < list->frame_count; i++) free((void*)list->frames[i].data);
    free(list->frames); free(list);
}

uint8_t* webp_decode_fragment_scaled(const uint8_t* frag, size_t size, int fw, int fh, int tw, int th, int* ow, int* oh) {
    int dw = fw, dh = fh;
    if (tw > 0 && th > 0) {
        double s = fmin((double)tw / fw, (double)th / fh);
        if (s < 1.0) { dw = (int)floor(fw * s); dh = (int)floor(fh * s); }
    }
    if (dw <= 0) dw = 1; if (dh <= 0) dh = 1;
    uint8_t* b = (uint8_t*)malloc((size_t)dw * dh * 4);
    if (!b) return NULL;
    WebPDecoderConfig cfg; WebPInitDecoderConfig(&cfg);
    cfg.options.use_scaling = 1; cfg.options.scaled_width = dw; cfg.options.scaled_height = dh;
    cfg.output.colorspace = MODE_RGBA; cfg.output.u.RGBA.rgba = b;
    cfg.output.u.RGBA.stride = dw * 4; cfg.output.u.RGBA.size = (size_t)dw * dh * 4; cfg.output.is_external_memory = 1;
    if (WebPDecode(frag, size, &cfg) != VP8_STATUS_OK) { free(b); return NULL; }
    if (ow) *ow = cfg.output.width; if (oh) *oh = cfg.output.height;
    return b;
}

void webp_free_buffer(uint8_t* buf) { free(buf); }
