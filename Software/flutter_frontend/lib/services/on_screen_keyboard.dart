import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class OnScreenKeyboardController {
  OnScreenKeyboardController({
    String? program,
    List<String>? fallbackPrograms,
    this.hideDelay = const Duration(milliseconds: 400),
    this.autoDismissOnEnter = true,
  }) : _programCandidates = _buildProgramCandidates(program, fallbackPrograms) {
    FocusManager.instance.addListener(_handleFocusChange);
    RawKeyboard.instance.addListener(_handleRawKey);
    _handleFocusChange();
  }

  final List<String> _programCandidates;
  final Duration hideDelay;
  final bool autoDismissOnEnter;

  Process? _process;
  Timer? _hideTimer;
  bool _isLaunching = false;
  String? _activeProgram;
  final Set<String> _failedCandidates = <String>{};
  bool _reportedExhausted = false;

  void dispose() {
    FocusManager.instance.removeListener(_handleFocusChange);
    RawKeyboard.instance.removeListener(_handleRawKey);
    _hideTimer?.cancel();
    _hideTimer = null;
    _stopKeyboard();
  }

  void _handleFocusChange() {
    final focus = FocusManager.instance.primaryFocus;
    final hasEditableFocus = _hasEditableTextFocus(focus);
    if (hasEditableFocus) {
      _hideTimer?.cancel();
      _hideTimer = null;
      _showKeyboard();
    } else {
      _hideTimer?.cancel();
      if (_process != null) {
        _hideTimer = Timer(hideDelay, _stopKeyboard);
      }
    }
  }

  bool _hasEditableTextFocus(FocusNode? focus) {
    if (focus == null) {
      return false;
    }
    final context = focus.context;
    if (context == null) {
      return false;
    }
    if (context.widget is EditableText) {
      return true;
    }
    var found = false;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  Future<void> _showKeyboard() async {
    if (_process != null) {
      return;
    }
    if (_isLaunching) {
      return;
    }
    if (kIsWeb) {
      return;
    }
    if (!Platform.isLinux) {
      return;
    }
    _isLaunching = true;
    try {
      for (final candidate in _programCandidates) {
        try {
          final process = await Process.start(candidate, const []);
          _process = process;
          _activeProgram = candidate;
          _failedCandidates.remove(candidate);
          _reportedExhausted = false;
          unawaited(process.exitCode.then((_) {
            if (identical(_process, process)) {
              _process = null;
              _activeProgram = null;
            }
          }));
          return;
        } catch (error, stackTrace) {
          final firstFailure = _failedCandidates.add(candidate);
          if (firstFailure) {
            debugPrint('Failed to launch $candidate: $error');
            debugPrint('$stackTrace');
          }
        }
      }
      if (!_reportedExhausted) {
        _reportedExhausted = true;
        debugPrint(
            'No on-screen keyboard candidates available: $_programCandidates');
      }
    } finally {
      _isLaunching = false;
    }
  }

  void _stopKeyboard() {
    final process = _process;
    final activeProgram = _activeProgram;
    _process = null;
    _activeProgram = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    if (process == null) {
      return;
    }
    try {
      if (!process.kill(ProcessSignal.sigterm)) {
        process.kill();
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to stop ${activeProgram ?? 'keyboard'}: $error');
      debugPrint('$stackTrace');
    }
  }

  void hideKeyboard({bool releaseFocus = false}) {
    if (_process == null) {
      return;
    }
    _stopKeyboard();
    if (releaseFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void _handleRawKey(RawKeyEvent event) {
    if (!autoDismissOnEnter) {
      return;
    }
    if (_process == null) {
      return;
    }
    if (event is! RawKeyDownEvent) {
      return;
    }
    final logicalKey = event.logicalKey;
    if (logicalKey != LogicalKeyboardKey.enter &&
        logicalKey != LogicalKeyboardKey.numpadEnter) {
      return;
    }
    if (event.isShiftPressed ||
        event.isAltPressed ||
        event.isControlPressed ||
        event.isMetaPressed) {
      return;
    }
    hideKeyboard(releaseFocus: true);
  }

  static List<String> _buildProgramCandidates(
      String? program, List<String>? fallbackPrograms) {
    final candidates = <String>{
      if (program != null) program,
      ...(fallbackPrograms ??
          const ['onboard', 'matchbox-keyboard', 'florence']),
    };
    return candidates.toList(growable: false);
  }
}
