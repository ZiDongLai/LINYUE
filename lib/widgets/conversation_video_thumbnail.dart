import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../services/native_video_frame_thumbnail.dart';

/// A real frame where supported; a plainly generic poster otherwise.
/// The play button and its click target are supplied by the parent card.
class ConversationVideoThumbnail extends StatefulWidget {
  const ConversationVideoThumbnail({
    super.key, required this.path, required this.width, required this.height,
  });

  final String? path;
  final double width;
  final double height;

  @override
  State<ConversationVideoThumbnail> createState() => _ConversationVideoThumbnailState();
}

class _ConversationVideoThumbnailState extends State<ConversationVideoThumbnail> {
  late Future<Uint8List?> _preview;

  @override
  void initState() {
    super.initState();
    _preview = NativeVideoFrameThumbnail.get(widget.path);
  }

  @override
  void didUpdateWidget(covariant ConversationVideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _preview = NativeVideoFrameThumbnail.get(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: FutureBuilder<Uint8List?>(
        future: _preview,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFF254954), Color(0xFF0C1D2B)],
              ),
            ),
            child: bytes == null
                ? const Center(child: Icon(Icons.movie_creation_outlined,
                    size: 68, color: Color(0x6680C6C4)))
                : Image.memory(bytes, fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.movie_creation_outlined,
                        size: 68, color: Color(0x6680C6C4)),
                    )),
          );
        },
      ),
    ),
  );
}
