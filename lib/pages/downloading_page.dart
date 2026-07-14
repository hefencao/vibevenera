import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/pipeline/cache_download_progress_publisher.dart';
import 'package:venera/foundation/image_provider/pipeline/pipeline_controller.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  DownloadTask? firstTask;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    firstTask = LocalManager().downloadingTasks.firstOrNull;
    firstTask?.addListener(update);
  }

  @override
  void initState() {
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    firstTask?.removeListener(update);
    super.dispose();
  }

  void update() {
    var currentFirstTask = LocalManager().downloadingTasks.firstOrNull;
    if (currentFirstTask != firstTask) {
      firstTask?.removeListener(update);
      firstTask = currentFirstTask;
      firstTask?.addListener(update);
    }
    if(mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: PopUpWidgetScaffold(
        title: "Download".tl,
        body: Column(
          children: [
            TabBar(
              tabs: [
                Tab(text: "Requests".tl),
                Tab(text: "Cache".tl),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildRequestedDownloads(),
                  _buildCacheDownloads(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestedDownloads() {
    return ListView.builder(
      itemCount: LocalManager().downloadingTasks.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) return buildTop();
        i--;
        return _DownloadTaskTile(
          key: ValueKey(LocalManager().downloadingTasks[i]),
          task: LocalManager().downloadingTasks[i],
        );
      },
    );
  }

  Widget _buildCacheDownloads() {
    return ValueListenableBuilder<List<CacheDownloadProgress>>(
      valueListenable: PipelineController.instance.cacheDownloadProgress,
      builder: (context, downloads, _) {
        if (downloads.isEmpty) return const SizedBox();
        return ListView.builder(
          itemCount: downloads.length,
          itemBuilder: (context, index) => _CacheDownloadTaskTile(
            key: ValueKey(downloads[index].identity),
            download: downloads[index],
          ),
        );
      },
    );
  }

  Widget buildTop() {
    int speed = 0;
    if (LocalManager().downloadingTasks.isNotEmpty) {
      speed = LocalManager().downloadingTasks.first.speed;
    }
    var first = LocalManager().downloadingTasks.firstOrNull;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          if (first?.isPaused == true)
            Text(
              "Paused".tl,
              style: ts.s18.bold,
            )
          else if (first?.isError == true)
            Text(
              "Error".tl,
              style: ts.s18.bold,
            )
          else
            Text(
              "${bytesToReadableString(speed)}/s",
              style: ts.s18.bold,
            ),
          const Spacer(),
          if (first?.isPaused == true || first?.isError == true)
            OutlinedButton(
              child: Row(
                children: [
                  const Icon(Icons.play_arrow, size: 18),
                  const SizedBox(width: 4),
                  Text("Start".tl),
                ],
              ),
              onPressed: () {
                first!.resume();
              },
            )
          else if (first != null)
            OutlinedButton(
              child: Row(
                children: [
                  const Icon(Icons.pause, size: 18),
                  const SizedBox(width: 4),
                  Text("Pause".tl),
                ],
              ),
              onPressed: () {
                first.pause();
              },
            ),
        ],
      ).paddingHorizontal(16),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _CacheDownloadTaskTile extends StatelessWidget {
  const _CacheDownloadTaskTile({required this.download, super.key});

  final CacheDownloadProgress download;

  @override
  Widget build(BuildContext context) {
    final status = switch (download.transport) {
      DownloadTransportState.paused => "Paused".tl,
      DownloadTransportState.failed => "Error".tl,
      _ => '${bytesToReadableString(download.speedBytesPerSecond.toInt())}/s',
    };
    return Container(
      height: 88,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: context.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.cached),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  download.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(value: download.progress),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${"Rank".tl} ${download.rank} · $status',
                      style: ts.s12,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 136,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 82,
            height: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: context.colorScheme.primaryContainer,
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.task.cover == null
                ? null
                : Image(
                    image: CachedImageProvider(widget.task.cover!),
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.task.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 2,
                      ),
                    ),
                    MenuButton(
                      entries: [
                        MenuEntry(
                          icon: Icons.close,
                          text: "Cancel".tl,
                          onClick: () {
                            widget.task.cancel();
                          },
                        ),
                        MenuEntry(
                          icon: Icons.vertical_align_top,
                          text: "Move To First".tl,
                          onClick: () {
                            LocalManager().moveToFirst(widget.task);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                if (!widget.task.isPaused || widget.task.isError)
                  Text(
                    widget.task.message,
                    style: ts.s12,
                    maxLines: 3,
                  ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: widget.task.progress,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
