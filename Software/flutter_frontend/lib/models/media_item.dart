enum MediaType { photo, video }

class PhotoItem {
  const PhotoItem({required this.path});

  final String path;

  Uri buildPreviewUri(Uri base) {
    return base.replace(
      path: '/preview/photo',
      queryParameters: {'p': path},
    );
  }

  Uri buildDownloadUri(Uri base) {
    return base.replace(
      path: '/download',
      queryParameters: {'p': path},
    );
  }
}

class VideoRecord {
  const VideoRecord({
    required this.path,
    required this.filename,
    required this.folder,
    required this.capturedAtDisplay,
    required this.locationLabel,
    required this.countryCode,
    required this.durationSeconds,
    required this.hasGps,
    required this.transcriptAvailable,
    required this.transcriptState,
    this.sizeBytes,
    this.sizeDisplay,
  });

  final String path;
  final String? filename;
  final String? folder;
  final String? capturedAtDisplay;
  final String? locationLabel;
  final String? countryCode;
  final double? durationSeconds;
  final bool hasGps;
  final bool transcriptAvailable;
  final String? transcriptState;
  final int? sizeBytes;
  final String? sizeDisplay;

  Duration? get duration {
    final value = durationSeconds;
    if (value == null) {
      return null;
    }
    return Duration(milliseconds: (value * 1000).round());
  }

  factory VideoRecord.fromJson(Map<String, dynamic> json) {
    return VideoRecord(
      path: json['path']?.toString() ?? '',
      filename: json['filename']?.toString(),
      folder: json['folder']?.toString(),
      capturedAtDisplay: json['captured_at_display']?.toString(),
      locationLabel: json['location_label']?.toString(),
      countryCode: json['country_code']?.toString(),
      durationSeconds: (json['duration_sec'] as num?)?.toDouble(),
      hasGps: json['has_gps'] as bool? ?? false,
      transcriptAvailable: json['transcript_available'] as bool? ?? false,
      transcriptState: json['transcript_state']?.toString(),
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      sizeDisplay: json['size_display']?.toString(),
    );
  }

  Uri buildPreviewUri(Uri base) {
    return base.replace(
      path: '/preview/video',
      queryParameters: {'p': path},
    );
  }

  Uri buildThumbnailUri(Uri base) {
    return base.replace(
      path: '/preview/video_thumb',
      queryParameters: {'p': path},
    );
  }

  Uri buildDownloadUri(Uri base) {
    return base.replace(
      path: '/download',
      queryParameters: {'p': path},
    );
  }
}

class MediaPage<T> {
  const MediaPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  final List<T> items;
  final int page;
  final int pageSize;
  final int total;

  int get pageCount {
    if (pageSize <= 0) {
      return 1;
    }
    final pages = (total / pageSize).ceil();
    return pages < 1 ? 1 : pages;
  }
}
