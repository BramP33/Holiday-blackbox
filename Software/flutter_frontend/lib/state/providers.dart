import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backup_status.dart';
import '../models/media_item.dart';
import '../models/media_location.dart';
import '../models/trip_stats.dart';
import '../models/trash_entry.dart';
import '../services/api_client.dart';
import '../services/on_screen_keyboard.dart';
import 'app_environment.dart';

final navigationIndexProvider = StateProvider<int>((ref) => 0);

final apiClientProvider = Provider<ApiClient>((ref) {
  final env = ref.watch(appEnvironmentProvider);
  final client = ApiClient(baseUri: env.baseUri);
  ref.onDispose(client.close);
  return client;
});

final tripStatsProvider = FutureProvider.autoDispose<TripStats>((ref) async {
  final api = ref.watch(apiClientProvider);
  final stats = await api.fetchTripStats();
  return stats;
});

final photosProvider = FutureProvider.autoDispose
    .family<MediaPage<PhotoItem>, int>((ref, page) async {
  final api = ref.watch(apiClientProvider);
  final result = await api.fetchPhotos(page: page);
  return result;
});

@immutable
class VideoRequest {
  const VideoRequest({required this.page, this.query});

  final int page;
  final String? query;

  VideoRequest copyWith({int? page, String? query}) {
    return VideoRequest(page: page ?? this.page, query: query ?? this.query);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoRequest && other.page == page && other.query == query;
  }

  @override
  int get hashCode => Object.hash(page, query);
}

final videosProvider = FutureProvider.autoDispose
    .family<MediaPage<VideoRecord>, VideoRequest>((ref, request) async {
  final api = ref.watch(apiClientProvider);
  final result =
      await api.fetchVideos(page: request.page, query: request.query);
  return result;
});

final trashEntriesProvider =
    FutureProvider.autoDispose<List<TrashEntry>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return api.fetchTrashEntries();
});

final backupStatusProvider =
    FutureProvider.autoDispose<BackupStatus>((ref) async {
  final api = ref.watch(apiClientProvider);
  final json = await api.fetchBackupStatus();
  return BackupStatus.fromJson(json);
});

final configProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final cfg = await api.fetchConfig();
  return cfg;
});

final localeProvider = StateNotifierProvider<LocaleController, Locale>((ref) {
  final controller = LocaleController();

  ref.listen<AsyncValue<Map<String, dynamic>>>(
    configProvider,
    (previous, next) {
      next.whenData((cfg) {
        controller.setLocale(localeFromConfig(cfg['language']?.toString()));
      });
    },
    fireImmediately: true,
  );

  return controller;
});

final onScreenKeyboardControllerProvider =
    Provider<OnScreenKeyboardController>((ref) {
  final controller = OnScreenKeyboardController();
  ref.onDispose(controller.dispose);
  return controller;
});

final lastMediaLocationProvider = FutureProvider<MediaLocation?>((ref) async {
  final api = ref.watch(apiClientProvider);
  final result = await api.fetchLastMediaLocation();
  return result;
});

class LocaleController extends StateNotifier<Locale> {
  LocaleController() : super(const Locale('en'));

  void setLocale(Locale locale) {
    if (state != locale) {
      state = locale;
    }
  }
}

Locale localeFromConfig(String? code) {
  final fallback = const Locale('en');
  if (code == null || code.trim().isEmpty) return fallback;
  final normalized = code.trim();
  final parts = normalized.split(RegExp(r'[-_]'));
  if (parts.length == 1) {
    return Locale(parts.first);
  }
  return Locale(parts[0], parts[1]);
}
