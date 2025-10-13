import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../layout.dart';
import '../models/media_item.dart';
import '../state/app_environment.dart';
import '../state/providers.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  const VideoPlayerScreen({super.key, required this.record});

  final VideoRecord record;

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  late VideoPlayerController _controller;

  Timer? _positionTimer;
  Timer? _transcriptCheckTimer;
  Timer? _controlsHideTimer;
  bool _initializing = true;
  bool _isPlaying = false;
  bool _controlsVisible = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _scrubOverride;
  String? _errorMessage;

  List<_SubtitleEntry> _subtitleEntries = const [];
  int? _activeSubtitleIndex;
  String? _activeSubtitle;
  String? _subtitleError;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final env = ref.read(appEnvironmentProvider);
      final videoUri = widget.record.buildPreviewUri(env.baseUri);

      setState(() {
        _initializing = true;
        _errorMessage = null;
        _subtitleEntries = const [];
        _activeSubtitleIndex = null;
        _activeSubtitle = null;
        _subtitleError = null;
      });

      // Initialize video player controller
      _controller = VideoPlayerController.networkUrl(videoUri);

      // Add listeners
      _controller.addListener(_onVideoPlayerUpdate);

      // Always try to load subtitles - transcription might be available even if not marked in database
      final subtitlesFuture = _loadSubtitleEntries();

      // Initialize player
      await _controller.initialize();
      
      // Start playing
      await _controller.play();

      // Start position timer
      _startPositionTimer();

      // Start transcript check timer if no subtitles are loaded yet
      if (_subtitleEntries.isEmpty) {
        _startTranscriptCheckTimer();
      }

      // Start controls hide timer
      _startControlsHideTimer();

      final subtitleResult = await subtitlesFuture;
      if (!mounted) return;
      setState(() {
        _subtitleEntries = subtitleResult.entries;
        _subtitleError = subtitleResult.error;
        _initializing = false;
        _duration = _controller.value.duration;
        _isPlaying = _controller.value.isPlaying;
      });
      _updateSubtitleForPosition(_position);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _initializing = false;
      });
    }
  }

  void _onVideoPlayerUpdate() {
    if (!mounted) return;
    final value = _controller.value;
    setState(() {
      _isPlaying = value.isPlaying;
      _duration = value.duration;
      if (!value.isBuffering) {
        _position = value.position;
      }
    });
    
    if (value.hasError) {
      setState(() {
        _errorMessage = value.errorDescription;
      });
    }
  }

  void _startPositionTimer() {
    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || !_controller.value.isInitialized) return;
      
      final position = _controller.value.position;
      if (position != _position) {
        setState(() {
          _position = position;
        });
        _updateSubtitleForPosition(position);
      }
    });
  }

  void _togglePlayback() {
    if (_controller.value.isPlaying) {
      _controller.pause();
      _controlsHideTimer?.cancel();
    } else {
      _controller.play();
      _startControlsHideTimer();
    }
    _showControls();
  }

  void _seekBySeconds(int seconds) {
    final target = _position + Duration(seconds: seconds);
    _seekTo(target);
    _showControls();
  }

  void _seekTo(Duration target) {
    var microseconds = target.inMicroseconds;
    if (microseconds < 0) {
      microseconds = 0;
    }
    final durationMicroseconds = _duration.inMicroseconds;
    if (durationMicroseconds > 0 && microseconds > durationMicroseconds) {
      microseconds = durationMicroseconds;
    }
    final clamped = Duration(microseconds: microseconds);
    _controller.seekTo(clamped);
    _updateSubtitleForPosition(clamped);
    _showControls();
  }

  Duration get _effectiveSliderPosition => _scrubOverride ?? _position;

  void _startTranscriptCheckTimer() {
    _transcriptCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      // Only check if we don't have subtitles yet
      if (_subtitleEntries.isEmpty) {
        final result = await _loadSubtitleEntries();
        if (mounted && result.entries.isNotEmpty) {
          setState(() {
            _subtitleEntries = result.entries;
            _subtitleError = result.error;
          });
          _updateSubtitleForPosition(_position);
          timer.cancel(); // Stop checking once we have subtitles
        }
      } else {
        timer.cancel(); // Stop checking if we already have subtitles
      }
    });
  }

  void _startControlsHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) {
        setState(() {
          _controlsVisible = false;
        });
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() {
        _controlsVisible = true;
      });
    }
    _startControlsHideTimer();
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
    });
    if (_controlsVisible) {
      _startControlsHideTimer();
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _transcriptCheckTimer?.cancel();
    _controlsHideTimer?.cancel();
    _controller.removeListener(_onVideoPlayerUpdate);
    _controller.dispose();
    super.dispose();
  }

  Future<_SubtitleLoadResult> _loadSubtitleEntries() async {
    try {
      print('Loading subtitles for: ${widget.record.path}'); // Debug
      final api = ref.read(apiClientProvider);
      final response = await api.fetchVideoTranscript(widget.record.path);
      print('Transcript response length: ${response?.length ?? 0}'); // Debug
      if (response == null || response.trim().isEmpty) {
        print('No transcript content'); // Debug
        return const _SubtitleLoadResult(entries: []);
      }
      final entries = _parseSrt(response);
      print('Parsed ${entries.length} subtitle entries'); // Debug
      if (entries.isNotEmpty) {
        print('First entry: ${entries.first.start} - ${entries.first.end}: "${entries.first.text}"'); // Debug
      }
      if (entries.isEmpty) {
        return const _SubtitleLoadResult(entries: []);
      }
      return _SubtitleLoadResult(entries: entries, error: null);
    } catch (error) {
      print('Error loading subtitles: $error'); // Debug
      // Silent fail for missing transcripts - don't show error if transcript just doesn't exist
      return const _SubtitleLoadResult(entries: []);
    }
  }

  void _updateSubtitleForPosition(Duration position) {
    if (_subtitleEntries.isEmpty) {
      if (_activeSubtitleIndex != null || _activeSubtitle != null) {
        setState(() {
          _activeSubtitleIndex = null;
          _activeSubtitle = null;
        });
      }
      return;
    }

    int? nextIndex = _activeSubtitleIndex;

    if (nextIndex != null) {
      final current = _subtitleEntries[nextIndex];
      if (position >= current.start && position <= current.end) {
        // Already in the right segment, ensure subtitle is set if it wasn't before
        if (nextIndex != _activeSubtitleIndex || _activeSubtitle != current.text) {
          setState(() {
            _activeSubtitleIndex = nextIndex;
            _activeSubtitle = current.text;
          });
        }
        return;
      }
      if (position < current.start) {
        for (var i = nextIndex - 1; i >= 0; i--) {
          final entry = _subtitleEntries[i];
          if (position > entry.end) {
            break;
          }
          if (position >= entry.start && position <= entry.end) {
            nextIndex = i;
            break;
          }
        }
      } else {
        for (var i = nextIndex + 1; i < _subtitleEntries.length; i++) {
          final entry = _subtitleEntries[i];
          if (position < entry.start) {
            nextIndex = null;
            break;
          }
          if (position <= entry.end) {
            nextIndex = i;
            break;
          }
        }
      }
    }

    if (nextIndex == null || nextIndex < 0 || nextIndex >= _subtitleEntries.length) {
      int? found;
      for (var i = 0; i < _subtitleEntries.length; i++) {
        final entry = _subtitleEntries[i];
        if (position < entry.start) {
          break;
        }
        if (position <= entry.end) {
          found = i;
          break;
        }
      }
      nextIndex = found;
    }

    if (nextIndex == null) {
      if (_activeSubtitleIndex != null || _activeSubtitle != null) {
        setState(() {
          _activeSubtitleIndex = null;
          _activeSubtitle = null;
        });
      }
      return;
    }

    final entry = _subtitleEntries[nextIndex];
    if (nextIndex != _activeSubtitleIndex || entry.text != _activeSubtitle) {
      print('Updating subtitle at ${position.inSeconds}s: "${entry.text}"'); // Debug
      setState(() {
        _activeSubtitleIndex = nextIndex;
        _activeSubtitle = entry.text;
      });
    }
  }

  List<_SubtitleEntry> _parseSrt(String data) {
    final normalized = data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final entries = <_SubtitleEntry>[];
    Duration? start;
    Duration? end;
    final buffer = <String>[];

    void flush() {
      if (start == null || end == null || buffer.isEmpty) {
        start = null;
        end = null;
        buffer.clear();
        return;
      }
      var subtitleStart = start!;
      var subtitleEnd = end!;
      if (subtitleEnd <= subtitleStart) {
        subtitleEnd = subtitleStart + const Duration(milliseconds: 400);
      }
      final text = buffer.join('\n').trim();
      if (text.isNotEmpty) {
        entries.add(_SubtitleEntry(start: subtitleStart, end: subtitleEnd, text: text));
      }
      start = null;
      end = null;
      buffer.clear();
    }

    final indexPattern = RegExp(r'^\d+$');

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        flush();
        continue;
      }
      final arrow = line.indexOf('-->');
      if (arrow != -1) {
        final parts = line.split('-->');
        if (parts.length == 2) {
          start = _parseSrtTimestamp(parts[0]);
          end = _parseSrtTimestamp(parts[1]);
          buffer.clear();
          continue;
        }
      }
      if (start == null && indexPattern.hasMatch(line)) {
        continue;
      }
      buffer.add(rawLine.trimRight());
    }
    flush();
    return entries;
  }

  Duration _parseSrtTimestamp(String value) {
    final match = RegExp(r'^(\d+):(\d+):(\d+)[,.](\d{1,3})').firstMatch(value.trim());
    if (match == null) {
      return Duration.zero;
    }
    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    final fraction = match.group(4)!;
    final milliseconds = int.parse(fraction.padRight(3, '0').substring(0, 3));
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  String _formatDuration(Duration duration) {
    if (duration <= Duration.zero) {
      return '00:00';
    }
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  double get _currentAspectRatio {
    if (_controller.value.isInitialized) {
      return _controller.value.aspectRatio;
    }
    return 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = ScreenLayout.isTargetSize(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              flex: 2,
              child: _buildVideoContainer(isCompact),
            ),
            Expanded(
              child: _buildMetadataSection(context, isCompact),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoContainer(bool isCompact) {
    return Container(
      width: double.infinity,
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _currentAspectRatio,
          child: _buildPlayerBody(isCompact),
        ),
      ),
    );
  }

  Widget _buildPlayerBody(bool isCompact) {
    final hasError = _errorMessage != null;

    return GestureDetector(
      onTap: _toggleControls,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black),
          if (!hasError && _controller.value.isInitialized)
            VideoPlayer(_controller),
        if (_initializing)
          const Center(
            child: SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ),
        if (_controller.value.isBuffering && !_initializing && !hasError)
          const Center(
            child: SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
              ),
            ),
          ),
        if (hasError) _buildErrorMessage(isCompact),
        _buildExitButton(isCompact),
        if (!hasError && !_initializing) _buildControlsOverlay(isCompact),
        if (!hasError && _activeSubtitle != null && _activeSubtitle!.isNotEmpty)
          _buildSubtitleOverlay(isCompact),
        ],
      ),
    );
  }

  Widget _buildErrorMessage(bool isCompact) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.white70,
              size: isCompact ? 40 : 48,
            ),
            const SizedBox(height: 12),
            Text(
              'Unable to load video.',
              style: TextStyle(
                color: Colors.white,
                fontSize: isCompact ? 16 : 18,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: isCompact ? 12 : 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildExitButton(bool isCompact) {
    return Positioned(
      left: 0,
      top: 0,
      child: SafeArea(
        minimum: EdgeInsets.all(isCompact ? 8 : 12),
        child: Material(
          color: Colors.black.withOpacity(0.6),
          shape: const CircleBorder(),
          child: IconButton(
            icon: const Icon(Icons.close),
            iconSize: isCompact ? 22 : 26,
            color: Colors.white,
            tooltip: 'Exit',
            padding: EdgeInsets.all(isCompact ? 8 : 10),
            constraints: const BoxConstraints(),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(bool isCompact) {
    if (!_controlsVisible) {
      return const SizedBox.shrink();
    }

    final durationMs = _duration.inMilliseconds;
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final rawPosition = _effectiveSliderPosition.inMilliseconds.toDouble();
    final double sliderValue = durationMs > 0
        ? rawPosition.clamp(0.0, sliderMax)
        : 0.0;

    final timeStyle = TextStyle(
      color: Colors.white70,
      fontSize: isCompact ? 12 : 13,
    );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 12 : 24,
          vertical: isCompact ? 12 : 18,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.0),
              Colors.black.withOpacity(0.35),
              Colors.black.withOpacity(0.75),
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: isCompact ? 2.5 : 3,
                thumbColor: Colors.white,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white30,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                min: 0.0,
                max: sliderMax,
                value: sliderValue.isFinite ? sliderValue : 0.0,
                onChanged: durationMs > 0
                    ? (value) {
                        setState(() {
                          _scrubOverride = Duration(milliseconds: value.round());
                        });
                      }
                    : null,
                onChangeEnd: durationMs > 0
                    ? (value) {
                        final target = Duration(milliseconds: value.round());
                        setState(() {
                          _scrubOverride = null;
                        });
                        _seekTo(target);
                      }
                    : null,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(_effectiveSliderPosition), style: timeStyle),
                Text(_formatDuration(_duration), style: timeStyle),
              ],
            ),
            SizedBox(height: isCompact ? 8 : 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildPlaybackButton(
                  icon: Icons.replay_10,
                  tooltip: 'Rewind 10 seconds',
                  onPressed: () => _seekBySeconds(-10),
                  size: isCompact ? 32 : 36,
                ),
                SizedBox(width: isCompact ? 24 : 32),
                _buildPlaybackButton(
                  icon: _isPlaying ? Icons.pause_circle : Icons.play_circle,
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                  onPressed: _togglePlayback,
                  size: isCompact ? 54 : 64,
                ),
                SizedBox(width: isCompact ? 24 : 32),
                _buildPlaybackButton(
                  icon: Icons.forward_10,
                  tooltip: 'Forward 10 seconds',
                  onPressed: () => _seekBySeconds(10),
                  size: isCompact ? 32 : 36,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackButton({
    required IconData icon,
    required VoidCallback onPressed,
    required double size,
    String? tooltip,
  }) {
    return IconButton(
      icon: Icon(icon),
      iconSize: size,
      color: Colors.white,
      splashRadius: size / 2,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  Widget _buildSubtitleOverlay(bool isCompact) {
    final horizontalInset = isCompact ? 16.0 : 24.0;
    final padding = EdgeInsets.symmetric(
      horizontal: isCompact ? 12 : 16,
      vertical: isCompact ? 6 : 8,
    );
    final bottomOffset = isCompact ? 120.0 : 140.0;

    return Positioned(
      left: horizontalInset,
      right: horizontalInset,
      bottom: bottomOffset,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.65),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: padding,
            child: Text(
              _activeSubtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: isCompact ? 14 : 16,
                height: 1.35,
                fontWeight: FontWeight.w600,
                shadows: const [
                  Shadow(color: Colors.black87, offset: Offset(0, 1), blurRadius: 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataSection(BuildContext context, bool isCompact) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surface,
      child: ListView(
        padding: EdgeInsets.all(isCompact ? 12 : 16),
        children: [
          if (widget.record.filename != null)
            _InfoRow(label: 'Name', value: widget.record.filename!),
          if (widget.record.locationLabel != null)
            _InfoRow(label: 'Location', value: widget.record.locationLabel!),
          if (widget.record.capturedAtDisplay != null)
            _InfoRow(label: 'Captured', value: widget.record.capturedAtDisplay!),
          if (widget.record.folder != null)
            _InfoRow(label: 'Folder', value: widget.record.folder!),
          if (widget.record.duration != null)
            _InfoRow(label: 'Duration', value: _formatDuration(widget.record.duration!)),
          if (widget.record.transcriptState != null)
            _InfoRow(label: 'Transcript Status', value: widget.record.transcriptState!),
          if (_subtitleEntries.isNotEmpty)
            const _InfoRow(label: 'Subtitles', value: 'Available (SRT)'),
          if (_subtitleEntries.isEmpty && widget.record.transcriptAvailable)
            _InfoRow(
              label: 'Subtitles',
              value: _subtitleError ?? 'Loading…',
            ),
          if (_subtitleEntries.isEmpty && !widget.record.transcriptAvailable)
            const _InfoRow(
              label: 'Subtitles',
              value: 'Checking for transcription…',
            ),
          const SizedBox(height: 16),
          Text(
            widget.record.path,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleEntry {
  const _SubtitleEntry({required this.start, required this.end, required this.text});

  final Duration start;
  final Duration end;
  final String text;
}

class _SubtitleLoadResult {
  const _SubtitleLoadResult({required this.entries, this.error});

  final List<_SubtitleEntry> entries;
  final String? error;
}
