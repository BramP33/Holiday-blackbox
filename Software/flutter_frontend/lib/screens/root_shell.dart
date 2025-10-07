import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'backup_screen.dart';
import 'dashboard_screen.dart';
import 'media_library_screen.dart';
import 'settings_screen.dart';

class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  final _pages = const [
    DashboardScreen(),
    MediaLibraryScreen(),
    BackupScreen(),
    SettingsScreen(),
  ];

  final _destinations = const [
    NavigationDestination(
      icon: Icon(Icons.terrain_outlined),
      selectedIcon: Icon(Icons.terrain),
      label: 'Tent',
    ),
    NavigationDestination(
      icon: Icon(Icons.photo_library_outlined),
      selectedIcon: Icon(Icons.photo_library),
      label: 'Library',
    ),
    NavigationDestination(
      icon: Icon(Icons.cloud_upload_outlined),
      selectedIcon: Icon(Icons.cloud_upload),
      label: 'Backup',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  @override
  void initState() {
    super.initState();
    ref.read(onScreenKeyboardControllerProvider);
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(navigationIndexProvider);
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: index, children: _pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => ref.read(navigationIndexProvider.notifier).state = value,
        destinations: _destinations,
      ),
    );
  }
}
