class TripStats {
  const TripStats({
    required this.tripName,
    required this.videoDurationLabel,
    required this.videoSeconds,
    required this.photoCount,
    required this.freeBytes,
    required this.deviceNames,
    required this.generatedAt,
  });

  final String tripName;
  final String videoDurationLabel;
  final double videoSeconds;
  final int photoCount;
  final int freeBytes;
  final List<String> deviceNames;
  final DateTime generatedAt;

  double get freeGigabytes => freeBytes / 1000000000.0;

  factory TripStats.fromJson(Map<String, dynamic> json) {
    final devices = (json['device_names'] as List<dynamic>? ?? [])
        .map((entry) => entry.toString())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    return TripStats(
      tripName: json['trip_name']?.toString() ?? 'Trip',
      videoDurationLabel: json['video_duration_label']?.toString() ?? '0m',
      videoSeconds: (json['video_seconds'] as num?)?.toDouble() ?? 0,
      photoCount: json['photo_count'] as int? ?? 0,
      freeBytes: json['free_bytes'] as int? ?? 0,
      deviceNames: devices,
      generatedAt: DateTime.tryParse(json['generated_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}
