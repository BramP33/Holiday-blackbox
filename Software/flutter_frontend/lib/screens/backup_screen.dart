import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../layout.dart';
import '../models/backup_status.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../widgets/compass_gauge.dart';
import '../widgets/info_tile.dart';
import '../widgets/journal_card.dart';
import '../widgets/log_entry_banner.dart';
import '../widgets/section_header.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      ref.invalidate(backupStatusProvider);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(backupStatusProvider);
    return RefreshIndicator(
      color: AppColors.amber,
      backgroundColor: AppColors.charcoalAlt,
      onRefresh: () async {
        ref.invalidate(backupStatusProvider);
        await ref.read(backupStatusProvider.future);
      },
      child: statusAsync.when(
        data: (status) => _BackupBody(status: status),
        loading: () => const ListLoadingState(),
        error: (error, stack) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            JournalCard(
              heroBadge: _MissionBadge(
                  text: context.tr('backup.alert.badge'),
                  color: AppColors.rust),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.tr('backup.error.offline_title'),
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Text(
                    error.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackupBody extends ConsumerWidget {
  const _BackupBody({required this.status});

  final BackupStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final phase = _describePhase(context, status.phase);
    final isIndeterminate = status.phase == BackupPhase.preparing ||
        status.phase == BackupPhase.cancelling;
    final gaugeValue = status.isActive
        ? status.progress.clamp(0.0, 1.0)
        : (status.phase == BackupPhase.done ? 1.0 : 0.0);
    final horizontal = ScreenLayout.horizontalPadding(context);
    final vertical = ScreenLayout.verticalPadding(context);
    final bottom = vertical + 40;
    final journalPadding = ScreenLayout.journalPadding(context);
    final spacing = ScreenLayout.journalSpacing(context);

    final processedFiles =
        status.copiedFiles + status.skippedFiles + status.replacedFiles;
    final manifestValue = status.totalFiles > 0
        ? '$processedFiles/${status.totalFiles}'
        : processedFiles.toString();
    final previewValue = status.previewsTotal > 0
        ? '${status.previewsDone}/${status.previewsTotal}'
        : '--';
    final missionLogMessage = status.message?.isNotEmpty == true
        ? status.message!
        : _defaultLogMessage(context, status);

    Future<void> triggerStart() async {
      final api = ref.read(apiClientProvider);
      try {
        await api.startBackup();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('backup.toast.started'))),
          );
        }
        ref.invalidate(backupStatusProvider);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'backup.toast.failed',
                  params: {'error': error.toString()},
                ),
              ),
            ),
          );
        }
      }
    }

    Future<void> triggerCancel() async {
      final api = ref.read(apiClientProvider);
      try {
        await api.cancelBackup();
        ref.invalidate(backupStatusProvider);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'backup.toast.failed',
                  params: {'error': error.toString()},
                ),
              ),
            ),
          );
        }
      }
    }

    final infoTiles = [
      InfoTile(
        label: context.tr('backup.info.transfer'),
        value: manifestValue,
        icon: Icons.layers,
        caption: context.tr('backup.info.transfer_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.data'),
        value: _formatBytes(status.bytesCopied),
        icon: Icons.sd_storage,
        caption: context.tr('backup.info.data_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.speed'),
        value: status.speed ?? 'n/a',
        icon: Icons.speed,
        caption: context.tr('backup.info.speed_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.eta'),
        value: status.eta ?? '--',
        icon: Icons.hourglass_bottom,
        caption: context.tr('backup.info.eta_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.copied_new'),
        value: status.copiedFiles.toString(),
        icon: Icons.file_download_done_rounded,
        caption: context.tr('backup.info.copied_new_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.duplicates'),
        value: status.skippedFiles.toString(),
        icon: Icons.copy_all_rounded,
        caption: context.tr('backup.info.duplicates_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.replaced'),
        value: status.replacedFiles.toString(),
        icon: Icons.swap_horiz_rounded,
        caption: context.tr('backup.info.replaced_caption'),
      ),
      InfoTile(
        label: context.tr('backup.info.preview'),
        value: previewValue,
        icon: Icons.movie_filter_rounded,
        caption: context.tr('backup.info.preview_caption'),
      ),
    ];
    final recoveryCard = _buildRecoveryCard(
      context: context,
      status: status,
      spacing: spacing,
      onRetry: triggerStart,
      onRefresh: () {
        ref.invalidate(backupStatusProvider);
      },
    );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(horizontal, vertical, horizontal, bottom),
      children: [
        SectionHeader(
          title: context.tr('backup.section.deck_title'),
          subtitle: context.tr('backup.section.deck_subtitle'),
          iconAsset: 'assets/icons/trail/compass.svg',
          action: _StatusChip(isActive: status.isActive, phase: phase),
        ),
        SizedBox(height: spacing),
        JournalCard(
          padding: journalPadding,
          heroBadge: _MissionBadge(
              text: phase.label.toUpperCase(), color: phase.badgeColor),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final available = constraints.maxWidth;
              final gaugeSize = ScreenLayout.gaugeSizeForWidth(available);
              final isTarget = ScreenLayout.isTargetSize(context);
              final compactThreshold = isTarget ? 820 : 720;
              final columns = available > (isTarget ? 960 : 1024)
                  ? 3
                  : available > compactThreshold
                      ? 2
                      : 1;
              final rawTileWidth = columns > 0
                  ? (available - (columns - 1) * spacing) / columns
                  : available;
              final cappedTileWidth = (isTarget
                      ? rawTileWidth.clamp(200, 300)
                      : rawTileWidth.clamp(220, 360))
                  .toDouble();

              final infoTileBuilder = Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: infoTiles
                    .map((tile) => ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: cappedTileWidth,
                            maxWidth: cappedTileWidth,
                          ),
                          child: tile,
                        ))
                    .toList(growable: false),
              );

              final gaugeWidget = CompassGauge(
                value: gaugeValue,
                indeterminate: isIndeterminate,
                label: context.tr('backup.gauge.label'),
                caption: phase.caption,
                size: gaugeSize,
              );

              final spacingWidget = SizedBox(height: spacing);

              final currentFile = status.currentFile;
              final detailWidgets = <Widget>[
                if (currentFile != null && currentFile.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: spacing),
                    child: Text(
                      context.tr('backup.info.current_file',
                          params: {'file': currentFile}),
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.amber, letterSpacing: 0.4),
                    ),
                  ),
                ..._buildStatusDetails(context, status, phase),
              ];

              if (isTarget && available < compactThreshold) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: gaugeWidget),
                    spacingWidget,
                    infoTileBuilder,
                    const SizedBox(height: 20),
                    ...detailWidgets,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      gaugeWidget,
                      SizedBox(width: spacing),
                      Expanded(child: infoTileBuilder),
                    ],
                  ),
                  spacingWidget,
                  ...detailWidgets,
                ],
              );
            },
          ),
        ),
        SizedBox(height: spacing),
        SectionHeader(
          title: context.tr('backup.section.timeline'),
          subtitle: context.tr('backup.section.timeline_subtitle'),
          iconAsset: 'assets/icons/trail/trail_marker.svg',
        ),
        const SizedBox(height: 16),
        _PhaseTimeline(status: status),
        SizedBox(height: spacing),
        SectionHeader(
          title: context.tr('backup.section.mission_log'),
          subtitle: context.tr('backup.section.mission_log_subtitle'),
        ),
        const SizedBox(height: 16),
        LogEntryBanner(
          title:
              '${phase.label} // ${status.deviceLabel ?? context.tr('backup.no_source')}',
          message: missionLogMessage,
          timestamp: status.updatedAt,
        ),
        if (recoveryCard != null) ...[
          SizedBox(height: spacing),
          recoveryCard,
        ],
        SizedBox(height: spacing),
        SectionHeader(
          title: context.tr('backup.section.actions'),
          subtitle: context.tr('backup.section.actions_subtitle'),
          iconAsset: 'assets/icons/trail/trail_marker.svg',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: spacing - 4,
          runSpacing: spacing - 4,
          children: [
            FilledButton.icon(
              onPressed: status.isActive
                  ? null
                  : () {
                      triggerStart();
                    },
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(context.tr('backup.actions.start')),
            ),
            OutlinedButton.icon(
              onPressed: status.canCancel
                  ? () {
                      triggerCancel();
                    }
                  : null,
              icon: const Icon(Icons.stop_circle_rounded),
              label: Text(context.tr('backup.actions.cancel')),
            ),
            TextButton.icon(
              onPressed: () {
                ref.invalidate(backupStatusProvider);
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.tr('backup.actions.refresh')),
            ),
          ],
        ),
      ],
    );
  }
}

List<Widget> _buildStatusDetails(
    BuildContext context, BackupStatus status, _PhaseDescriptor phase) {
  final theme = Theme.of(context);
  final details = <Widget>[];

  if (status.deviceLabel != null) {
    details.add(
      _DeviceCallout(deviceLabel: status.deviceLabel!, phase: phase),
    );
  }

  if (status.message != null) {
    details.add(
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          status.message!,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.sage, height: 1.4),
        ),
      ),
    );
  }

  if (status.errors.isNotEmpty) {
    details.add(
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('backup.errors.heading'),
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: AppColors.rust)),
            const SizedBox(height: 8),
            ...status.errors.map(
              (err) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $err', style: theme.textTheme.bodySmall),
              ),
            ),
          ],
        ),
      ),
    );
  }

  if (details.isEmpty) {
    details.add(const SizedBox.shrink());
  }

  return details;
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isActive, required this.phase});

  final bool isActive;
  final _PhaseDescriptor phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.rust.withOpacity(0.8)
            : AppColors.sage.withOpacity(0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.rust, width: 1.5),
      ),
      child: Text(
        isActive
            ? context.tr('backup.status.active',
                params: {'phase': phase.label.toUpperCase()})
            : context.tr('backup.status.standby'),
        style: theme.textTheme.labelMedium?.copyWith(color: AppColors.kraft),
      ),
    );
  }
}

class _MissionBadge extends StatelessWidget {
  const _MissionBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.charcoal, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            offset: const Offset(0, 4),
            blurRadius: 12,
          ),
        ],
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: AppColors.charcoal),
      ),
    );
  }
}

class _DeviceCallout extends StatelessWidget {
  const _DeviceCallout({required this.deviceLabel, required this.phase});

  final String deviceLabel;
  final _PhaseDescriptor phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.kraft.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: phase.badgeColor.withOpacity(0.6), width: 1.4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.directions_boat_filled_outlined, color: phase.badgeColor),
          const SizedBox(width: 12),
          Text(
            context.tr('backup.device_label', params: {'device': deviceLabel}),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.kraft, letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}

enum _PhasePillState { completed, active, upcoming, error }

class _PhaseTimeline extends StatelessWidget {
  const _PhaseTimeline({required this.status});

  final BackupStatus status;

  @override
  Widget build(BuildContext context) {
    final spacing = ScreenLayout.journalSpacing(context);
    final theme = Theme.of(context);
    const phases = [
      BackupPhase.preparing,
      BackupPhase.copying,
      BackupPhase.verifying,
      BackupPhase.done,
    ];
    final currentIndex = _currentPhaseIndex(status.phase);
    final hasError = status.phase == BackupPhase.error;
    final isCancelling = status.phase == BackupPhase.cancelling;

    return JournalCard(
      padding: ScreenLayout.journalPadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: phases.map((phase) {
              final index = phases.indexOf(phase);
              final pillState =
                  _resolvePhaseState(phase, index, currentIndex, status);
              final descriptor = _describePhase(context, phase);
              return _PhasePill(
                label: descriptor.label,
                caption: descriptor.caption,
                icon: _phaseIcon(phase),
                state: pillState,
              );
            }).toList(growable: false),
          ),
          if (hasError || isCancelling) ...[
            SizedBox(height: spacing),
            Text(
              hasError
                  ? context.tr('backup.phase.error_caption')
                  : context.tr('backup.phase.cancelling_caption'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.rust, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _PhasePill extends StatelessWidget {
  const _PhasePill({
    required this.label,
    required this.caption,
    required this.icon,
    required this.state,
  });

  final String label;
  final String caption;
  final IconData icon;
  final _PhasePillState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTarget = ScreenLayout.isTargetSize(context);

    Color border;
    Color fill;
    Color textColor;

    switch (state) {
      case _PhasePillState.completed:
        border = AppColors.sage;
        fill = AppColors.sage.withOpacity(0.18);
        textColor = AppColors.kraft;
        break;
      case _PhasePillState.active:
        border = AppColors.amber;
        fill = AppColors.amber.withOpacity(0.2);
        textColor = AppColors.kraft;
        break;
      case _PhasePillState.error:
        border = AppColors.rust;
        fill = AppColors.rust.withOpacity(0.2);
        textColor = AppColors.kraft;
        break;
      case _PhasePillState.upcoming:
      default:
        border = AppColors.sage.withOpacity(0.5);
        fill = AppColors.charcoalAlt.withOpacity(0.6);
        textColor = AppColors.sage;
        break;
    }

    return Container(
      width: isTarget ? 220 : 240,
      padding: EdgeInsets.symmetric(
          horizontal: isTarget ? 18 : 20, vertical: isTarget ? 18 : 20),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            offset: const Offset(0, 6),
            blurRadius: 14,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: border, size: isTarget ? 22 : 24),
          SizedBox(height: isTarget ? 12 : 14),
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelLarge
                ?.copyWith(color: border, letterSpacing: 1.2),
          ),
          SizedBox(height: isTarget ? 6 : 8),
          Text(
            caption,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: textColor, height: 1.35),
          ),
        ],
      ),
    );
  }
}

Widget? _buildRecoveryCard({
  required BuildContext context,
  required BackupStatus status,
  required double spacing,
  required Future<void> Function() onRetry,
  required VoidCallback onRefresh,
}) {
  final hasError = !status.isActive &&
      (status.phase == BackupPhase.error || status.errors.isNotEmpty);
  if (!hasError) {
    return null;
  }

  final theme = Theme.of(context);
  final hint = _recoveryHint(context, status);
  final baseMessage = status.message?.isNotEmpty == true
      ? status.message!
      : hint ?? context.tr('backup.recovery.generic');

  return JournalCard(
    padding: ScreenLayout.journalPadding(context),
    heroBadge: _MissionBadge(
        text: context.tr('backup.alert.badge'), color: AppColors.rust),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('backup.recovery.title'),
            style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        Text(baseMessage,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.kraft, height: 1.4)),
        if (hint != null && hint != baseMessage) ...[
          const SizedBox(height: 8),
          Text(hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.sage, height: 1.4)),
        ],
        if (status.errors.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...status.errors.map(
            (err) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $err',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.kraft)),
            ),
          ),
        ],
        SizedBox(height: spacing),
        Wrap(
          spacing: spacing - 6,
          runSpacing: spacing - 6,
          children: [
            FilledButton.icon(
              onPressed: () {
                onRetry();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.tr('backup.recovery.retry')),
            ),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.check_circle_outline),
              label: Text(context.tr('backup.recovery.dismiss')),
            ),
          ],
        ),
      ],
    ),
  );
}

String? _recoveryHint(BuildContext context, BackupStatus status) {
  final haystack =
      ('${status.message ?? ''} ${status.errors.join(' ')}').toLowerCase();
  if (haystack.contains('no source')) {
    return context.tr('backup.recovery.hint.no_source');
  }
  if (haystack.contains('multiple')) {
    return context.tr('backup.recovery.hint.multiple_sources');
  }
  if (haystack.contains('low space')) {
    return context.tr('backup.recovery.hint.space');
  }
  if (haystack.contains('preview')) {
    return context.tr('backup.recovery.hint.preview');
  }
  if (haystack.contains('verify')) {
    return context.tr('backup.recovery.hint.verify');
  }
  return context.tr('backup.recovery.hint.generic');
}

int _currentPhaseIndex(BackupPhase phase) {
  switch (phase) {
    case BackupPhase.preparing:
      return 0;
    case BackupPhase.copying:
      return 1;
    case BackupPhase.verifying:
    case BackupPhase.cancelling:
    case BackupPhase.error:
      return 2;
    case BackupPhase.done:
      return 3;
    default:
      return -1;
  }
}

_PhasePillState _resolvePhaseState(
  BackupPhase phase,
  int index,
  int currentIndex,
  BackupStatus status,
) {
  if (status.phase == BackupPhase.error && phase == BackupPhase.verifying) {
    return _PhasePillState.error;
  }
  if (status.phase == BackupPhase.done && phase == BackupPhase.done) {
    return _PhasePillState.completed;
  }
  if (currentIndex == -1) {
    return _PhasePillState.upcoming;
  }
  if (index < currentIndex) {
    return _PhasePillState.completed;
  }
  if (index == currentIndex && status.phase != BackupPhase.done) {
    return _PhasePillState.active;
  }
  return _PhasePillState.upcoming;
}

IconData _phaseIcon(BackupPhase phase) {
  switch (phase) {
    case BackupPhase.preparing:
      return Icons.storage_rounded;
    case BackupPhase.copying:
      return Icons.sync_alt_rounded;
    case BackupPhase.verifying:
      return Icons.verified_rounded;
    case BackupPhase.done:
      return Icons.flag_rounded;
    default:
      return Icons.device_unknown;
  }
}

class ListLoadingState extends StatelessWidget {
  const ListLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: const [
        SizedBox(height: 120),
        Center(
          child: CircularProgressIndicator(
            strokeWidth: 6,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber),
          ),
        ),
      ],
    );
  }
}

class _PhaseDescriptor {
  const _PhaseDescriptor(
      {required this.label, required this.caption, required this.badgeColor});

  final String label;
  final String caption;
  final Color badgeColor;
}

_PhaseDescriptor _describePhase(BuildContext context, BackupPhase phase) {
  switch (phase) {
    case BackupPhase.preparing:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.preparing'),
        caption: context.tr('backup.phase.preparing_caption'),
        badgeColor: AppColors.sage,
      );
    case BackupPhase.copying:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.copying'),
        caption: context.tr('backup.phase.copying_caption'),
        badgeColor: AppColors.amber,
      );
    case BackupPhase.verifying:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.verifying'),
        caption: context.tr('backup.phase.verifying_caption'),
        badgeColor: AppColors.rust,
      );
    case BackupPhase.done:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.done'),
        caption: context.tr('backup.phase.done_caption'),
        badgeColor: AppColors.kraft,
      );
    case BackupPhase.error:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.error'),
        caption: context.tr('backup.phase.error_caption'),
        badgeColor: AppColors.rust,
      );
    case BackupPhase.cancelling:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.cancelling'),
        caption: context.tr('backup.phase.cancelling_caption'),
        badgeColor: AppColors.sage,
      );
    case BackupPhase.idle:
    default:
      return _PhaseDescriptor(
        label: context.tr('backup.phase.idle'),
        caption: context.tr('backup.phase.idle_caption'),
        badgeColor: AppColors.sage,
      );
  }
}

String _defaultLogMessage(BuildContext context, BackupStatus status) {
  if (status.errors.isNotEmpty) {
    final phaseLabel = _describePhase(context, status.phase).label;
    return context.tr('backup.log.issue', params: {'phase': phaseLabel});
  }
  if (status.isActive) {
    switch (status.phase) {
      case BackupPhase.preparing:
        return context.tr('backup.log.preparing');
      case BackupPhase.copying:
        return context.tr('backup.log.copying');
      case BackupPhase.verifying:
        return context.tr('backup.log.verifying');
      case BackupPhase.cancelling:
        return context.tr('backup.log.cancelling');
      default:
        break;
    }
  }
  if (status.phase == BackupPhase.done) {
    return context.tr('backup.log.done');
  }
  if (status.phase == BackupPhase.error) {
    return context.tr('backup.phase.error_caption');
  }
  return context.tr('backup.log.idle');
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final precision = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}
