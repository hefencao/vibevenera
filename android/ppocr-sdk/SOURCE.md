# Vendored PaddleOCR Android SDK

- Upstream: https://github.com/PaddlePaddle/PaddleOCR
- Revision: `211989f046cc1878460f9e65574690c00a127a1a`
- Source directory: `deploy/ppocr-android/ppocr-sdk`
- License: Apache-2.0; see `LICENSE`.

Venera keeps the upstream asset-loading API and extends the explicit-path
constructor to load models downloaded into app support storage. The module
minimum SDK is lowered from 26 to Venera's existing 24; the vendored source
does not call API 25/26-only Android APIs. The obsolete QuickBird OpenCV 4.5.3
AAR is replaced by the official `org.opencv:opencv:4.13.0` AAR.
