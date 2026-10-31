import 'dart:io';
import 'package:flutter/material.dart';
import 'file_visual_badge.dart';

/// Only existing small local images may enter the in-app viewer. Do not follow
/// symlinks, and never treat a generated sent thumbnail as an original.
Future<bool> mayPreviewLocalImage(String displayName, String? localPath, {
  int maxSourceBytes = 25 * 1024 * 1024,
}) async {
  if (!supportsInlineThumbnail(displayName)) return false;
  return mayLoadImageThumbnail(localPath, maxSourceBytes: maxSourceBytes);
}

/// E14: a local preview source. [onSave] must only be provided for a verified
/// received ORIGINAL; sent originals already belong to the sender, and a sent
/// thumbnail cannot be exported as if it were the original.
class ImagePreviewItem {
  const ImagePreviewItem({
    required this.file,
    required this.displayName,
    this.isSentThumbnail = false,
    this.onSave,
  });

  final File file;
  final String displayName;
  final bool isSentThumbnail;
  final VoidCallback? onSave;
}

/// Shared desktop/Android image viewer. [items] enables chronological previous
/// and next navigation without returning to the transfer conversation. The
/// legacy single-file constructor remains compatible with prior callers/tests.
class ReceivedImagePreviewPage extends StatefulWidget {
  const ReceivedImagePreviewPage({
    super.key,
    required this.file,
    required this.displayName,
    this.isSentThumbnail = false,
    this.onSave,
    this.saveLabel = '另存图片',
    this.items,
    this.initialIndex = 0,
  });

  final File file;
  final String displayName;
  final bool isSentThumbnail;
  final VoidCallback? onSave;
  final String saveLabel;
  final List<ImagePreviewItem>? items;
  final int initialIndex;

  @override
  State<ReceivedImagePreviewPage> createState() => _ReceivedImagePreviewPageState();
}

class _ReceivedImagePreviewPageState extends State<ReceivedImagePreviewPage> {
  late final List<ImagePreviewItem> _items;
  late final PageController _pages;
  final Map<int, GlobalKey<_PreviewImageCanvasState>> _canvases = {};
  late int _index;

  ImagePreviewItem get _current => _items[_index];

  @override
  void initState() {
    super.initState();
    _items = (widget.items == null || widget.items!.isEmpty)
        ? <ImagePreviewItem>[
            ImagePreviewItem(
              file: widget.file,
              displayName: widget.displayName,
              isSentThumbnail: widget.isSentThumbnail,
              onSave: widget.onSave,
            ),
          ]
        : List<ImagePreviewItem>.unmodifiable(widget.items!);
    _index = widget.initialIndex.clamp(0, _items.length - 1).toInt();
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= _items.length || !_pages.hasClients) return;
    _pages.animateToPage(target,
        duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  void _zoom(double multiplier) =>
      _canvases[_index]?.currentState?.zoom(multiplier);

  void _resetZoom() => _canvases[_index]?.currentState?.resetZoom();

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      backgroundColor: const Color(0xFF07151D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF102B33),
        leading: IconButton(
          tooltip: '关闭预览',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(current.displayName,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
        actions: [
          if (current.onSave != null && !current.isSentThumbnail)
            TextButton.icon(
              onPressed: current.onSave,
              icon: const Icon(Icons.download_rounded, size: 19),
              label: Text(widget.saveLabel),
            ),
          IconButton(
            tooltip: '缩小',
            icon: const Icon(Icons.zoom_out_rounded),
            onPressed: () => _zoom(0.8),
          ),
          IconButton(
            tooltip: '放大',
            icon: const Icon(Icons.zoom_in_rounded),
            onPressed: () => _zoom(1.25),
          ),
          IconButton(
            tooltip: '还原',
            icon: const Icon(Icons.fit_screen_rounded),
            onPressed: _resetZoom,
          ),
        ],
      ),
      body: SafeArea(child: Column(children: [
        Expanded(child: PageView.builder(
          controller: _pages,
          itemCount: _items.length,
          onPageChanged: (page) => setState(() => _index = page),
          itemBuilder: (context, index) => _PreviewImageCanvas(
            key: _canvases.putIfAbsent(
                index, () => GlobalKey<_PreviewImageCanvasState>()),
            file: _items[index].file,
          ),
        )),
        if (_items.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                tooltip: '上一张',
                onPressed: _index == 0 ? null : () => _move(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Text('${_index + 1} / ${_items.length}',
                  style: const TextStyle(color: Color(0xFFE2EEEC))),
              IconButton(
                tooltip: '下一张',
                onPressed: _index == _items.length - 1
                    ? null : () => _move(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Text(
            current.isSentThumbnail
                ? '当前显示缩略图 · 发送记录仅保留缩略图，无法还原原图分辨率'
                : _items.length > 1
                    ? '左右滑动切换 · 双指或鼠标缩放 · 图片仅在本机预览'
                    : '鼠标滚轮或双指缩放 · 拖动查看 · 图片仅在本机预览',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Color(0xFFA9C0C3)),
          ),
        ),
      ])),
    );
  }
}

/// Each page owns its own zoom controller: switching images cannot carry a
/// previous image's zoom/offset into the next image.
class _PreviewImageCanvas extends StatefulWidget {
  const _PreviewImageCanvas({super.key, required this.file});
  final File file;

  @override
  State<_PreviewImageCanvas> createState() => _PreviewImageCanvasState();
}

class _PreviewImageCanvasState extends State<_PreviewImageCanvas> {
  final TransformationController _transform = TransformationController();

  void zoom(double multiplier) {
    final current = _transform.value.getMaxScaleOnAxis();
    final next = (current * multiplier).clamp(1.0, 5.0).toDouble();
    _transform.value = Matrix4.identity()..scale(next);
  }

  void resetZoom() => _transform.value = Matrix4.identity();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) => ClipRect(
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1.0,
        maxScale: 5.0,
        child: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Image.file(
            widget.file,
            fit: BoxFit.contain,
            cacheWidth: 2560,
            cacheHeight: 2560,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.broken_image_outlined,
                    size: 40, color: Color(0xFFB5CCD0)),
                SizedBox(height: 10),
                Text('图片无法预览或已被移动',
                    style: TextStyle(color: Color(0xFFE2EEEC))),
              ]),
            ),
          ),
        ),
      ),
    ));
  }
}
