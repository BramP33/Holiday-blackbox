import 'dart:async';

/// Minimal no-op replacement for the wakelock_plus API.
///
/// The Flutter touchscreen app does not require fullscreen wakelock behaviour
/// on the Raspberry Pi, so we keep the same public methods but make them
/// synchronous no-ops to avoid pulling the upstream plugin (which depends on
/// the Windows win32 bindings not available on arm64 Linux).
class WakelockPlus {
  static Future<void> enable() async {}
  static Future<void> disable() async {}
  static Future<void> toggle({required bool enable}) async {}
  static Future<bool> get enabled async => false;
}
