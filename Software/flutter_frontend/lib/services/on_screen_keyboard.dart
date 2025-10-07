import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class OnScreenKeyboardController {
  OnScreenKeyboardController({this.program = 'onboard', this.hideDelay = const Duration(milliseconds: 400)}) {
    FocusManager.instance.addListener(_handleFocusChange);
  }

  final String program;
  final Duration hideDelay;

  Process? _process;
  Timer? _hideTimer;

  void dispose() {
    FocusManager.instance.removeListener(_handleFocusChange);
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
    try {
      final process = await Process.start(program, const []);
      _process = process;
      unawaited(process.exitCode.then((_) {
        if (identical(_process, process)) {
          _process = null;
        }
      }));
    } catch (error, stackTrace) {
      debugPrint('Failed to launch $program: $error');
      debugPrint('$stackTrace');
      _process = null;
    }
  }

  void _stopKeyboard() {
    final process = _process;
    _process = null;
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
      debugPrint('Failed to stop $program: $error');
      debugPrint('$stackTrace');
    }
  }
}
