import 'package:flutter/material.dart';

import 'advanced_settings_screen.dart';
import 'bluetooth_settings_screen.dart';
import 'bluetooth_debug_screen.dart';
import 'trip_settings_screen.dart';
import 'wifi_settings_screen.dart';
import 'wifi_debug_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsNavButton(
          icon: Icons.map_outlined,
          title: 'Trip',
          subtitle: 'Plan and manage trip preferences.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TripSettingsScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _SettingsNavButton(
          icon: Icons.wifi,
          title: 'Wi-Fi',
          subtitle: 'Configure wireless connectivity.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WifiSettingsScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _SettingsNavButton(
          icon: Icons.bluetooth,
          title: 'Bluetooth',
          subtitle: 'Pair and manage Bluetooth devices.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BluetoothSettingsScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _SettingsNavButton(
          icon: Icons.tune,
          title: 'Advanced',
          subtitle: 'Access detailed configuration options.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdvancedSettingsScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _SettingsNavButton(
          icon: Icons.bug_report,
          title: 'WiFi Debug',
          subtitle: 'Debug WiFi connectivity and scan for networks.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WiFiDebugScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _SettingsNavButton(
          icon: Icons.bluetooth_searching,
          title: 'Bluetooth Debug',
          subtitle: 'Debug Bluetooth connectivity and device pairing.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BluetoothDebugScreen()),
          ),
        ),
      ],
    );
  }
}

class _SettingsNavButton extends StatelessWidget {
  const _SettingsNavButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurface.withOpacity(0.6)),
            ],
          ),
        ),
      ),
    );
  }
}
