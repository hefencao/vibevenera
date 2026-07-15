/**
 * webp_texture_blit.c — 动图 native texture 零拷贝 blit（仅 Android）
 *
 * 背景：原实现每帧在 Dart UI isolate 上做 ~10MB 的 Uint8List 全帧拷贝，再经
 * MethodChannel 序列化同样的 10MB，堵住 UI isolate（实测 60ms/帧、~16fps）。
 *
 * 本函数改为「JNI 直读」：Dart 侧只把 native 帧地址(int64)+宽高经通道传来，这里
 * 用 ANativeWindow 直接从该地址 memcpy 进 Surface 缓冲区。UI isolate 完全不碰
 * 像素字节，10MB 拷贝只在 native 侧发生一次（且在 Android 平台线程，不在 UI
 * isolate）。
 *
 * 源像素约定：Premultiplied RGBA8888，R,G,B,A 字节序 —— 与
 * WINDOW_FORMAT_RGBA_8888 的内存布局一致，直接逐行 memcpy。
 *
 * 生命周期：调用方（Dart）必须保证 addr 指向的 native 帧在本调用返回前存活
 * （即 frame.dispose() 放在 await channel.update() 之后）。
 */

#include <jni.h>
#include <stdint.h>
#include <string.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/log.h>

#define BLIT_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "WebP_Blit", __VA_ARGS__)

JNIEXPORT jboolean JNICALL
Java_com_github_wgh136_venera_WebPTexturePlugin_nativeBlit(
    JNIEnv* env,
    jobject thiz,
    jobject surface,
    jlong addr,
    jint width,
    jint height,
    jboolean configure) {
  (void)thiz;
  if (surface == NULL || addr == 0 || width <= 0 || height <= 0) {
    return JNI_FALSE;
  }

  ANativeWindow* win = ANativeWindow_fromSurface(env, surface);
  if (win == NULL) {
    BLIT_LOGE("ANativeWindow_fromSurface returned NULL");
    return JNI_FALSE;
  }

  jboolean ok = JNI_FALSE;
  int geometry_result = configure
      ? ANativeWindow_setBuffersGeometry(win, width, height,
                                         WINDOW_FORMAT_RGBA_8888)
      : 0;
  if (geometry_result == 0) {
    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(win, &buf, NULL) == 0) {
      const uint8_t* src = (const uint8_t*)(intptr_t)addr;
      uint8_t* dst = (uint8_t*)buf.bits;

      int copy_w = width < buf.width ? width : buf.width;
      int copy_h = height < buf.height ? height : buf.height;
      size_t src_stride = (size_t)width * 4;
      size_t dst_stride = (size_t)buf.stride * 4;  /* stride 单位是像素 */
      size_t row_bytes = (size_t)copy_w * 4;

      if (dst != NULL) {
        for (int y = 0; y < copy_h; y++) {
          memcpy(dst + (size_t)y * dst_stride,
                 src + (size_t)y * src_stride,
                 row_bytes);
        }
        ok = JNI_TRUE;
      }
      ANativeWindow_unlockAndPost(win);
    } else {
      BLIT_LOGE("ANativeWindow_lock failed");
    }
  } else {
    BLIT_LOGE("ANativeWindow_setBuffersGeometry failed w=%d h=%d", width, height);
  }

  ANativeWindow_release(win);
  return ok;
}
