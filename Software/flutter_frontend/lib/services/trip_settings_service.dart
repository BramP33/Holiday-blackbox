import '../services/api_client.dart';

class TripSettings {
  const TripSettings({
    required this.name,
    required this.beginDate,
    required this.endDate,
    required this.places,
  });

  final String name;
  final DateTime beginDate;
  final DateTime endDate;
  final List<String> places;

  factory TripSettings.fromJson(Map<String, dynamic> json) {
    final tripData = json['trip'] as Map<String, dynamic>? ?? {};
    
    return TripSettings(
      name: tripData['name'] as String? ?? 'My Trip',
      beginDate: _parseDate(tripData['begin_date'] as String?) ?? DateTime.now(),
      endDate: _parseDate(tripData['end_date'] as String?) ?? DateTime.now().add(const Duration(days: 7)),
      places: (tripData['places'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'trip': {
        'name': name,
        'begin_date': _formatDate(beginDate),
        'end_date': _formatDate(endDate),
        'places': places,
      },
    };
  }

  TripSettings copyWith({
    String? name,
    DateTime? beginDate,
    DateTime? endDate,
    List<String>? places,
  }) {
    return TripSettings(
      name: name ?? this.name,
      beginDate: beginDate ?? this.beginDate,
      endDate: endDate ?? this.endDate,
      places: places ?? this.places,
    );
  }

  static DateTime? _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
      return DateTime.parse(dateStr);
    } catch (e) {
      return null;
    }
  }

  static String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

class TripSettingsServiceResult<T> {
  const TripSettingsServiceResult.success(this.data) : error = null;
  const TripSettingsServiceResult.failure(this.error) : data = null;

  final T? data;
  final String? error;

  bool get isSuccess => error == null;
  bool get isFailure => error != null;
}

class TripSettingsService {
  TripSettingsService._();
  static final TripSettingsService instance = TripSettingsService._();

  /// Load current trip settings from backend
  Future<TripSettingsServiceResult<TripSettings>> loadTripSettings(ApiClient apiClient) async {
    try {
      final config = await apiClient.fetchConfig();
      final tripSettings = TripSettings.fromJson(config);
      return TripSettingsServiceResult.success(tripSettings);
    } catch (e) {
      return TripSettingsServiceResult.failure('Failed to load trip settings: $e');
    }
  }

  /// Save trip settings to backend
  Future<TripSettingsServiceResult<TripSettings>> saveTripSettings(
    ApiClient apiClient,
    TripSettings settings,
  ) async {
    try {
      // First get current config to preserve other settings
      final currentConfig = await apiClient.fetchConfig();
      
      // Update only trip settings
      final updatedConfig = Map<String, dynamic>.from(currentConfig);
      updatedConfig.addAll(settings.toJson());
      
      // Save updated config
      final savedConfig = await apiClient.updateConfig(updatedConfig);
      
      // Return the saved trip settings
      final savedTripSettings = TripSettings.fromJson(savedConfig);
      return TripSettingsServiceResult.success(savedTripSettings);
    } catch (e) {
      return TripSettingsServiceResult.failure('Failed to save trip settings: $e');
    }
  }

  /// Update only trip name
  Future<TripSettingsServiceResult<TripSettings>> updateTripName(
    ApiClient apiClient,
    String name,
  ) async {
    try {
      final currentResult = await loadTripSettings(apiClient);
      if (currentResult.isFailure) {
        return TripSettingsServiceResult.failure(currentResult.error!);
      }
      
      final updatedSettings = currentResult.data!.copyWith(name: name);
      return await saveTripSettings(apiClient, updatedSettings);
    } catch (e) {
      return TripSettingsServiceResult.failure('Failed to update trip name: $e');
    }
  }

  /// Update trip dates
  Future<TripSettingsServiceResult<TripSettings>> updateTripDates(
    ApiClient apiClient, {
    DateTime? beginDate,
    DateTime? endDate,
  }) async {
    try {
      final currentResult = await loadTripSettings(apiClient);
      if (currentResult.isFailure) {
        return TripSettingsServiceResult.failure(currentResult.error!);
      }
      
      final updatedSettings = currentResult.data!.copyWith(
        beginDate: beginDate,
        endDate: endDate,
      );
      return await saveTripSettings(apiClient, updatedSettings);
    } catch (e) {
      return TripSettingsServiceResult.failure('Failed to update trip dates: $e');
    }
  }

  /// Update trip places
  Future<TripSettingsServiceResult<TripSettings>> updateTripPlaces(
    ApiClient apiClient,
    List<String> places,
  ) async {
    try {
      final currentResult = await loadTripSettings(apiClient);
      if (currentResult.isFailure) {
        return TripSettingsServiceResult.failure(currentResult.error!);
      }
      
      final updatedSettings = currentResult.data!.copyWith(places: places);
      return await saveTripSettings(apiClient, updatedSettings);
    } catch (e) {
      return TripSettingsServiceResult.failure('Failed to update trip places: $e');
    }
  }
}