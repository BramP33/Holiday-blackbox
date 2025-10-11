import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_environment.dart';
import '../state/providers.dart';
import '../widgets/section_header.dart';
import 'bluetooth_debug_screen.dart';
import 'wifi_debug_screen.dart';

class AdvancedSettingsScreen extends ConsumerStatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  ConsumerState<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends ConsumerState<AdvancedSettingsScreen> {
  static const _deepEquality = DeepCollectionEquality();

  Map<String, dynamic>? _draft;
  Map<String, dynamic>? _serverConfig;
  bool _dirty = false;
  bool _saving = false;
  bool _syncRequested = false;
  int _formVersion = 0;

  @override
  Widget build(BuildContext context) {
    final env = ref.watch(appEnvironmentProvider);
    final configAsync = ref.watch(configProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Advanced settings'),
        leading: const BackButton(),
      ),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => _buildError(context, error),
        data: (config) {
          _serverConfig = _deepCopy(config);
          if (_draft == null || _syncRequested || (!_dirty && !_deepEquality.equals(_draft, _serverConfig))) {
            _draft = _deepCopy(_serverConfig!);
            _dirty = false;
            _formVersion++;
            _syncRequested = false;
          }

          final draft = _draft;
          if (draft == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return RefreshIndicator(
            onRefresh: () async {
              _syncRequested = true;
              ref.invalidate(configProvider);
              await ref.read(configProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SectionHeader(title: 'Configuration', action: _buildActions(context)),
                const SizedBox(height: 12),
                _buildOverviewCard(context, env),
                const SizedBox(height: 24),
                SectionHeader(title: 'General'),
                const SizedBox(height: 12),
                _buildGeneralSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Access Point'),
                const SizedBox(height: 12),
                _buildApSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Previews'),
                const SizedBox(height: 12),
                _buildPreviewsSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Storage & Paths'),
                const SizedBox(height: 12),
                _buildStorageSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Transcription'),
                const SizedBox(height: 12),
                _buildTranscriptionSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Web Interface'),
                const SizedBox(height: 12),
                _buildWebSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Device Labels'),
                const SizedBox(height: 12),
                _buildDeviceLabelsSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Hardware'),
                const SizedBox(height: 12),
                _buildHardwareSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Debug Tools'),
                const SizedBox(height: 12),
                _buildDebugSection(context),
                const SizedBox(height: 24),
                SectionHeader(title: 'Application Control'),
                const SizedBox(height: 12),
                _buildApplicationControlSection(context),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_dirty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Unsaved changes',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary),
            ),
          ),
        OutlinedButton.icon(
          onPressed: (_dirty && !_saving) ? () => _resetDraft() : null,
          icon: const Icon(Icons.refresh),
          label: const Text('Reset'),
        ),
        FilledButton.icon(
          onPressed: (!_dirty || _saving) ? null : () => _handleSave(context),
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save),
          label: const Text('Save changes'),
        ),
      ],
    );
  }

  Widget _buildOverviewCard(BuildContext context, AppEnvironment env) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Backend', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _InfoRow(label: 'API base URL', value: env.baseUri.toString()),
          _InfoRow(label: 'Status stream', value: env.webSocketUri.toString()),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _openWeb(context, env.baseUri),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Open web interface'),
              ),
              OutlinedButton.icon(
                onPressed: () => _openDocs(context, env.baseUri),
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('Open documentation'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralSection(BuildContext context) {
    final languageItems = const [
      DropdownMenuItem(value: 'en', child: Text('English')),
      DropdownMenuItem(value: 'nl', child: Text('Dutch')),
    ];
    final verifyItems = const [
      DropdownMenuItem(value: 'fast', child: Text('Fast (size only)')),
      DropdownMenuItem(value: 'sha256', child: Text('SHA-256 checksum')),
    ];
    final powerItems = const [
      DropdownMenuItem(value: 'info', child: Text('Info screen')),
      DropdownMenuItem(value: 'trip', child: Text('Trip info')),
      DropdownMenuItem(value: 'clear', child: Text('Clear (blank)')),
    ];
    final networkItems = const [
      DropdownMenuItem(value: 'ap', child: Text('Create hotspot')),
      DropdownMenuItem(value: 'wifi', child: Text('Join Wi-Fi')),
    ];

    return _sectionCard(
      context,
      child: Column(
        children: [
          _buildDropdown(
            context,
            path: const ['language'],
            label: 'Interface language',
            items: languageItems,
          ),
          const SizedBox(height: 12),
          _buildDropdown(
            context,
            path: const ['verify', 'default_mode'],
            label: 'Verification mode',
            items: verifyItems,
          ),
          const SizedBox(height: 12),
          _buildDropdown(
            context,
            path: const ['power_off_screen'],
            label: 'Power-off screen',
            items: powerItems,
          ),
          const SizedBox(height: 12),
          _buildDropdown(
            context,
            path: const ['network', 'mode'],
            label: 'Network mode',
            items: networkItems,
          ),
        ],
      ),
    );
  }

  Widget _buildApSection(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        children: [
          _buildTextField(
            context,
            path: const ['ap', 'ssid'],
            label: 'SSID',
            hint: 'Blackbox',
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['ap', 'password'],
            label: 'Password',
            helperText: 'Leave blank for open network (not recommended)',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  context,
                  path: const ['ap', 'channel'],
                  label: 'Channel',
                  hint: 'auto or channel number',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTextField(
                  context,
                  path: const ['ap', 'region'],
                  label: 'Region',
                  hint: 'US / EU / ...',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewsSection(BuildContext context) {
    final previewsEnabled = _boolValue(const ['previews', 'enabled'], fallback: true);
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSwitch(
            context,
            path: const ['previews', 'enabled'],
            title: 'Generate previews',
            subtitle: 'Create proxy videos and thumbnails after import',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  context,
                  path: const ['previews', 'video_height'],
                  label: 'Video height (px)',
                  keyboardType: TextInputType.number,
                  enabled: previewsEnabled,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTextField(
                  context,
                  path: const ['previews', 'video_bitrate'],
                  label: 'Video bitrate',
                  helperText: 'e.g. 1200k',
                  enabled: previewsEnabled,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['previews', 'max_cache_gb'],
            label: 'Max cache size (GB)',
            keyboardType: TextInputType.number,
            enabled: previewsEnabled,
          ),
        ],
      ),
    );
  }

  Widget _buildStorageSection(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextField(
            context,
            path: const ['limits', 'min_free_gb'],
            label: 'Reserve free space (GB)',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['paths', 'nvme_mount'],
            label: 'NVMe mount path',
            helperText: 'Root mount where the Blackbox folder is created',
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['paths', 'source_roots'],
            label: 'Source roots',
            helperText: 'One path per line',
            maxLines: 3,
            listSeparator: '\n',
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['paths', 'proxies_subdir'],
            label: 'Proxies subdirectory',
          ),
        ],
      ),
    );
  }

  Widget _buildTranscriptionSection(BuildContext context) {
    final transcriptionEnabled = _boolValue(const ['transcription', 'enabled'], fallback: true);
    final semanticEnabled = _boolValue(const ['transcription', 'semantic', 'enabled'], fallback: true);
    final theme = Theme.of(context);

    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSwitch(
            context,
            path: const ['transcription', 'enabled'],
            title: 'Enable transcription',
            subtitle: 'Automatically transcribe audio during quiet hours',
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: transcriptionEnabled ? 1.0 : 0.6,
            child: IgnorePointer(
              ignoring: !transcriptionEnabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'start_time'],
                          label: 'Quiet hours start',
                          hint: '22:00',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'end_time'],
                          label: 'Quiet hours end',
                          hint: '07:00',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    context,
                    path: const ['transcription', 'poll_seconds'],
                    label: 'Poll interval (seconds)',
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  Text('Whisper', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _buildTextField(
                    context,
                    path: const ['transcription', 'whisper', 'model'],
                    label: 'Model',
                  ),
                  const SizedBox(height: 12),
                  _buildDropdown(
                    context,
                    path: const ['transcription', 'whisper', 'language'],
                    label: 'Language',
                    items: const [
                      DropdownMenuItem(value: 'auto', child: Text('Auto-detect')),
                      DropdownMenuItem(value: 'nl', child: Text('Nederlands')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                      DropdownMenuItem(value: 'fr', child: Text('Français')),
                      DropdownMenuItem(value: 'es', child: Text('Español')),
                      DropdownMenuItem(value: 'it', child: Text('Italiano')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'whisper', 'compute_type'],
                          label: 'Compute type',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'whisper', 'device'],
                          label: 'Device',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'whisper', 'beam_size'],
                          label: 'Beam size',
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'whisper', 'temperature'],
                          label: 'Temperature',
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildSwitch(
                    context,
                    path: const ['transcription', 'whisper', 'vad_filter'],
                    title: 'Voice activity detection',
                    subtitle: 'Skip silent segments for faster processing',
                  ),
                  const SizedBox(height: 16),
                  Text('Keywords', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _buildDropdown(
                    context,
                    path: const ['transcription', 'keywords', 'method'],
                    label: 'Method',
                    items: const [
                      DropdownMenuItem(value: 'frequency', child: Text('Frequency')), 
                      DropdownMenuItem(value: 'sentence-transformer', child: Text('Sentence transformer')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'keywords', 'top_k'],
                          label: 'Top K',
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildTextField(
                          context,
                          path: const ['transcription', 'keywords', 'max_candidates'],
                          label: 'Max candidates',
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Semantic search', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _buildSwitch(
                    context,
                    path: const ['transcription', 'semantic', 'enabled'],
                    title: 'Enable semantic clustering',
                    subtitle: 'Group clips by meaning using embeddings',
                  ),
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: semanticEnabled ? 1.0 : 0.6,
                    child: IgnorePointer(
                      ignoring: !semanticEnabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildTextField(
                            context,
                            path: const ['transcription', 'semantic', 'model'],
                            label: 'Model',
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _buildTextField(
                                  context,
                                  path: const ['transcription', 'semantic', 'device'],
                                  label: 'Device',
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildTextField(
                                  context,
                                  path: const ['transcription', 'semantic', 'min_similarity'],
                                  label: 'Min similarity',
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebSection(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextField(
            context,
            path: const ['web', 'host'],
            label: 'Host',
            hint: '0.0.0.0',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  context,
                  path: const ['web', 'port'],
                  label: 'Port',
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTextField(
                  context,
                  path: const ['web', 'page_size'],
                  label: 'Page size',
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['web', 'upload_device_label'],
            label: 'Upload device label',
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['web', 'upload_max_mb'],
            label: 'Max upload size (MB)',
            keyboardType: TextInputType.number,
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceLabelsSection(BuildContext context) {
    final labelsRaw = _getValue(const ['device_labels']);
    final labels = <String, String>{};
    if (labelsRaw is Map) {
      for (final entry in labelsRaw.entries) {
        final key = entry.key.toString();
        labels[key] = (entry.value ?? '').toString();
      }
    }
    final sortedKeys = labels.keys.toList()..sort();

    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final key in sortedKeys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(key, style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: ValueKey('device_labels.$key.$_formVersion'),
                      initialValue: labels[key],
                      decoration: const InputDecoration(labelText: 'Label'),
                      onChanged: (value) => _updateField(['device_labels', key], value),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: () => _removeDeviceLabel(key),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _promptDeviceLabel(context),
            icon: const Icon(Icons.add),
            label: const Text('Add label'),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareSection(BuildContext context) {
    final orientationItems = const [
      DropdownMenuItem(value: 'landscape', child: Text('Landscape')),
      DropdownMenuItem(value: 'portrait', child: Text('Portrait')),
    ];

    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextField(
            context,
            path: const ['hardware', 'display'],
            label: 'Display driver',
            helperText: 'e.g. epd2in7_v2',
          ),
          const SizedBox(height: 12),
          _buildDropdown(
            context,
            path: const ['hardware', 'orientation'],
            label: 'Orientation',
            items: orientationItems,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            path: const ['hardware', 'buttons'],
            label: 'Button pins',
            helperText: 'Comma or space separated BCM numbers (top to bottom)',
          ),
        ],
      ),
    );
  }

  Widget _buildDebugSection(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: const Text('WiFi Debug'),
            subtitle: const Text('Debug WiFi connectivity and scan for networks'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WiFiDebugScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bluetooth_searching),
            title: const Text('Bluetooth Debug'),
            subtitle: const Text('Debug Bluetooth connectivity and device pairing'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BluetoothDebugScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApplicationControlSection(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(Icons.desktop_windows, color: Theme.of(context).colorScheme.error),
            title: const Text('Back to Desktop'),
            subtitle: const Text('Close the application and return to desktop'),
            trailing: FilledButton.icon(
              onPressed: () => _handleBackToDesktop(context),
              icon: const Icon(Icons.close),
              label: const Text('Exit'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
    BuildContext context, {
    required List<String> path,
    required String label,
    String? hint,
    String? helperText,
    TextInputType? keyboardType,
    int maxLines = 1,
    bool enabled = true,
    String listSeparator = ', ',
  }) {
    final value = _stringValue(_getValue(path), separator: listSeparator);
    final effectiveKeyboard = keyboardType ?? (maxLines > 1 ? TextInputType.multiline : TextInputType.text);
    return TextFormField(
      key: ValueKey('${path.join('.')}.$_formVersion'),
      initialValue: value,
      enabled: enabled,
      decoration: InputDecoration(labelText: label, hintText: hint, helperText: helperText),
      keyboardType: effectiveKeyboard,
      maxLines: maxLines,
      onChanged: (text) => _updateField(path, text),
    );
  }

  Widget _buildDropdown(
    BuildContext context, {
    required List<String> path,
    required String label,
    required List<DropdownMenuItem<String>> items,
  }) {
    final current = _getValue(path)?.toString();
    final knownValues = items.map((item) => item.value).whereType<String>().toSet();
    final dropdownItems = [
      ...items,
      if (current != null && current.isNotEmpty && !knownValues.contains(current))
        DropdownMenuItem(value: current, child: Text(current)),
    ];
    final value = (current != null && current.isNotEmpty) ? current : dropdownItems.first.value;

    return DropdownButtonFormField<String>(
      key: ValueKey('${path.join('.')}.$_formVersion'),
      value: value,
      decoration: InputDecoration(labelText: label),
      items: dropdownItems,
      onChanged: (selected) {
        if (selected != null) {
          _updateField(path, selected);
        }
      },
    );
  }

  Widget _buildSwitch(
    BuildContext context, {
    required List<String> path,
    required String title,
    String? subtitle,
  }) {
    final value = _boolValue(path, fallback: false);
    return SwitchListTile(
      key: ValueKey('${path.join('.')}.$_formVersion'),
      value: value,
      onChanged: (val) => _updateField(path, val),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const Icon(Icons.error_outline, size: 64),
        const SizedBox(height: 16),
        Text('Failed to load settings', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(error.toString(), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            onPressed: () {
              _syncRequested = true;
              ref.invalidate(configProvider);
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }

  Widget _sectionCard(BuildContext context, {required Widget child}) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Future<void> _handleSave(BuildContext context) async {
    if (_draft == null || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
    });

    final errors = <String>[];
    final payload = _buildPayload(errors);
    if (errors.isNotEmpty) {
      final message = errors.first;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      setState(() {
        _saving = false;
      });
      return;
    }

    try {
      final api = ref.read(apiClientProvider);
      final saved = await api.updateConfig(payload);
      if (!mounted) return;
      setState(() {
        _serverConfig = _deepCopy(saved);
        _draft = _deepCopy(saved);
        _dirty = false;
        _saving = false;
        _formVersion++;
      });
      if (!mounted) return;
      ref.invalidate(configProvider);
      ref.read(localeProvider.notifier).setLocale(localeFromConfig(saved['language']?.toString()));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save settings: $error')));
    }
  }

  Future<void> _handleBackToDesktop(BuildContext context) async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Exit Application'),
          content: const Text('Are you sure you want to close the application and return to desktop?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Exit'),
            ),
          ],
        );
      },
    );

    if (shouldExit == true) {
      // Close the application
      exit(0);
    }
  }

  void _resetDraft() {
    if (_serverConfig == null) return;
    setState(() {
      _draft = _deepCopy(_serverConfig!);
      _dirty = false;
      _formVersion++;
    });
  }

  void _updateField(List<String> path, dynamic value) {
    final map = _draft;
    if (map == null) return;
    setState(() {
      _setValueOn(map, path, value);
      _dirty = true;
    });
  }

  void _removeDeviceLabel(String key) {
    final map = _draft;
    if (map == null) return;
    final labelsRaw = _getValue(const ['device_labels']);
    final labels = <String, dynamic>{};
    if (labelsRaw is Map) {
      labels.addAll(labelsRaw.map((k, v) => MapEntry(k.toString(), v)));
    }
    if (!labels.containsKey(key)) {
      return;
    }
    setState(() {
      labels.remove(key);
      _setValueOn(map, const ['device_labels'], labels);
      _dirty = true;
      _formVersion++;
    });
  }

  Future<void> _promptDeviceLabel(BuildContext context) async {
    final keyController = TextEditingController();
    final valueController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<_LabelInput>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add device label'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: keyController,
                  decoration: const InputDecoration(labelText: 'Device id'),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Enter a device id';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: valueController,
                  decoration: const InputDecoration(labelText: 'Display label'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(_LabelInput(
                    keyController.text.trim(),
                    valueController.text.trim(),
                  ));
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    if (result == null || _draft == null) {
      return;
    }

    final labelsRaw = _getValue(const ['device_labels']);
    final labels = <String, dynamic>{};
    if (labelsRaw is Map) {
      labels.addAll(labelsRaw.map((k, v) => MapEntry(k.toString(), v)));
    }
    setState(() {
      labels[result.key] = result.value;
      _setValueOn(_draft!, const ['device_labels'], labels);
      _dirty = true;
      _formVersion++;
    });
  }

  Map<String, dynamic> _buildPayload(List<String> errors) {
    final source = _draft ?? <String, dynamic>{};
    final result = _deepCopy(source);

    void stringField(List<String> path, {bool trim = true}) {
      final raw = _getValueFrom(source, path);
      if (raw == null) {
        _setValueOn(result, path, '');
        return;
      }
      var text = raw.toString();
      if (trim) {
        text = text.trim();
      }
      _setValueOn(result, path, text);
    }

    int? parseIntField(List<String> path, String label) {
      final raw = _getValueFrom(source, path);
      final parsed = _coerceInt(raw);
      if (parsed == null) {
        errors.add('$label must be a number');
      }
      return parsed;
    }

    double? parseDoubleField(List<String> path, String label) {
      final raw = _getValueFrom(source, path);
      final parsed = _coerceDouble(raw);
      if (parsed == null) {
        errors.add('$label must be a number');
      }
      return parsed;
    }

    List<String> parseListField(List<String> path, {Pattern? pattern}) {
      final raw = _getValueFrom(source, path);
      return _toStringList(raw, pattern: pattern);
    }

    List<int> parseIntListField(List<String> path) {
      final raw = _getValueFrom(source, path);
      return _toIntList(raw);
    }

    // Strings
    stringField(const ['verify', 'default_mode']);
    stringField(const ['power_off_screen']);
    stringField(const ['language']);
    stringField(const ['network', 'mode']);
    stringField(const ['ap', 'ssid']);
    stringField(const ['ap', 'password'], trim: false);
    stringField(const ['ap', 'channel']);
    stringField(const ['ap', 'region']);
    stringField(const ['previews', 'video_bitrate']);
    stringField(const ['transcription', 'start_time']);
    stringField(const ['transcription', 'end_time']);
    stringField(const ['transcription', 'whisper', 'model']);
    stringField(const ['transcription', 'whisper', 'compute_type']);
    stringField(const ['transcription', 'whisper', 'device']);
    stringField(const ['transcription', 'keywords', 'method']);
    stringField(const ['transcription', 'semantic', 'model']);
    stringField(const ['transcription', 'semantic', 'device']);
    stringField(const ['web', 'host']);
    stringField(const ['web', 'upload_device_label']);
    stringField(const ['paths', 'nvme_mount']);
    stringField(const ['paths', 'proxies_subdir']);
    stringField(const ['hardware', 'display']);
    stringField(const ['hardware', 'orientation']);

    // Lists
    _setValueOn(result, const ['trip', 'places'], parseListField(const ['trip', 'places']));
    _setValueOn(result, const ['paths', 'source_roots'], parseListField(const ['paths', 'source_roots'], pattern: '\n'));
    _setValueOn(result, const ['hardware', 'buttons'], parseIntListField(const ['hardware', 'buttons']));

    // Device labels map normalization
    final labelsRaw = _getValueFrom(source, const ['device_labels']);
    if (labelsRaw is Map) {
      final normalized = <String, String>{};
      for (final entry in labelsRaw.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;
        normalized[key] = (entry.value ?? '').toString().trim();
      }
      _setValueOn(result, const ['device_labels'], normalized);
    }

    // Integer fields
    final intFields = <List<String>, String>{
      const ['limits', 'min_free_gb']: 'Reserve free space',
      const ['previews', 'video_height']: 'Video height',
      const ['previews', 'max_cache_gb']: 'Preview cache size',
      const ['transcription', 'poll_seconds']: 'Poll interval',
      const ['transcription', 'whisper', 'beam_size']: 'Beam size',
      const ['transcription', 'keywords', 'top_k']: 'Top K',
      const ['transcription', 'keywords', 'max_candidates']: 'Max candidates',
      const ['web', 'page_size']: 'Page size',
      const ['web', 'port']: 'Web port',
      const ['web', 'upload_max_mb']: 'Max upload size',
    };
    for (final entry in intFields.entries) {
      final parsed = parseIntField(entry.key, entry.value);
      if (parsed != null) {
        _setValueOn(result, entry.key, parsed);
      }
    }

    // Double fields
    final doubleFields = <List<String>, String>{
      const ['transcription', 'whisper', 'temperature']: 'Whisper temperature',
      const ['transcription', 'semantic', 'min_similarity']: 'Min similarity',
    };
    for (final entry in doubleFields.entries) {
      final parsed = parseDoubleField(entry.key, entry.value);
      if (parsed != null) {
        _setValueOn(result, entry.key, parsed);
      }
    }

    return result;
  }

  Map<String, dynamic> _deepCopy(Map<String, dynamic> source) {
    return json.decode(json.encode(source)) as Map<String, dynamic>;
  }

  dynamic _getValue(List<String> path) {
    final map = _draft;
    if (map == null) return null;
    return _getValueFrom(map, path);
  }

  dynamic _getValueFrom(Map<String, dynamic> source, List<String> path) {
    dynamic current = source;
    for (final segment in path) {
      if (current is Map<String, dynamic>) {
        current = current[segment];
      } else if (current is Map) {
        current = (current as Map)[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  void _setValueOn(Map<String, dynamic> target, List<String> path, dynamic value) {
    Map<String, dynamic> current = target;
    for (var i = 0; i < path.length - 1; i++) {
      final key = path[i];
      final next = current[key];
      if (next is Map<String, dynamic>) {
        current = next;
      } else if (next is Map) {
        final converted = Map<String, dynamic>.from(next as Map);
        current[key] = converted;
        current = converted;
      } else {
        final newMap = <String, dynamic>{};
        current[key] = newMap;
        current = newMap;
      }
    }
    current[path.last] = value;
  }

  String _stringValue(dynamic raw, {String separator = ', '}) {
    if (raw == null) return '';
    if (raw is String) return raw;
    if (raw is List) {
      return raw.map((value) => value.toString()).join(separator);
    }
    return raw.toString();
  }

  bool _boolValue(List<String> path, {bool fallback = false}) {
    final raw = _getValue(path);
    if (raw is bool) return raw;
    if (raw is String) {
      final lower = raw.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    if (raw is num) return raw != 0;
    return fallback;
  }

  int? _coerceInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return int.tryParse(trimmed);
    }
    return null;
  }

  double? _coerceDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return double.tryParse(trimmed);
    }
    return null;
  }

  List<String> _toStringList(dynamic value, {Pattern? pattern}) {
    final separator = pattern ?? RegExp(r'[\n,]');
    if (value is List) {
      return value.map((entry) => entry.toString().trim()).where((entry) => entry.isNotEmpty).toList();
    }
    if (value is String) {
      final parts = value.split(separator);
      return parts.map((entry) => entry.trim()).where((entry) => entry.isNotEmpty).toList();
    }
    return const [];
  }

  List<int> _toIntList(dynamic value) {
    final result = <int>[];
    Iterable<dynamic> entries;
    if (value is List) {
      entries = value;
    } else if (value is String) {
      entries = value.split(RegExp('[,\s]+'));
    } else {
      return result;
    }
    for (final entry in entries) {
      final parsed = _coerceInt(entry);
      if (parsed != null) {
        result.add(parsed);
      }
    }
    return result;
  }

  Future<void> _openWeb(BuildContext context, Uri baseUri) async {
    final uri = baseUri.replace(path: '/');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to open browser')));
    }
  }

  Future<void> _openDocs(BuildContext context, Uri baseUri) async {
    final uri = baseUri.replace(path: '/README');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to open documentation')));
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          SelectableText(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _LabelInput {
  const _LabelInput(this.key, this.value);

  final String key;
  final String value;
}
