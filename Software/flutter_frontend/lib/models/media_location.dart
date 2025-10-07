class MediaLocation {
  MediaLocation({
    required this.path,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.capturedAt,
    this.city,
    this.admin,
    this.countryCode,
    this.locationSlug,
  });

  final String path;
  final double latitude;
  final double longitude;
  final double? altitude;
  final String? capturedAt;
  final String? city;
  final String? admin;
  final String? countryCode;
  final String? locationSlug;

  factory MediaLocation.fromJson(Map<String, dynamic> json) {
    double? _asDouble(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      if (value is String) {
        return double.tryParse(value);
      }
      return null;
    }

    final lat = _asDouble(json['latitude']) ?? 0.0;
    final lon = _asDouble(json['longitude']) ?? 0.0;
    return MediaLocation(
      path: json['path']?.toString() ?? '',
      capturedAt: json['captured_at']?.toString(),
      latitude: lat,
      longitude: lon,
      altitude: _asDouble(json['altitude']),
      city: json['city']?.toString(),
      admin: json['admin']?.toString(),
      countryCode: json['country_code']?.toString(),
      locationSlug: json['location_slug']?.toString(),
    );
  }

  double get alignmentX => (longitude / 180).clamp(-1.0, 1.0);

  double get alignmentY => (-(latitude) / 90).clamp(-1.0, 1.0);

  String displayLabel() {
    final parts = <String>[
      if ((city ?? '').trim().isNotEmpty) city!.trim(),
      if ((admin ?? '').trim().isNotEmpty) admin!.trim(),
      if ((countryCode ?? '').trim().isNotEmpty) countryCode!.trim().toUpperCase(),
    ];
    if (parts.isNotEmpty) {
      return parts.join(', ');
    }
    if ((locationSlug ?? '').trim().isNotEmpty) {
      return locationSlug!.trim();
    }
    return 'Unknown location';
  }
}
