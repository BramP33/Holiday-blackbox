import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/trip_settings_service.dart';
import '../state/providers.dart';
import '../utils/camp_name_generator.dart';

class TripSettingsScreen extends ConsumerStatefulWidget {
  const TripSettingsScreen({super.key});

  @override
  ConsumerState<TripSettingsScreen> createState() => _TripSettingsScreenState();
}

class _TripSettingsScreenState extends ConsumerState<TripSettingsScreen> {
  final TripSettingsService _tripService = TripSettingsService.instance;
  final CampNameGenerator _nameGenerator = CampNameGenerator.instance;
  
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _placesController = TextEditingController();
  
  TripSettings? _currentSettings;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTripSettings();
    _nameGenerator.ensureLoaded();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _placesController.dispose();
    super.dispose();
  }

  Future<void> _loadTripSettings() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final apiClient = ref.read(apiClientProvider);
    final result = await _tripService.loadTripSettings(apiClient);

    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _currentSettings = result.data!;
        _nameController.text = _currentSettings!.name;
        _startDate = _currentSettings!.beginDate;
        _endDate = _currentSettings!.endDate;
        _placesController.text = _currentSettings!.places.join(', ');
      } else {
        _errorMessage = result.error;
      }
    });
  }

  Future<void> _saveTripSettings() async {
    if (_currentSettings == null) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    final places = _placesController.text
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final updatedSettings = _currentSettings!.copyWith(
      name: _nameController.text.trim(),
      beginDate: _startDate ?? _currentSettings!.beginDate,
      endDate: _endDate ?? _currentSettings!.endDate,
      places: places,
    );

    final apiClient = ref.read(apiClientProvider);
    final result = await _tripService.saveTripSettings(apiClient, updatedSettings);

    setState(() {
      _isSaving = false;
      if (result.isSuccess) {
        _currentSettings = result.data!;
        _showSnackBar('Trip settings saved successfully!', isError: false);
      } else {
        _errorMessage = result.error;
        _showSnackBar('Failed to save: ${result.error}', isError: true);
      }
    });
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> _selectStartDate() async {
    final currentDate = _startDate ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: 'Select trip start date',
    );

    if (picked != null) {
      setState(() {
        _startDate = picked;
        // Ensure end date is not before start date
        if (_endDate != null && _endDate!.isBefore(picked)) {
          _endDate = picked.add(const Duration(days: 1));
        }
      });
    }
  }

  Future<void> _selectEndDate() async {
    final currentDate = _endDate ?? DateTime.now().add(const Duration(days: 7));
    final minDate = _startDate ?? DateTime.now();
    
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate.isBefore(minDate) ? minDate : currentDate,
      firstDate: minDate,
      lastDate: DateTime(2030),
      helpText: 'Select trip end date',
    );

    if (picked != null) {
      setState(() {
        _endDate = picked;
      });
    }
  }

  void _generateRandomName() {
    final randomName = _nameGenerator.randomName();
    setState(() {
      _nameController.text = randomName;
    });
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Select date';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.map_outlined),
            SizedBox(width: 8),
            Text('Trip Settings'),
          ],
        ),
        leading: const BackButton(),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              onPressed: _currentSettings != null ? _saveTripSettings : null,
              child: const Text('Save'),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading trip settings...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: $_errorMessage'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadTripSettings,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildTripNameSection(),
        const SizedBox(height: 24),
        _buildDatesSection(),
        const SizedBox(height: 24),
        _buildPlacesSection(),
        const SizedBox(height: 32),
        _buildSaveButton(),
      ],
    );
  }

  Widget _buildTripNameSection() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.drive_file_rename_outline),
                const SizedBox(width: 8),
                Text(
                  'Trip Name',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Enter trip name',
                      hintText: 'My Amazing Trip',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filled(
                  onPressed: _generateRandomName,
                  icon: const Icon(Icons.casino),
                  tooltip: 'Generate random name',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDatesSection() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.date_range),
                const SizedBox(width: 8),
                Text(
                  'Trip Dates',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildDateButton(
                    label: 'Start Date',
                    date: _startDate,
                    onPressed: _selectStartDate,
                    icon: Icons.flight_takeoff,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildDateButton(
                    label: 'End Date',
                    date: _endDate,
                    onPressed: _selectEndDate,
                    icon: Icons.flight_land,
                  ),
                ),
              ],
            ),
            if (_startDate != null && _endDate != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Duration: ${_endDate!.difference(_startDate!).inDays + 1} days',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDateButton({
    required String label,
    required DateTime? date,
    required VoidCallback onPressed,
    required IconData icon,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            _formatDate(date),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildPlacesSection() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.place),
                const SizedBox(width: 8),
                Text(
                  'Destinations',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Add places you plan to visit (comma-separated)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _placesController,
              decoration: const InputDecoration(
                labelText: 'Enter places',
                hintText: 'Paris, Rome, Barcelona',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _currentSettings != null && !_isSaving ? _saveTripSettings : null,
      icon: _isSaving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.save),
      label: Text(_isSaving ? 'Saving...' : 'Save Trip Settings'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
