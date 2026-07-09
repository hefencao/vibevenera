import 'dart:async';

import 'package:dio/dio.dart'; // CancelToken
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/foundation/image_provider/image_fetch.dart';
import 'package:venera/network/images.dart';

import 'webp_image_provider.dart';

// ═══════════════════════════════════════════════════════════════
// Image Pipeline — Policy → Resource → Scheduler
//
//   InteractionState → ResourcePolicy → ResourceEntry → PipelineController
//                                                              │
//                                              ┌───────────────┼───────────────┐
//                                              ▼               ▼               ▼
//                                        DownloadTask    PrecreateTask    (future)
//
//   TaskScheduler — pure dispatcher (priority queue + concurrency)
//   TaskRegistry  — key→task lookup + dedup
//   MigrationMgr  — priority-based task migration
// ═══════════════════════════════════════════════════════════════

part 'pipeline/pipeline_resource.dart';
part 'pipeline/task_runtime.dart';
part 'pipeline/task_scheduler_runtime.dart';
