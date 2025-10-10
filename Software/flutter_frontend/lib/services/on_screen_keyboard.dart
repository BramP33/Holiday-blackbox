import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

const double _keyboardHeight = 280;
const Duration _defaultHideDelay = Duration(milliseconds: 200);

bool _defaultPlatformPredicate() {
  if (kIsWeb) {
    return false;
  }
  return Platform.isLinux;
}

class OnScreenKeyboardController {
  OnScreenKeyboardController({
    bool Function()? platformPredicate,
    this.hideDelay = _defaultHideDelay,
    this.autoDismissOnEnter = true,
  }) : platformPredicate = platformPredicate ?? _defaultPlatformPredicate {
    FocusManager.instance.addListener(_handleFocusChange);
    RawKeyboard.instance.addListener(_handleRawKey);
    _handleFocusChange();
  }

  final bool Function() platformPredicate;
  final Duration hideDelay;
  final bool autoDismissOnEnter;

  final ValueNotifier<bool> isVisible = ValueNotifier<bool>(false);
  final ValueNotifier<_KeyboardModifiers> modifiers =
      ValueNotifier<_KeyboardModifiers>(const _KeyboardModifiers());

  EditableTextState? _currentEditable;
  Timer? _hideTimer;
  int? _lastCaretPosition;

  void dispose() {
    FocusManager.instance.removeListener(_handleFocusChange);
    RawKeyboard.instance.removeListener(_handleRawKey);
    _hideTimer?.cancel();
    _currentEditable = null;
  }

  void _handleFocusChange() {
    if (!platformPredicate()) {
      _hideImmediately();
      return;
    }

    final focus = FocusManager.instance.primaryFocus;
    final EditableTextState? editable = _resolveEditableFromFocus(focus);
    if (editable != null && editable.mounted) {
      _currentEditable = editable;
      _hideTimer?.cancel();
      _hideTimer = null;
      final TextEditingValue value = editable.textEditingValue;
      final TextSelection selection = value.selection;
      if (selection.isValid) {
        _lastCaretPosition = selection.extentOffset;
      } else {
        _lastCaretPosition = value.text.length;
      }
      _ensureEditableFocus();
      if (!isVisible.value) {
        isVisible.value = true;
      }
      return;
    }

    _scheduleHide();
  }

  EditableTextState? _resolveEditableFromFocus(FocusNode? focus) {
    if (focus == null) return null;
    final BuildContext? context = focus.context;
    if (context == null) return null;

    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }

    return context.findAncestorStateOfType<EditableTextState>();
  }

  bool _ensureEditableFocus() {
    final EditableTextState? editable = _currentEditable;
    if (editable == null || !editable.mounted) {
      return false;
    }
    final FocusNode focusNode = editable.widget.focusNode;
    final bool hadPrimaryFocus = focusNode.hasPrimaryFocus;
    if (!hadPrimaryFocus && focusNode.canRequestFocus) {
      focusNode.requestFocus();
      _scheduleSelectionRestore(editable);
    }
    return focusNode.hasFocus || focusNode.hasPrimaryFocus;
  }

  void _scheduleSelectionRestore(EditableTextState editable) {
    scheduleMicrotask(() {
      if (!editable.mounted) {
        return;
      }
      final int? caret = _lastCaretPosition;
      if (caret == null) {
        return;
      }
      final TextEditingValue value = editable.textEditingValue;
      final TextSelection selection = value.selection;
      final bool isSelectAll = selection.baseOffset == 0 &&
          selection.extentOffset == value.text.length &&
          !selection.isCollapsed;
      if (!isSelectAll) {
        return;
      }
      final int clampedCaret = caret.clamp(0, value.text.length) as int;
      final TextSelection collapsed =
          TextSelection.collapsed(offset: clampedCaret);
      if (collapsed == selection) {
        return;
      }
      editable.updateEditingValue(
        value.copyWith(selection: collapsed, composing: TextRange.empty),
      );
    });
  }

  void _scheduleHide() {
    if (!isVisible.value) {
      _currentEditable = null;
      return;
    }
    _hideTimer?.cancel();
    if (hideDelay == Duration.zero) {
      _hideImmediately();
    } else {
      _hideTimer = Timer(hideDelay, _hideImmediately);
    }
  }

  void _hideImmediately() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (isVisible.value) {
      isVisible.value = false;
    }
    _currentEditable = null;
    _lastCaretPosition = null;
    if (modifiers.value != const _KeyboardModifiers()) {
      modifiers.value = const _KeyboardModifiers();
    }
  }

  void hideKeyboard({bool releaseFocus = false}) {
    _hideImmediately();
    if (releaseFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void insertCharacter(_KeyboardKeySpec spec) {
    final EditableTextState? editable = _currentEditable;
    if (editable == null || !editable.mounted) {
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = null;
    _ensureEditableFocus();
    final String textToInsert = spec.resolveOutput(modifiers.value);
    if (textToInsert.isEmpty) {
      return;
    }
    _commitText(editable, textToInsert);
  }

  void insertSpace() {
    final EditableTextState? editable = _currentEditable;
    if (editable == null || !editable.mounted) {
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = null;
    _ensureEditableFocus();
    _commitText(editable, ' ');
  }

  void _commitText(EditableTextState editable, String text) {
    final TextEditingValue currentValue = editable.textEditingValue;
    final TextSelection selection = currentValue.selection;
    final int start = selection.isValid
        ? selection.start
        : currentValue.text.length;
    final int end = selection.isValid ? selection.end : currentValue.text.length;

    final String newText =
        currentValue.text.replaceRange(start, end, text);
    final TextSelection newSelection =
        TextSelection.collapsed(offset: start + text.length);

    editable.updateEditingValue(
      currentValue.copyWith(
        text: newText,
        selection: newSelection,
        composing: TextRange.empty,
      ),
    );
    _lastCaretPosition = newSelection.extentOffset;

    _applyPostInputModifiers();
  }

  void backspace() {
    debugPrint('Backspace called');
    final EditableTextState? editable = _currentEditable;
    if (editable == null || !editable.mounted) {
      debugPrint('Backspace: No editable or not mounted');
      return;
    }

    debugPrint('Backspace: Processing...');
    _hideTimer?.cancel();
    _hideTimer = null;
    _ensureEditableFocus();

    final TextEditingValue currentValue = editable.textEditingValue;
    final TextSelection selection = currentValue.selection;
    debugPrint('Backspace: Current text: "${currentValue.text}", selection: ${selection.start}-${selection.end}');

    if (!selection.isValid) {
      debugPrint('Backspace: Invalid selection, removing last char');
      if (currentValue.text.isEmpty) {
        debugPrint('Backspace: Text is empty, nothing to do');
        return;
      }
      final String newText =
          currentValue.text.substring(0, currentValue.text.length - 1);
      final TextSelection newSelection =
          TextSelection.collapsed(offset: newText.length);
      editable.updateEditingValue(
        currentValue.copyWith(
          text: newText,
          selection: newSelection,
          composing: TextRange.empty,
        ),
      );
      _lastCaretPosition = newSelection.extentOffset;
      _applyPostInputModifiers();
      return;
    }

    if (!selection.isCollapsed) {
      final String newText =
          currentValue.text.replaceRange(selection.start, selection.end, '');
      final TextSelection newSelection =
          TextSelection.collapsed(offset: selection.start);
      editable.updateEditingValue(
        currentValue.copyWith(
          text: newText,
          selection: newSelection,
          composing: TextRange.empty,
        ),
      );
      _lastCaretPosition = newSelection.extentOffset;
      _applyPostInputModifiers();
      return;
    }

    if (selection.start == 0) {
      return;
    }

    final int previousIndex = selection.start - 1;
    final String newText =
        currentValue.text.replaceRange(previousIndex, selection.start, '');
    final TextSelection newSelection =
        TextSelection.collapsed(offset: previousIndex);
    editable.updateEditingValue(
      currentValue.copyWith(
        text: newText,
        selection: newSelection,
        composing: TextRange.empty,
      ),
    );
    _lastCaretPosition = newSelection.extentOffset;
    _applyPostInputModifiers();
  }

  void pressEnter() {
    final EditableTextState? editable = _currentEditable;
    if (editable == null || !editable.mounted) {
      hideKeyboard(releaseFocus: true);
      return;
    }

    _hideTimer?.cancel();
    _hideTimer = null;
    _ensureEditableFocus();

    final EditableText widget = editable.widget;
    final TextEditingValue currentValue = editable.textEditingValue;
    final bool singleLine = (widget.maxLines ?? 1) == 1 ||
        widget.textInputAction == TextInputAction.done ||
        widget.textInputAction == TextInputAction.go ||
        widget.textInputAction == TextInputAction.send;

    if (singleLine) {
      widget.onEditingComplete?.call();
      widget.onSubmitted?.call(currentValue.text);
      hideKeyboard(releaseFocus: true);
      return;
    }

    _commitText(editable, '\n');
  }

  void toggleShift() {
    final _KeyboardModifiers current = modifiers.value;
    modifiers.value = current.copyWith(isShifted: !current.isShifted);
  }

  void toggleCapsLock() {
    final _KeyboardModifiers current = modifiers.value;
    modifiers.value = current.copyWith(
      isCapsLocked: !current.isCapsLocked,
      isShifted: false,
    );
  }

  void _applyPostInputModifiers() {
    final _KeyboardModifiers current = modifiers.value;
    if (current.isShifted && !current.isCapsLocked) {
      modifiers.value = current.copyWith(isShifted: false);
    }
  }

  void _handleRawKey(RawKeyEvent event) {
    if (!autoDismissOnEnter) {
      return;
    }
    if (!isVisible.value) {
      return;
    }
    if (event is! RawKeyDownEvent) {
      return;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
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
}

@immutable
class _KeyboardModifiers {
  const _KeyboardModifiers({
    this.isShifted = false,
    this.isCapsLocked = false,
  });

  final bool isShifted;
  final bool isCapsLocked;

  bool get shouldUseShift => isShifted || isCapsLocked;

  _KeyboardModifiers copyWith({
    bool? isShifted,
    bool? isCapsLocked,
  }) {
    return _KeyboardModifiers(
      isShifted: isShifted ?? this.isShifted,
      isCapsLocked: isCapsLocked ?? this.isCapsLocked,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _KeyboardModifiers &&
        other.isShifted == isShifted &&
        other.isCapsLocked == isCapsLocked;
  }

  @override
  int get hashCode => Object.hash(isShifted, isCapsLocked);
}

enum _KeyboardKeyType {
  character,
  backspace,
  shift,
  capsLock,
  space,
  enter,
  hide,
}

class _KeyboardKeySpec {
  const _KeyboardKeySpec._({
    required this.type,
    this.primary,
    this.shift,
    this.label,
    this.icon,
    required this.flex,
  });

  const _KeyboardKeySpec.character({
    required String primary,
    String? shift,
    int flex = 10,
  }) : this._(
          type: _KeyboardKeyType.character,
          primary: primary,
          shift: shift,
          flex: flex,
        );

  const _KeyboardKeySpec.backspace({int flex = 18})
      : this._(
          type: _KeyboardKeyType.backspace,
          icon: Icons.backspace_outlined,
          flex: flex,
        );

  const _KeyboardKeySpec.shift({int flex = 18})
      : this._(
          type: _KeyboardKeyType.shift,
          icon: Icons.keyboard_double_arrow_up,
          label: 'Shift',
          flex: flex,
        );

  const _KeyboardKeySpec.capsLock({int flex = 18})
      : this._(
          type: _KeyboardKeyType.capsLock,
          icon: Icons.keyboard_capslock,
          label: 'Caps',
          flex: flex,
        );

  const _KeyboardKeySpec.enter({int flex = 22})
      : this._(
          type: _KeyboardKeyType.enter,
          icon: Icons.keyboard_return,
          label: 'Enter',
          flex: flex,
        );

  const _KeyboardKeySpec.space({int flex = 60})
      : this._(
          type: _KeyboardKeyType.space,
          icon: Icons.space_bar,
          label: 'Space',
          flex: flex,
        );

  const _KeyboardKeySpec.hide({int flex = 18})
      : this._(
          type: _KeyboardKeyType.hide,
          icon: Icons.keyboard_hide,
          label: 'Hide',
          flex: flex,
        );

  final _KeyboardKeyType type;
  final String? primary;
  final String? shift;
  final String? label;
  final IconData? icon;
  final int flex;

  String displayLabel(_KeyboardModifiers modifiers) {
    switch (type) {
      case _KeyboardKeyType.character:
        final String? base = primary;
        if (base == null) {
          return '';
        }
        if (!modifiers.shouldUseShift) {
          return base;
        }
        if (shift != null && !_isAlphabetic(base)) {
          return shift!;
        }
        if (_isAlphabetic(base)) {
          return base.toUpperCase();
        }
        return base;
      case _KeyboardKeyType.space:
        return label ?? 'Space';
      default:
        return label ?? '';
    }
  }

  String resolveOutput(_KeyboardModifiers modifiers) {
    if (type != _KeyboardKeyType.character || primary == null) {
      return '';
    }
    if (!modifiers.shouldUseShift) {
      return primary!;
    }
    if (shift != null) {
      return shift!;
    }
    if (_isAlphabetic(primary!)) {
      return primary!.toUpperCase();
    }
    return primary!;
  }

  bool _isAlphabetic(String value) {
    if (value.isEmpty) return false;
    final String lower = value.toLowerCase();
    final String upper = value.toUpperCase();
    return lower != upper;
  }
}

const List<List<_KeyboardKeySpec>> _keyboardRows = [
  [
    _KeyboardKeySpec.character(primary: '`', shift: '~'),
    _KeyboardKeySpec.character(primary: '1', shift: '!'),
    _KeyboardKeySpec.character(primary: '2', shift: '@'),
    _KeyboardKeySpec.character(primary: '3', shift: '#'),
    _KeyboardKeySpec.character(primary: '4', shift: r'$'),
    _KeyboardKeySpec.character(primary: '5', shift: '%'),
    _KeyboardKeySpec.character(primary: '6', shift: '^'),
    _KeyboardKeySpec.character(primary: '7', shift: '&'),
    _KeyboardKeySpec.character(primary: '8', shift: '*'),
    _KeyboardKeySpec.character(primary: '9', shift: '('),
    _KeyboardKeySpec.character(primary: '0', shift: ')'),
    _KeyboardKeySpec.character(primary: '-', shift: '_'),
    _KeyboardKeySpec.character(primary: '=', shift: '+'),
    _KeyboardKeySpec.backspace(),
  ],
  [
    _KeyboardKeySpec.character(primary: 'q'),
    _KeyboardKeySpec.character(primary: 'w'),
    _KeyboardKeySpec.character(primary: 'e'),
    _KeyboardKeySpec.character(primary: 'r'),
    _KeyboardKeySpec.character(primary: 't'),
    _KeyboardKeySpec.character(primary: 'y'),
    _KeyboardKeySpec.character(primary: 'u'),
    _KeyboardKeySpec.character(primary: 'i'),
    _KeyboardKeySpec.character(primary: 'o'),
    _KeyboardKeySpec.character(primary: 'p'),
    _KeyboardKeySpec.character(primary: '[', shift: '{'),
    _KeyboardKeySpec.character(primary: ']', shift: '}'),
    _KeyboardKeySpec.character(primary: r'\', shift: '|', flex: 14),
  ],
  [
    _KeyboardKeySpec.capsLock(),
    _KeyboardKeySpec.character(primary: 'a'),
    _KeyboardKeySpec.character(primary: 's'),
    _KeyboardKeySpec.character(primary: 'd'),
    _KeyboardKeySpec.character(primary: 'f'),
    _KeyboardKeySpec.character(primary: 'g'),
    _KeyboardKeySpec.character(primary: 'h'),
    _KeyboardKeySpec.character(primary: 'j'),
    _KeyboardKeySpec.character(primary: 'k'),
    _KeyboardKeySpec.character(primary: 'l'),
    _KeyboardKeySpec.character(primary: ';', shift: ':'),
    _KeyboardKeySpec.character(primary: "'", shift: '"'),
    _KeyboardKeySpec.enter(),
  ],
  [
    _KeyboardKeySpec.shift(),
    _KeyboardKeySpec.character(primary: 'z'),
    _KeyboardKeySpec.character(primary: 'x'),
    _KeyboardKeySpec.character(primary: 'c'),
    _KeyboardKeySpec.character(primary: 'v'),
    _KeyboardKeySpec.character(primary: 'b'),
    _KeyboardKeySpec.character(primary: 'n'),
    _KeyboardKeySpec.character(primary: 'm'),
    _KeyboardKeySpec.character(primary: ',', shift: '<'),
    _KeyboardKeySpec.character(primary: '.', shift: '>'),
    _KeyboardKeySpec.character(primary: '/', shift: '?'),
    _KeyboardKeySpec.shift(),
  ],
  [
    _KeyboardKeySpec.hide(),
    _KeyboardKeySpec.space(),
  ],
];

class OnScreenKeyboardOverlay extends StatelessWidget {
  const OnScreenKeyboardOverlay({
    super.key,
    required this.controller,
    required this.child,
  });

  final OnScreenKeyboardController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.isVisible,
      child: child,
      builder: (context, visible, child) {
        final double bottomPadding = MediaQuery.of(context).padding.bottom;
        final double keyboardInset = visible ? _keyboardHeight + bottomPadding : 0;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: visible ? Curves.easeOut : Curves.easeIn,
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: child,
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _OnScreenKeyboardView(
                controller: controller,
                visible: visible,
                bottomPadding: bottomPadding,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OnScreenKeyboardView extends StatelessWidget {
  const _OnScreenKeyboardView({
    required this.controller,
    required this.visible,
    required this.bottomPadding,
  });

  final OnScreenKeyboardController controller;
  final bool visible;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        offset: Offset(0, visible ? 0 : 1),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1 : 0,
          child: SizedBox(
            height: _keyboardHeight + bottomPadding,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.charcoalSoft.withOpacity(0.96),
                border: const Border(
                  top: BorderSide(color: AppColors.sage, width: 1.2),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    offset: const Offset(0, -6),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, bottomPadding + 16),
                child: ValueListenableBuilder<_KeyboardModifiers>(
                  valueListenable: controller.modifiers,
                  builder: (context, modifiers, _) {
                    return FocusScope(
                      canRequestFocus: false,
                      child: _KeyboardLayout(
                        controller: controller,
                        modifiers: modifiers,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyboardLayout extends StatelessWidget {
  const _KeyboardLayout({
    required this.controller,
    required this.modifiers,
  });

  final OnScreenKeyboardController controller;
  final _KeyboardModifiers modifiers;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < _keyboardRows.length; i++) {
      rows.add(
        _KeyboardRow(
          specs: _keyboardRows[i],
          controller: controller,
          modifiers: modifiers,
        ),
      );
      if (i != _keyboardRows.length - 1) {
        rows.add(const SizedBox(height: 8));
      }
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: rows,
    );
  }
}

class _KeyboardRow extends StatelessWidget {
  const _KeyboardRow({
    required this.specs,
    required this.controller,
    required this.modifiers,
  });

  final List<_KeyboardKeySpec> specs;
  final OnScreenKeyboardController controller;
  final _KeyboardModifiers modifiers;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          for (final _KeyboardKeySpec spec in specs)
            Expanded(
              flex: spec.flex,
              child: _KeyboardButton(
                spec: spec,
                controller: controller,
                modifiers: modifiers,
              ),
            ),
        ],
      ),
    );
  }
}

class _KeyboardButton extends StatelessWidget {
  const _KeyboardButton({
    required this.spec,
    required this.controller,
    required this.modifiers,
  });

  final _KeyboardKeySpec spec;
  final OnScreenKeyboardController controller;
  final _KeyboardModifiers modifiers;

  bool get _isActive {
    if (spec.type == _KeyboardKeyType.shift) {
      return modifiers.isShifted;
    }
    if (spec.type == _KeyboardKeyType.capsLock) {
      return modifiers.isCapsLocked;
    }
    return false;
  }

  void _onTap() {
    switch (spec.type) {
      case _KeyboardKeyType.character:
        controller.insertCharacter(spec);
        break;
      case _KeyboardKeyType.backspace:
        controller.backspace();
        break;
      case _KeyboardKeyType.shift:
        controller.toggleShift();
        break;
      case _KeyboardKeyType.capsLock:
        controller.toggleCapsLock();
        break;
      case _KeyboardKeyType.space:
        controller.insertSpace();
        break;
      case _KeyboardKeyType.enter:
        controller.pressEnter();
        break;
      case _KeyboardKeyType.hide:
        controller.hideKeyboard(releaseFocus: true);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isActive = _isActive;
    final Color backgroundColor = isActive
        ? AppColors.forest.withOpacity(0.92)
        : AppColors.charcoalAlt.withOpacity(0.94);
    final Color borderColor = isActive
        ? AppColors.amber.withOpacity(0.7)
        : AppColors.sage.withOpacity(0.35);
    final Color foregroundColor = isActive ? AppColors.amber : AppColors.kraft;

    final TextStyle characterStyle = (theme.textTheme.headlineSmall ??
            const TextStyle(fontSize: 24, fontWeight: FontWeight.w600))
        .copyWith(color: foregroundColor, letterSpacing: 0.4);
    final TextStyle labelStyle = (theme.textTheme.titleMedium ??
            const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))
        .copyWith(color: foregroundColor, letterSpacing: 0.4);

    final String label = spec.displayLabel(modifiers);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(8),
            splashColor: AppColors.amber.withOpacity(0.12),
            highlightColor: AppColors.amber.withOpacity(0.08),
            onTap: _onTap,
            child: Center(
              child: _KeyLabel(
                spec: spec,
                label: label,
                characterStyle: characterStyle,
                labelStyle: labelStyle,
                foregroundColor: foregroundColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyLabel extends StatelessWidget {
  const _KeyLabel({
    required this.spec,
    required this.label,
    required this.characterStyle,
    required this.labelStyle,
    required this.foregroundColor,
  });

  final _KeyboardKeySpec spec;
  final String label;
  final TextStyle characterStyle;
  final TextStyle labelStyle;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final bool hasIcon = spec.icon != null;
    final bool showLabel = label.isNotEmpty;

    if (spec.type == _KeyboardKeyType.character) {
      return Text(label, style: characterStyle, textAlign: TextAlign.center);
    }

    if (hasIcon && showLabel) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(spec.icon, color: foregroundColor),
          const SizedBox(width: 6),
          Text(label, style: labelStyle, textAlign: TextAlign.center),
        ],
      );
    }

    if (hasIcon) {
      return Icon(spec.icon, color: foregroundColor);
    }

    return Text(label, style: labelStyle, textAlign: TextAlign.center);
  }
}
