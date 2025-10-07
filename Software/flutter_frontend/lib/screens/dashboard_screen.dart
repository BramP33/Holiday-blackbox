import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout.dart';
import '../models/trip_stats.dart';
import '../state/providers.dart';
import '../widgets/info_tile.dart';
import '../widgets/section_header.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(tripStatsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(tripStatsProvider);
        await ref.read(tripStatsProvider.future);
      },
      child: statsAsync.when(
        data: (stats) => _DashboardBody(stats: stats),
        loading: () => const _LoadingState(),
        error: (error, stack) => _ErrorState(error: error),
      ),
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  const _DashboardBody({required this.stats});

  final TripStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final horizontal = ScreenLayout.horizontalPadding(context);
    final vertical = ScreenLayout.verticalPadding(context);
    final spacing = ScreenLayout.journalSpacing(context);

    return ListView(
      padding: EdgeInsets.fromLTRB(horizontal, vertical, horizontal, vertical + 32),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SectionHeader(title: 'Trip overview'),
        SizedBox(height: spacing - 12),
        Material(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.all(ScreenLayout.isTargetSize(context) ? 18 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stats.tripName.isEmpty ? 'Unnamed trip' : stats.tripName,
                  style: theme.textTheme.titleLarge,
                ),
                SizedBox(height: spacing - 12),
                Row(
                  children: [
                    Expanded(
                      child: InfoTile(
                        label: 'Photos',
                        value: stats.photoCount.toString(),
                        icon: Icons.photo,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InfoTile(
                        label: 'Video',
                        value: stats.videoDurationLabel,
                        icon: Icons.movie,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: spacing - 12),
                InfoTile(
                  label: 'Free space',
                  value: '${stats.freeGigabytes.toStringAsFixed(1)} GB',
                  icon: Icons.storage,
                ),
                SizedBox(height: spacing - 8),
                if (stats.deviceNames.isNotEmpty)
                  Wrap(
                    spacing: spacing - 12,
                    runSpacing: spacing - 12,
                    children: stats.deviceNames
                        .map((name) => Chip(
                              label: Text(name),
                              avatar: const Icon(Icons.videocam, size: 16),
                            ))
                        .toList(growable: false),
                  )
                else
                  Text(
                    'No devices indexed yet',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: spacing),
        const SectionHeader(title: 'Quick actions'),
        SizedBox(height: spacing - 12),
        Wrap(
          spacing: spacing - 12,
          runSpacing: spacing - 12,
          children: [
            _QuickActionButton(
              icon: Icons.cloud_upload,
              label: 'Start backup',
              onPressed: () async {
                final api = ref.read(apiClientProvider);
                try {
                  await api.startBackup();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Backup started')),
                    );
                    ref.invalidate(backupStatusProvider);
                  }
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed: $error')),
                    );
                  }
                }
              },
            ),
            _QuickActionButton(
              icon: Icons.photo_library,
              label: 'Open library',
              onPressed: () {
                ref.read(navigationIndexProvider.notifier).state = 1;
              },
            ),
            _QuickActionButton(
              icon: Icons.settings,
              label: 'Settings',
              onPressed: () {
                ref.read(navigationIndexProvider.notifier).state = 3;
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isTarget = ScreenLayout.isTargetSize(context);
    return SizedBox(
      width: isTarget ? 164 : 180,
      height: isTarget ? 52 : 56,
      child: FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.error, size: 64, color: Colors.redAccent),
        const SizedBox(height: 16),
        Text(
          'Something went wrong',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(error.toString()),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () {
            final messenger = ScaffoldMessenger.of(context);
            messenger.showSnackBar(const SnackBar(content: Text('Retry fetch from pull-to-refresh')));
          },
          child: const Text('Retry later'),
        ),
      ],
    );
  }
}
