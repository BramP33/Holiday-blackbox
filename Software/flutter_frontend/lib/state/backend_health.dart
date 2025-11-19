import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';

/// Provider that waits for the backend to be healthy and ready
/// This ensures the frontend doesn't start until the backend is accessible
final backendHealthProvider = FutureProvider<bool>((ref) async {
  final api = ref.watch(apiClientProvider);
  const maxRetries = 30; // ~30 seconds with 1s intervals
  const retryDelay = Duration(seconds: 1);

  for (int i = 0; i < maxRetries; i++) {
    try {
      // Try to fetch the backup status as a simple health check
      await api.fetchBackupStatus();
      return true; // Backend is healthy
    } catch (e) {
      if (i < maxRetries - 1) {
        await Future.delayed(retryDelay);
      }
    }
  }

  // If we get here, backend is not responding
  throw Exception('Backend is not responding after $maxRetries attempts');
});

/// Import this where needed:
/// ```dart
/// import 'state/backend_health.dart';
/// ```
