import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppEnvironment {
  AppEnvironment({required this.baseUri, required this.webSocketUri});

  final Uri baseUri;
  final Uri webSocketUri;

  factory AppEnvironment.detect() {
    final baseUrl = const String.fromEnvironment(
      'BLACKBOX_BASE_URL',
      defaultValue: 'http://127.0.0.1:5000',
    );
    final wsUrl = const String.fromEnvironment(
      'BLACKBOX_WS_URL',
      defaultValue: 'ws://127.0.0.1:5000/ws/status',
    );

    // Allow overriding through platform environment when running in debug/profile.
    if (!kReleaseMode) {
      final envBase = Platform.environment['BLACKBOX_BASE_URL'];
      final envWs = Platform.environment['BLACKBOX_WS_URL'];
      return AppEnvironment(
        baseUri: Uri.parse(envBase?.isNotEmpty == true ? envBase! : baseUrl),
        webSocketUri: Uri.parse(envWs?.isNotEmpty == true ? envWs! : wsUrl),
      );
    }

    return AppEnvironment(
      baseUri: Uri.parse(baseUrl),
      webSocketUri: Uri.parse(wsUrl),
    );
  }
}

final appEnvironmentProvider = Provider<AppEnvironment>((ref) {
  return AppEnvironment.detect();
});
