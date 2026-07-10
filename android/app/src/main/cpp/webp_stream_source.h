#ifndef VENERA_WEBP_STREAM_SOURCE_H
#define VENERA_WEBP_STREAM_SOURCE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WebPSourceContext WebPSourceContext;

enum {
    WEBP_SOURCE_OK = 0,
    WEBP_SOURCE_INVALID = -1,
    WEBP_SOURCE_STALE_EPOCH = -2,
    WEBP_SOURCE_INVALID_OFFSET = -3,
    WEBP_SOURCE_INVALID_RESERVATION = -4,
    WEBP_SOURCE_ALLOCATION_FAILED = -5,
    WEBP_SOURCE_INVALID_CONTAINER = -6,
    WEBP_SOURCE_INVALID_FINAL_LENGTH = -7
};

typedef struct {
    uint64_t epoch;
    uint64_t expected_length;
    uint64_t committed_length;
    uint64_t declared_length;
    uint64_t parsed_offset;
    int32_t sealed;
    int32_t failed;
    int32_t last_error;
    int32_t canvas_width;
    int32_t canvas_height;
    int32_t loop_count;
    int32_t frame_count;
    int32_t animated;
} WebPSourceState;

typedef struct {
    uint64_t payload_offset;
    uint64_t payload_length;
    int32_t x_offset;
    int32_t y_offset;
    int32_t width;
    int32_t height;
    int32_t duration_ms;
    int32_t dispose_method;
    int32_t blend_method; /* 0=no blend, 1=alpha blend */
    int32_t has_alpha;
} WebPSourceFrame;

WebPSourceContext* webp_source_new(uint64_t expected_length, uint64_t epoch);

uint8_t* webp_source_reserve(WebPSourceContext* source,
                             uint64_t epoch,
                             uint64_t offset,
                             uint64_t length);

int webp_source_commit(WebPSourceContext* source,
                       uint64_t epoch,
                       uint64_t offset,
                       uint64_t length);

int webp_source_seal(WebPSourceContext* source, uint64_t epoch);

int webp_source_reset(WebPSourceContext* source,
                      uint64_t expected_length,
                      uint64_t new_epoch);

int webp_source_get_state(WebPSourceContext* source, WebPSourceState* out_state);

int webp_source_get_frame(WebPSourceContext* source,
                          int32_t frame_index,
                          WebPSourceFrame* out_frame);

void webp_source_delete(WebPSourceContext* source);

/* Internal cursor/source ownership API. The returned payload pointer remains
 * valid until webp_source_release_frame_data(). */
int webp_source_retain(WebPSourceContext* source);

void webp_source_release(WebPSourceContext* source);

int webp_source_acquire_frame_data(WebPSourceContext* source,
                                   uint64_t epoch,
                                   int32_t frame_index,
                                   WebPSourceFrame* out_frame,
                                   const uint8_t** out_payload);

void webp_source_release_frame_data(WebPSourceContext* source);

#ifdef __cplusplus
}
#endif

#endif
