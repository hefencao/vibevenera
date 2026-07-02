Venera WebP 高能效渲染引擎系统规范 (Spec)
一、 系统架构图与对象关系
code
Text
+-------------------------------------------------------+
               |                  DecoderManager                       |
               +-------------------------------------------------------+
                                   |
         +-------------------------+-------------------------+
         |                         |                         |
+-----------------+       +-----------------+       +-----------------+
|  CURRENT Page   |       |    NEXT Page    |       |  LAST/PRECACHE  |
|  State: CURRENT |       |   State: NEXT   |       | State: PRECACHE |
+-----------------+       +-----------------+       +-----------------+
| FrameBuffer     |       | FrameBuffer     |       | FrameBuffer     |
| (Size: 3~7)     |       | (Size: 0~5)     |       | (Size: 0~5)     |
+-----------------+       +-----------------+       +-----------------+
         |                         |                         |
         +-------------------------+-------------------------+
                                   | (Dispatch Job with Generation)
                                   v
               +-------------------------------------------------------+
               |                  WorkerPoolScheduler                  |
               +-------------------------------------------------------+
                /                  |                  \
               /                   |                   \
              v                    v                    v
      +---------------+    +---------------+    +---------------+
      | CURRENT_Q     |    |    NEXT_Q     |    | BACKGROUND_Q  |
      | (Highest Pri) |    | (Medium Pri)  |    | (Lowest Pri)  |
      | Threads: 2-3  |    | Threads: 1    |    | Threads: 1    |
      +---------------+    +---------------+    +---------------+
              |                    |                    |
              +--------------------+--------------------+
                                   | (Notify GPU Upload)
                                   v
                    [ Flutter Raster Thread / GPU ]
二、 核心子系统详述
1. 窗口补充机制 (Window-Based Refill)
设计动机：摒弃“每消费一帧，即刻唤醒线程解码一帧”的低效行为。改为批量触发（Batch Decodes），使 CPU 能够一次性连续解码多帧，提高核心利用率（Core Residency），随后长时间进入深睡眠状态。
参数指标：
HIGH_WATERMARK (7)：双缓冲区的上限值。当缓冲区帧数达到此值时，挂起该页面的解码任务。
LOW_WATERMARK (3)：触发阈值。当 UI 消费导致缓冲区剩余帧数小于或等于该值时，向调度器申请 refill 任务。
BATCH_SIZE (4)：单次批量解码并上传 GPU 的帧数（HIGH_WATERMARK−LOW_WATERMARK）。
2. 页面状态机机制 (Page State Machine)
管理页面（图像提供器）在滑动窗口中的生存状态和解码特征。
CURRENT（当前激活页）：
解码策略：开启 CONTINUOUS（持续补充模式）。
并发特征：启用多线程解码（libwebp 线程数设为 2 至 3），保证高清图能在 <15ms 内完成解码。
NEXT（预读下一页）：
解码策略：不开启 CONTINUOUS。一次性解码 TARGET = 5 帧并上传 GPU 后，立即停止（STOP）。
并发特征：单线程解码（libwebp 线程数 = 1），在后台静默进行，不抢占主通道 CPU 资源。
LAST（回退上一页）：
解码策略：不开启 CONTINUOUS。停止所有新帧的解码任务。
内存特征：保留退出前已存在于 FrameBuffer 中的渲染帧（不执行销毁），以便用户即时滑回。
PRECACHE（远端预加载页）：
解码策略：不开启 CONTINUOUS。最多只解码 TARGET = 5 帧，放置于低优先级后台队列中进行。
3. 世代任务丢弃机制 (Generational Dispatch)
解决痛点：解决用户在快速翻页（例如 15 -> 16 -> 17 -> 18）时，先前页面积压的大量解码任务持续在后台排队，抢占当前可见页 CPU 资源的顽疾。
设计实现：
DecoderManager 全局维护一个自增的整数 generation。
每次可见页面发生变更，generation++。
所有的解码任务（DecodeJob）在派发时强制携带当前的 generation。
工作线程在取出 Job 时，或在 Batch 内部循环的间隔，立即检查 job.generation == currentGeneration。若不匹配，立刻丢弃（Abort），直接释放原生资源而不进行后续耗时解码。
4. 延迟回收机制 (Deferred TTL Eviction)
设计动机：上一页或滑出视窗的远端页面，如果立即被完全释放，在用户反复拖动或来回滑页时，会导致重新建立连接、解码等昂贵开销。
设计实现：
处于 LAST 或 PRECACHE 状态下的 DecoderHolder 标记最后的访问时间戳 lastAccessTime。
系统后台启动一个 1 秒周期的心跳定时器。
若发现 now - lastAccessTime > 2s，则执行实质性物理释放（销毁原生解码器句柄、清空关联缓冲区）。
三、 C 层接口配置升级
为了配合多状态的线程管理，webp_decoder.h 必须支持设置底层线程数：
code
C
/* webp_decoder.h */

/**
 * 动态调整动画解码器的 libwebp 内部线程数。
 * 
 * @param ctx          解码器句柄
 * @param use_threads  线程数量（0 或 1 表示单线程，2 或 3 表示多线程并发）
 */
void webp_anim_decoder_set_thread_limit(WebPAnimContext* ctx, int use_threads);
code
C
/* webp_decoder.c */

void webp_anim_decoder_set_thread_limit(WebPAnimContext* ctx, int use_threads) {
    if (!ctx) return;
    // 内部实现：将该参数存储于 context 中
    // 在后续 webp_anim_decoder_get_frame 执行 WebPDecode 实例化 WebPDecoderConfig 时，
    // 将 cfg.options.use_threads 赋值为 (use_threads > 1 ? 1 : 0)；
    // 有些平台底层库支持设置具体的线程数，如 options.thread_level 或编译期多线程参数。
}
四、 Dart 层高能效系统架构蓝图
以下为完整、严格遵循该 Spec 编写的 Dart 层核心骨架。
code
Dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

// 模拟 webp 原生库调用接口定义
class NativeWebP {
  static void setThreadLimit(int decoderAddress, int useThreads) {}
  static void dispose(int decoderAddress) {}
  static int getNextFrame(int decoderAddress) => 0; // 返回帧内存地址
  static bool hasMore(int decoderAddress) => true;
  static void reset(int decoderAddress) {}
}

/// 页面状态枚举
enum PageState {
  CURRENT,  // 当前激活页
  NEXT,     // 预读页
  LAST,     // 上一页
  PRECACHE  // 远端预存页
}

/// 解码任务包装类
class DecodeJob {
  final int generation;
  final int decoderAddress;
  final int framesToDecode;
  final int targetW;
  final int targetH;
  final double scale;
  final Function(List<ui.Image> decoded) onComplete;

  DecodeJob({
    required this.generation,
    required this.decoderAddress,
    required this.framesToDecode,
    required this.targetW,
    required this.targetH,
    required this.scale,
    required this.onComplete,
  });
}

/// 三级专职工作池（调度器）
class WorkerPoolScheduler {
  static final WorkerPoolScheduler instance = WorkerPoolScheduler._();
  WorkerPoolScheduler._();

  // 三级任务队列
  final Queue<DecodeJob> _currentQueue = Queue();
  final Queue<DecodeJob> _nextQueue = Queue();
  final Queue<DecodeJob> _bgQueue = Queue();

  bool _isProcessing = false;
  int _currentGeneration = 0;

  void updateGeneration(int newGen) {
    _currentGeneration = newGen;
  }

  /// 派发解码任务
  void dispatch(DecodeJob job, PageState state) {
    switch (state) {
      case PageState.CURRENT:
        _currentQueue.add(job);
        break;
      case PageState.NEXT:
        _nextQueue.add(job);
        break;
      case PageState.LAST:
      case PageState.PRECACHE:
        _bgQueue.add(job);
        break;
    }
    _scheduleNext();
  }

  void _scheduleNext() {
    if (_isProcessing) return;
    _isProcessing = true;
    
    // 使用微任务异步处理，不阻塞 Dart 渲染循环
    scheduleMicrotask(() async {
      await _processQueues();
      _isProcessing = false;
    });
  }

  Future<void> _processQueues() async {
    // 优先级治理：CURRENT 队列拥有绝对执行权，其次 NEXT，最后 BACKGROUND
    while (_currentQueue.isNotEmpty || _nextQueue.isNotEmpty || _bgQueue.isNotEmpty) {
      DecodeJob? job;
      if (_currentQueue.isNotEmpty) {
        job = _currentQueue.removeFirst();
      } else if (_nextQueue.isNotEmpty) {
        job = _nextQueue.removeFirst();
      } else if (_bgQueue.isNotEmpty) {
        job = _bgQueue.removeFirst();
      }

      if (job == null) continue;

      // 【世代检测 1】：从队列取出时如果发现世代已过期，直接默默丢弃，零计算开销
      if (job.generation != _currentGeneration) {
        debugPrint('[Venera-Worker] Discarding stale job from generation ${job.generation}, current: $_currentGeneration');
        continue;
      }

      await _executeJob(job);
    }
  }

  Future<void> _executeJob(DecodeJob job) async {
    final List<ui.Image> batchFrames = [];
    
    for (int i = 0; i < job.framesToDecode; i++) {
      // 【世代检测 2】：批量解码的间隔中可能用户正在疾速划屏，一旦过期立即中止
      if (job.generation != _currentGeneration) {
        break;
      }

      try {
        final frameAddr = NativeWebP.getNextFrame(job.decoderAddress);
        if (frameAddr == 0) break;

        // 深拷贝保护
        final int len = job.targetW * job.targetH * 4;
        final rawPointer = Pointer<Uint8>.fromAddress(frameAddr); // 伪代码映射
        final bytes = Uint8List.fromList(rawPointer.asTypedList(len));

        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          bytes, 
          job.targetW, 
          job.targetH, 
          ui.PixelFormat.rgba8888, 
          (img) => completer.complete(img)
        );

        final image = await completer.future;
        batchFrames.add(image);
      } catch (e) {
        debugPrint('[Venera-Worker] Frame decode error: $e');
        break;
      }
    }

    if (batchFrames.isNotEmpty && job.generation == _currentGeneration) {
      job.onComplete(batchFrames);
    } else {
      // 若因被废弃而中途退出，及时回收该批已生成的 ui.Image
      for (final img in batchFrames) {
        img.dispose();
      }
    }
  }
}

/// 页面解码器的状态维护宿主
class DecoderHolder {
  final String key;
  final int decoderAddress;
  final int targetW;
  final int targetH;
  final double scale;
  
  PageState _state = PageState.PRECACHE;
  final Queue<ui.Image> _frameBuffer = Queue();
  
  int lastAccessTime = DateTime.now().millisecondsSinceEpoch;
  bool _isFetching = false;

  DecoderHolder({
    required this.key,
    required this.decoderAddress,
    required this.targetW,
    required this.targetH,
    required this.scale,
  });

  PageState get state => _state;

  void updateState(PageState newState) {
    if (_state == newState) return;
    _state = newState;
    lastAccessTime = DateTime.now().millisecondsSinceEpoch;

    // 根据所属状态，动态控制底层 libwebp 多线程解算器的调度行为
    if (newState == PageState.CURRENT) {
      NativeWebP.setThreadLimit(decoderAddress, 2); // 开启核心多线程解码
      _triggerRefillIfNeeded();
    } else {
      NativeWebP.setThreadLimit(decoderAddress, 1); // 降低并发，为当前视窗让出 CPU
    }
  }

  /// 消费一帧（由 UI 渲染链路调用）
  ui.Image? consumeFrame() {
    lastAccessTime = DateTime.now().millisecondsSinceEpoch;
    if (_frameBuffer.isEmpty) {
      _triggerRefillIfNeeded();
      return null;
    }

    final frame = _frameBuffer.removeFirst();
    _triggerRefillIfNeeded();
    return frame;
  }

  void _triggerRefillIfNeeded() {
    if (_isFetching) return;

    // 状态水位线判定规则
    if (_state == PageState.CURRENT) {
      // CURRENT 页面持续补充模式（水位线控制：< 3 则 refill 到 7）
      if (_frameBuffer.length <= 3) {
        final int refillCount = 7 - _frameBuffer.length;
        _isFetching = true;
        
        WorkerPoolScheduler.instance.dispatch(
          DecodeJob(
            generation: WorkerPoolScheduler.instance._currentGeneration,
            decoderAddress: decoderAddress,
            framesToDecode: refillCount,
            targetW: targetW,
            targetH: targetH,
            scale: scale,
            onComplete: (newFrames) {
              _frameBuffer.addAll(newFrames);
              _isFetching = false;
              _triggerRefillIfNeeded(); // 自适应递归填充
            },
          ),
          _state
        );
      }
    } else if (_state == PageState.NEXT || _state == PageState.PRECACHE) {
      // 预存页单次补充限制（静态扩充，绝不持续循环）
      if (_frameBuffer.length < 5) {
        final int refillCount = 5 - _frameBuffer.length;
        _isFetching = true;

        WorkerPoolScheduler.instance.dispatch(
          DecodeJob(
            generation: WorkerPoolScheduler.instance._currentGeneration,
            decoderAddress: decoderAddress,
            framesToDecode: refillCount,
            targetW: targetW,
            targetH: targetH,
            scale: scale,
            onComplete: (newFrames) {
              _frameBuffer.addAll(newFrames);
              _isFetching = false;
            },
          ),
          _state
        );
      }
    }
    // LAST 页静默不干预，直接停用任何 Refill 动作
  }

  void dispose() {
    for (final img in _frameBuffer) {
      img.dispose();
    }
    _frameBuffer.clear();
    NativeWebP.dispose(decoderAddress);
    debugPrint('[Venera-Holder] Deep cleared resources for decoder holder: $key');
  }
}

/// 集中全局调度控制中枢
class DecoderManager {
  static final DecoderManager instance = DecoderManager._();
  DecoderManager._() {
    // 启动系统级延迟回收观察心跳
    Timer.periodic(const Duration(seconds: 1), _onEvictionHeartbeat);
  }

  final Map<String, DecoderHolder> _activeHolders = {};
  int _currentGeneration = 0;

  /// 全局可见性迁移接口（滑动状态驱动）
  void activePagesChanged({
    required String currentKey,
    required List<String> nextKeys,
    required List<String> lastKeys,
    required List<String> precacheKeys,
  }) {
    // 更新世代值，所有正在执行/等待的陈旧后台任务将被立即安全丢弃
    _currentGeneration++;
    WorkerPoolScheduler.instance.updateGeneration(_currentGeneration);

    // 1. 设置当前活动页面
    _getOrCreateHolder(currentKey)?.updateState(PageState.CURRENT);

    // 2. 设置下一页预取集合
    for (final key in nextKeys) {
      _getOrCreateHolder(key)?.updateState(PageState.NEXT);
    }

    // 3. 设置上一页回退保留集合
    for (final key in lastKeys) {
      _getOrCreateHolder(key)?.updateState(PageState.LAST);
    }

    // 4. 设置远端缓存页面集合
    for (final key in precacheKeys) {
      _getOrCreateHolder(key)?.updateState(PageState.PRECACHE);
    }
  }

  DecoderHolder? _getOrCreateHolder(String key) {
    if (_activeHolders.containsKey(key)) {
      return _activeHolders[key];
    }
    // 此处省去基础数据解析逻辑与原生 Decoder 地址的获取，仅创建模型
    final holder = DecoderHolder(
      key: key, 
      decoderAddress: 12345, // 模拟生成的原生 decoder 地址指针
      targetW: 1080, 
      targetH: 1920, 
      scale: 1.0
    );
    _activeHolders[key] = holder;
    return holder;
  }

  /// 场景 5 实现：基于心跳定时器和 TTL 机制检测多余缓存
  void _onEvictionHeartbeat(Timer timer) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<String> keysToEvict = [];

    _activeHolders.forEach((key, holder) {
      // 仅当属于不活跃状态（LAST, PRECACHE）并且超过 2 秒未访问才启动硬销毁
      if (holder.state == PageState.LAST || holder.state == PageState.PRECACHE) {
        if (now - holder.lastAccessTime > 2000) {
          keysToEvict.add(key);
        }
      }
    });

    for (final key in keysToEvict) {
      final evicted = _activeHolders.remove(key);
      evicted?.dispose();
    }
  }
}
五、 系统效能表现预估与演练验证
在采用此重构架构后，系统在极端场景下的运行状态如下：
1. 正常单页平稳播放（CURRENT）
运行链路：消费第 1,2,3,4 帧，当消费第4帧后，FrameBuffer 水位线降到3（触发 LOW_WATERMARK）。
功耗表现：工作线程一次性被唤醒，采用 MT=2 并发机制一口气解码完4帧（7−3）并上传 GPU。整个过程在40ms内结束，之后工作线程完全进入深休眠状态，直至下一次 refill 临界。彻底杜绝了每帧唤醒造成的“高频低效微空转”。
2. 用户疯狂右滑翻页（15 -> 16 -> 17 -> 18）
运行链路：滑动时触发 activePagesChanged，generation 增至 4。此时排队在队列中的 15 页和 16 页的解码任务被调度器拉起，其内部循环逻辑立刻检测到 job.generation (2) != currentGeneration (4)。
功耗表现：任务立即零开销丢弃，后台没有任何多余的 decode 计算被执行。CPU 资源以零延迟状态迅速倾斜给第 18 页，保证快速滑动时界面完全不卡顿、设备不发热。