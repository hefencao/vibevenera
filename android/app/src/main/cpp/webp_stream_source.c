#include "webp_stream_source.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct WebPSourceContext {
    pthread_mutex_t mutex;
    pthread_rwlock_t storage_lock;
    uint8_t* data;
    size_t capacity;
    uint64_t epoch;
    uint64_t expected_length;
    uint64_t committed_length;
    uint64_t declared_length;
    uint64_t parsed_offset;
    uint64_t reserved_offset;
    uint64_t reserved_length;
    int reservation_active;
    int sealed;
    int failed;
    int last_error;
    int canvas_width;
    int canvas_height;
    int loop_count;
    int animated;
    WebPSourceFrame* frames;
    size_t frame_count;
    size_t frame_capacity;
    int references;
};

static uint32_t read_u24(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
}

static uint32_t read_u32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int fourcc(const uint8_t* p, const char* value) {
    return p[0] == (uint8_t)value[0] && p[1] == (uint8_t)value[1] &&
           p[2] == (uint8_t)value[2] && p[3] == (uint8_t)value[3];
}

static int fail_locked(WebPSourceContext* source, int error) {
    source->failed = 1;
    source->last_error = error;
    return error;
}

static int ensure_capacity_locked(WebPSourceContext* source, uint64_t required) {
    if (required <= source->capacity) return WEBP_SOURCE_OK;
    if (required > SIZE_MAX) return fail_locked(source, WEBP_SOURCE_ALLOCATION_FAILED);
    uint64_t capacity = source->capacity ? source->capacity : 65536;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }
    pthread_rwlock_wrlock(&source->storage_lock);
    uint8_t* data = (uint8_t*)realloc(source->data, (size_t)capacity);
    pthread_rwlock_unlock(&source->storage_lock);
    if (!data) return fail_locked(source, WEBP_SOURCE_ALLOCATION_FAILED);
    source->data = data;
    source->capacity = (size_t)capacity;
    return WEBP_SOURCE_OK;
}

static int append_frame_locked(WebPSourceContext* source,
                               const uint8_t* payload,
                               uint64_t payload_offset,
                               uint32_t payload_size) {
    if (payload_size < 16) return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
    if (source->frame_count == source->frame_capacity) {
        size_t capacity = source->frame_capacity ? source->frame_capacity * 2 : 32;
        WebPSourceFrame* frames = (WebPSourceFrame*)realloc(
            source->frames, capacity * sizeof(WebPSourceFrame));
        if (!frames) return fail_locked(source, WEBP_SOURCE_ALLOCATION_FAILED);
        source->frames = frames;
        source->frame_capacity = capacity;
    }
    WebPSourceFrame* frame = &source->frames[source->frame_count++];
    frame->x_offset = (int32_t)(read_u24(payload) * 2);
    frame->y_offset = (int32_t)(read_u24(payload + 3) * 2);
    frame->width = (int32_t)read_u24(payload + 6) + 1;
    frame->height = (int32_t)read_u24(payload + 9) + 1;
    frame->duration_ms = (int32_t)read_u24(payload + 12);
    frame->dispose_method = payload[15] & 1;
    frame->blend_method = (payload[15] & 2) == 0;
    frame->has_alpha = 0;
    frame->payload_offset = payload_offset + 16;
    frame->payload_length = payload_size - 16;
    uint64_t offset = 16;
    while (payload_size - offset >= 8) {
        const uint8_t* header = payload + offset;
        uint32_t size = read_u32(header + 4);
        uint64_t chunk_length = 8 + (uint64_t)size + (size & 1u);
        if (payload_size - offset < chunk_length) break;
        if (fourcc(header, "ALPH") || fourcc(header, "VP8L")) {
            frame->has_alpha = 1;
        }
        offset += chunk_length;
    }
    source->animated = 1;
    return WEBP_SOURCE_OK;
}

static int parse_locked(WebPSourceContext* source) {
    if (source->failed) return source->last_error;
    if (source->parsed_offset == 0) {
        if (source->committed_length < 12) return WEBP_SOURCE_OK;
        if (!fourcc(source->data, "RIFF") || !fourcc(source->data + 8, "WEBP")) {
            return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
        }
        source->declared_length = (uint64_t)read_u32(source->data + 4) + 8;
        if (source->declared_length < 12) {
            return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
        }
        source->expected_length = source->declared_length;
        if (ensure_capacity_locked(source, source->declared_length) != WEBP_SOURCE_OK) {
            return source->last_error;
        }
        if (source->committed_length > source->declared_length) {
            return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
        }
        source->parsed_offset = 12;
    }
    while (source->committed_length - source->parsed_offset >= 8) {
        uint64_t chunk_offset = source->parsed_offset;
        const uint8_t* header = source->data + chunk_offset;
        uint32_t chunk_size = read_u32(header + 4);
        uint64_t chunk_length = 8 + (uint64_t)chunk_size + (chunk_size & 1u);
        if (chunk_offset + chunk_length > source->declared_length) {
            return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
        }
        if (source->committed_length - chunk_offset < chunk_length) break;
        const uint8_t* payload = header + 8;
        if (fourcc(header, "VP8X")) {
            if (chunk_size < 10) return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
            source->animated = (payload[0] & 2) != 0;
            source->canvas_width = (int32_t)read_u24(payload + 4) + 1;
            source->canvas_height = (int32_t)read_u24(payload + 7) + 1;
        } else if (fourcc(header, "ANIM")) {
            if (chunk_size < 6) return fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER);
            source->loop_count = (int32_t)payload[4] | ((int32_t)payload[5] << 8);
            source->animated = 1;
        } else if (fourcc(header, "ANMF")) {
            int result = append_frame_locked(source, payload, chunk_offset + 8, chunk_size);
            if (result != WEBP_SOURCE_OK) return result;
        }
        source->parsed_offset += chunk_length;
    }
    return WEBP_SOURCE_OK;
}

WebPSourceContext* webp_source_new(uint64_t expected_length, uint64_t epoch) {
    WebPSourceContext* source = (WebPSourceContext*)calloc(1, sizeof(WebPSourceContext));
    if (!source) return NULL;
    pthread_mutex_init(&source->mutex, NULL);
    pthread_rwlock_init(&source->storage_lock, NULL);
    source->references = 1;
    source->epoch = epoch;
    source->expected_length = expected_length;
    if (expected_length > 0 && ensure_capacity_locked(source, expected_length) != WEBP_SOURCE_OK) {
        pthread_rwlock_destroy(&source->storage_lock);
        pthread_mutex_destroy(&source->mutex);
        free(source);
        return NULL;
    }
    return source;
}

uint8_t* webp_source_reserve(WebPSourceContext* source,
                             uint64_t epoch,
                             uint64_t offset,
                             uint64_t length) {
    if (!source || length == 0 || offset > UINT64_MAX - length) return NULL;
    pthread_mutex_lock(&source->mutex);
    if (source->failed || source->sealed || epoch != source->epoch ||
        source->reservation_active || offset != source->committed_length ||
        (source->declared_length > 0 &&
         offset + length > source->declared_length) ||
        ensure_capacity_locked(source, offset + length) != WEBP_SOURCE_OK) {
        if (!source->failed) {
            source->last_error = epoch != source->epoch
                ? WEBP_SOURCE_STALE_EPOCH
                : offset != source->committed_length
                    ? WEBP_SOURCE_INVALID_OFFSET
                    : source->declared_length > 0 &&
                      offset + length > source->declared_length
                        ? fail_locked(source, WEBP_SOURCE_INVALID_CONTAINER)
                        : WEBP_SOURCE_INVALID_RESERVATION;
        }
        pthread_mutex_unlock(&source->mutex);
        return NULL;
    }
    source->reserved_offset = offset;
    source->reserved_length = length;
    source->reservation_active = 1;
    uint8_t* target = source->data + offset;
    pthread_mutex_unlock(&source->mutex);
    return target;
}

int webp_source_commit(WebPSourceContext* source,
                       uint64_t epoch,
                       uint64_t offset,
                       uint64_t length) {
    if (!source) return WEBP_SOURCE_INVALID;
    pthread_mutex_lock(&source->mutex);
    if (source->failed) {
        int error = source->last_error;
        pthread_mutex_unlock(&source->mutex);
        return error;
    }
    if (epoch != source->epoch) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_STALE_EPOCH;
    }
    if (!source->reservation_active || offset != source->reserved_offset ||
        length != source->reserved_length) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_INVALID_RESERVATION;
    }
    source->reservation_active = 0;
    source->committed_length += length;
    int result = parse_locked(source);
    pthread_mutex_unlock(&source->mutex);
    return result;
}

int webp_source_seal(WebPSourceContext* source, uint64_t epoch) {
    if (!source) return WEBP_SOURCE_INVALID;
    pthread_mutex_lock(&source->mutex);
    if (source->failed) {
        int error = source->last_error;
        pthread_mutex_unlock(&source->mutex);
        return error;
    }
    if (epoch != source->epoch) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_STALE_EPOCH;
    }
    if (source->reservation_active) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_INVALID_RESERVATION;
    }
    int result = parse_locked(source);
    if (result == WEBP_SOURCE_OK &&
        (source->declared_length == 0 ||
         source->committed_length != source->declared_length ||
         source->parsed_offset != source->declared_length)) {
        result = fail_locked(source, WEBP_SOURCE_INVALID_FINAL_LENGTH);
    }
    if (result == WEBP_SOURCE_OK) source->sealed = 1;
    pthread_mutex_unlock(&source->mutex);
    return result;
}

int webp_source_reset(WebPSourceContext* source,
                      uint64_t expected_length,
                      uint64_t new_epoch) {
    if (!source) return WEBP_SOURCE_INVALID;
    pthread_mutex_lock(&source->mutex);
    if (source->reservation_active) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_INVALID_RESERVATION;
    }
    pthread_rwlock_wrlock(&source->storage_lock);
    source->epoch = new_epoch;
    source->expected_length = expected_length;
    source->committed_length = 0;
    source->declared_length = 0;
    source->parsed_offset = 0;
    source->reserved_offset = 0;
    source->reserved_length = 0;
    source->reservation_active = 0;
    source->sealed = 0;
    source->failed = 0;
    source->last_error = WEBP_SOURCE_OK;
    source->canvas_width = 0;
    source->canvas_height = 0;
    source->loop_count = 0;
    source->animated = 0;
    source->frame_count = 0;
    pthread_rwlock_unlock(&source->storage_lock);
    int result = expected_length > 0 ? ensure_capacity_locked(source, expected_length)
                                    : WEBP_SOURCE_OK;
    pthread_mutex_unlock(&source->mutex);
    return result;
}

int webp_source_get_state(WebPSourceContext* source, WebPSourceState* out_state) {
    if (!source || !out_state) return WEBP_SOURCE_INVALID;
    pthread_mutex_lock(&source->mutex);
    out_state->epoch = source->epoch;
    out_state->expected_length = source->expected_length;
    out_state->committed_length = source->committed_length;
    out_state->declared_length = source->declared_length;
    out_state->parsed_offset = source->parsed_offset;
    out_state->sealed = source->sealed;
    out_state->failed = source->failed;
    out_state->last_error = source->last_error;
    out_state->canvas_width = source->canvas_width;
    out_state->canvas_height = source->canvas_height;
    out_state->loop_count = source->loop_count;
    out_state->frame_count = (int32_t)source->frame_count;
    out_state->animated = source->animated;
    pthread_mutex_unlock(&source->mutex);
    return WEBP_SOURCE_OK;
}

int webp_source_get_frame(WebPSourceContext* source,
                          int32_t frame_index,
                          WebPSourceFrame* out_frame) {
    if (!source || !out_frame || frame_index < 0) return WEBP_SOURCE_INVALID;
    pthread_mutex_lock(&source->mutex);
    if ((size_t)frame_index >= source->frame_count) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_INVALID;
    }
    *out_frame = source->frames[frame_index];
    pthread_mutex_unlock(&source->mutex);
    return WEBP_SOURCE_OK;
}

void webp_source_delete(WebPSourceContext* source) {
    webp_source_release(source);
}

int webp_source_retain(WebPSourceContext* source) {
    if (!source) return WEBP_SOURCE_INVALID;
    pthread_mutex_lock(&source->mutex);
    source->references++;
    pthread_mutex_unlock(&source->mutex);
    return WEBP_SOURCE_OK;
}

void webp_source_release(WebPSourceContext* source) {
    if (!source) return;
    pthread_mutex_lock(&source->mutex);
    source->references--;
    if (source->references > 0) {
        pthread_mutex_unlock(&source->mutex);
        return;
    }
    pthread_rwlock_wrlock(&source->storage_lock);
    free(source->frames);
    free(source->data);
    pthread_rwlock_unlock(&source->storage_lock);
    pthread_mutex_unlock(&source->mutex);
    pthread_rwlock_destroy(&source->storage_lock);
    pthread_mutex_destroy(&source->mutex);
    free(source);
}

int webp_source_acquire_frame_data(WebPSourceContext* source,
                                   uint64_t epoch,
                                   int32_t frame_index,
                                   WebPSourceFrame* out_frame,
                                   const uint8_t** out_payload) {
    if (!source || !out_frame || !out_payload || frame_index < 0) {
        return WEBP_SOURCE_INVALID;
    }
    pthread_mutex_lock(&source->mutex);
    if (epoch != source->epoch) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_STALE_EPOCH;
    }
    if (source->failed) {
        int error = source->last_error;
        pthread_mutex_unlock(&source->mutex);
        return error;
    }
    if ((size_t)frame_index >= source->frame_count) {
        pthread_mutex_unlock(&source->mutex);
        return WEBP_SOURCE_INVALID_OFFSET;
    }
    *out_frame = source->frames[frame_index];
    pthread_rwlock_rdlock(&source->storage_lock);
    *out_payload = source->data + out_frame->payload_offset;
    pthread_mutex_unlock(&source->mutex);
    return WEBP_SOURCE_OK;
}

void webp_source_release_frame_data(WebPSourceContext* source) {
    if (source) pthread_rwlock_unlock(&source->storage_lock);
}
