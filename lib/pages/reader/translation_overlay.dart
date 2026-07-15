part of 'reader.dart';

class _ReaderTranslationLayer extends StatelessWidget {
  final int pageIndex;
  final Alignment alignment;
  final Widget child;

  const _ReaderTranslationLayer({
    required this.pageIndex,
    required this.child,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    if (!reader.translationSession.enabled) return child;
    final identity = reader.translationIdentity(pageIndex);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ValueListenableBuilder<ComicTranslationPageState>(
                valueListenable:
                    reader.translationSession.listenable(identity),
                builder: (context, state, _) {
                  final artifact = state.artifact;
                  if (state.phase != ComicTranslationPhase.ready ||
                      artifact == null) {
                    return const SizedBox();
                  }
                  return CustomPaint(
                    painter: _ComicTranslationPainter(
                      artifact: artifact,
                      fit: BoxFit.contain,
                      alignment: alignment,
                      background: context.colorScheme.surface.withValues(
                        alpha: 0.88,
                      ),
                      foreground: context.colorScheme.onSurface,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ComicTranslationPainter extends CustomPainter {
  final ComicTranslationArtifact artifact;
  final BoxFit fit;
  final Alignment alignment;
  final Color background;
  final Color foreground;

  const _ComicTranslationPainter({
    required this.artifact,
    required this.fit,
    required this.alignment,
    required this.background,
    required this.foreground,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sourceSize = Size(
      artifact.imageWidth.toDouble(),
      artifact.imageHeight.toDouble(),
    );
    final fitted = applyBoxFit(fit, sourceSize, size);
    final imageRect = alignment.inscribe(fitted.destination, Offset.zero & size);
    for (final region in artifact.regions) {
      if (region.kind == ComicTextKind.soundEffect ||
          region.translatedText.trim().isEmpty ||
          region.polygon.isEmpty) {
        continue;
      }
      final points = region.polygon.map((point) => Offset(
        imageRect.left + point.x * imageRect.width,
        imageRect.top + point.y * imageRect.height,
      ));
      final bounds = _bounds(points).inflate(4).intersect(imageRect);
      if (bounds.width < 12 || bounds.height < 12) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(bounds, const Radius.circular(8)),
        Paint()..color = background,
      );
      final paragraph = _fitText(region.translatedText, bounds.deflate(4));
      paragraph.paint(
        canvas,
        Offset(
          bounds.left + (bounds.width - paragraph.width) / 2,
          bounds.top + (bounds.height - paragraph.height) / 2,
        ),
      );
    }
  }

  TextPainter _fitText(String text, Rect bounds) {
    var low = 6.0;
    var high = math.min(42.0, bounds.height);
    late TextPainter painter;
    for (var i = 0; i < 7; i++) {
      final size = (low + high) / 2;
      painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: foreground,
            fontSize: size,
            height: 1.05,
            fontWeight: FontWeight.w500,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: bounds.width);
      if (painter.height <= bounds.height) {
        low = size;
      } else {
        high = size;
      }
    }
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: foreground,
          fontSize: low,
          height: 1.05,
          fontWeight: FontWeight.w500,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bounds.width);
  }

  Rect _bounds(Iterable<Offset> points) {
    final iterator = points.iterator;
    iterator.moveNext();
    var left = iterator.current.dx;
    var top = iterator.current.dy;
    var right = left;
    var bottom = top;
    while (iterator.moveNext()) {
      final point = iterator.current;
      left = math.min(left, point.dx);
      top = math.min(top, point.dy);
      right = math.max(right, point.dx);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  bool shouldRepaint(covariant _ComicTranslationPainter oldDelegate) =>
      oldDelegate.artifact != artifact ||
      oldDelegate.fit != fit ||
      oldDelegate.alignment != alignment ||
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}
