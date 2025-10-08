import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../models/media_location.dart';
import '../models/trip_stats.dart';
import '../models/trash_entry.dart';

class ApiClient {
  ApiClient({required this.baseUri, http.Client? client})
      : _client = client ?? http.Client();

  final Uri baseUri;
  final http.Client _client;

  @visibleForTesting
  http.Client get rawClient => _client;

  Uri _resolve(String path, [Map<String, dynamic>? query]) {
    return baseUri.replace(path: path, queryParameters: query);
  }

  Future<TripStats> fetchTripStats() async {
    final uri = _resolve('/api/stats');
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to load stats (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    return TripStats.fromJson(jsonMap);
  }

  Future<MediaPage<PhotoItem>> fetchPhotos({int page = 1}) async {
    final uri = _resolve('/api/photos', {
      'page': page.toString(),
    });
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to load photos (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    final items = (jsonMap['items'] as List<dynamic>? ?? [])
        .map((entry) => PhotoItem(path: entry.toString()))
        .toList(growable: false);
    return MediaPage<PhotoItem>(
      items: items,
      page: jsonMap['page'] as int? ?? page,
      pageSize: jsonMap['page_size'] as int? ?? items.length,
      total: jsonMap['total'] as int? ?? items.length,
    );
  }

  Future<MediaPage<VideoRecord>> fetchVideos({
    int page = 1,
    String? query,
  }) async {
    final uri = _resolve('/api/videos', {
      'page': page.toString(),
      if (query != null && query.isNotEmpty) 'q': query,
    });
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to load videos (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    final records = (jsonMap['records'] as List<dynamic>? ?? [])
        .map((entry) => VideoRecord.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
    return MediaPage<VideoRecord>(
      items: records,
      page: jsonMap['page'] as int? ?? page,
      pageSize: jsonMap['page_size'] as int? ?? records.length,
      total: jsonMap['total'] as int? ?? records.length,
    );
  }

  Future<String?> fetchVideoTranscript(String path) async {
    final uri = _resolve('/transcript', {'p': path});
    final response = await _client.get(uri);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw ApiException('Failed to load transcript (${response.statusCode})');
    }
    return response.body;
  }

  Future<List<TrashEntry>> fetchTrashEntries() async {
    final uri = _resolve('/api/trash');
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to load trash (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    final entries = (jsonMap['entries'] as List<dynamic>? ?? [])
        .map((entry) => TrashEntry.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
    return entries;
  }

  Future<void> restoreTrashEntry(String id) async {
    final uri = _resolve('/api/trash/restore');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'id': id}),
    );
    if (response.statusCode != 200) {
      throw ApiException('Failed to restore trash (${response.statusCode})');
    }
  }

  Future<void> purgeTrashEntry(String id) async {
    final uri = _resolve('/api/trash/purge');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'id': id}),
    );
    if (response.statusCode != 200) {
      throw ApiException('Failed to delete trash (${response.statusCode})');
    }
  }

  Future<void> deleteMedia(String path) async {
    final uri = _resolve('/delete');
    final response = await _client.post(uri, body: {'p': path});
    if (response.statusCode != 302 && response.statusCode != 200) {
      throw ApiException('Failed to delete media (${response.statusCode})');
    }
  }

  Future<void> startBackup() async {
    final uri = _resolve('/api/backup/start');
    final response = await _client.post(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to start backup (${response.statusCode})');
    }
  }

  Future<Map<String, dynamic>> fetchBackupStatus() async {
    final uri = _resolve('/api/backup/status');
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to fetch backup status (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    return jsonMap;
  }

  Future<void> cancelBackup() async {
    final uri = _resolve('/api/backup/cancel');
    final response = await _client.post(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to cancel backup (${response.statusCode})');
    }
  }

  Future<Map<String, dynamic>> startTranscription() async {
    final uri = _resolve('/api/transcription/start');
    final response = await _client.post(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to start transcription (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    return jsonMap;
  }

  Future<Map<String, dynamic>> fetchConfig() async {
    final uri = _resolve('/api/config');
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('Failed to load config (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    return jsonMap;
  }

  Future<Map<String, dynamic>> updateConfig(Map<String, dynamic> config) async {
    final uri = _resolve('/api/config');
    final response = await _client.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(config),
    );
    if (response.statusCode != 200) {
      throw ApiException('Failed to save config (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    return jsonMap;
  }

  Future<MediaLocation?> fetchLastMediaLocation() async {
    final uri = _resolve('/api/media/last-location');
    final response = await _client.get(uri);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw ApiException('Failed to load last media location (${response.statusCode})');
    }
    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    if (!jsonMap.containsKey('latitude') || !jsonMap.containsKey('longitude')) {
      return null;
    }
    return MediaLocation.fromJson(jsonMap);
  }

  void close() {
    _client.close();
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => 'ApiException: $message';
}
