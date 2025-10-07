import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout.dart';
import '../models/media_item.dart';
import '../state/app_environment.dart';

class PhotoViewerScreen extends ConsumerStatefulWidget {
  const PhotoViewerScreen({super.key, required this.item});

  final PhotoItem item;

  @override
  ConsumerState<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends ConsumerState<PhotoViewerScreen> {
  int _rotationQuarterTurns = 0;

  void _rotateImage() {
    setState(() {
      _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4;
    });
  }

  @override
  Widget build(BuildContext context) {
    final env = ref.watch(appEnvironmentProvider);
    final imageUrl = widget.item.buildPreviewUri(env.baseUri).toString();
    final isCompact = ScreenLayout.isTargetSize(context);
    final padding = EdgeInsets.all(isCompact ? 12 : 16);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: RotatedBox(
                  quarterTurns: _rotationQuarterTurns,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return const Center(child: CircularProgressIndicator(color: Colors.white70));
                    },
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white70,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: padding,
                child: _ExitButton(compact: isCompact),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: padding,
                child: _RotateButton(
                  compact: isCompact,
                  onRotate: _rotateImage,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExitButton extends StatelessWidget {
  const _ExitButton({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 44.0 : 48.0;
    final iconSize = compact ? 22.0 : 24.0;
    return Material(
      color: Colors.black.withOpacity(0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.of(context).maybePop(),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.close, size: iconSize, color: Colors.white),
        ),
      ),
    );
  }
}

class _RotateButton extends StatelessWidget {
  const _RotateButton({required this.compact, required this.onRotate});

  final bool compact;
  final VoidCallback onRotate;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 44.0 : 48.0;
    final iconSize = compact ? 22.0 : 24.0;
    return Material(
      color: Colors.black.withOpacity(0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onRotate,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.rotate_90_degrees_ccw, size: iconSize, color: Colors.white),
        ),
      ),
    );
  }
}
