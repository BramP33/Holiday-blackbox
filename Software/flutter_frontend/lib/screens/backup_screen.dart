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
    final previewValue = status.proxyJobsTotal > 0
        ? '${status.proxyJobsDone}/${status.proxyJobsTotal}'
        : status.previewsTotal > 0
            ? '${status.previewsDone}/${status.previewsTotal}'
            : '--';
    final transcriptionValue = status.transcriptionTotal > 0
        ? '${status.transcriptionDone}/${status.transcriptionTotal}'
        : null;
    final statusMessage = status.message?.isNotEmpty == true
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

    Future<void> triggerStartTranscription() async {
      final api = ref.read(apiClientProvider);
      try {
        await api.startTranscription();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Transcription started')),
          );
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content:
                  Text('Failed to start transcription: ${error.toString()}'),
            ),
          );
        }
      }
    }

    Future<void> triggerStartSsdExport() async {
      final api = ref.read(apiClientProvider);
      final offload = status.offload;
      final target = offload.target ??
          (offload.availableTargets.isNotEmpty
              ? offload.availableTargets.first
              : null);
      final mountpoint = target?.mountpoint;
      try {
        final result = await api.startSsdExport(
          mountpoint:
              mountpoint != null && mountpoint.isNotEmpty ? mountpoint : null,
        );
        if (context.mounted) {
          final payload = result['target'];
          final label = payload is Map<String, dynamic>
              ? payload['label']?.toString()
              : target?.label;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'backup.toast.export_started',
                  params: {'target': label ?? 'SSD'},
                ),
              ),
            ),
          );
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'backup.toast.export_failed',
                  params: {'error': error.toString()},
                ),
              ),
            ),
          );
        }
      } finally {
        ref.invalidate(backupStatusProvider);
      }
    }

    Future<void> triggerCancelSsdExport() async {
      final api = ref.read(apiClientProvider);
      try {
        await api.cancelSsdExport();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.tr('backup.toast.export_cancelled')),
            ),
          );
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'backup.toast.export_failed',
                  params: {'error': error.toString()},
                ),
              ),
            ),
          );
        }
      } finally {
        ref.invalidate(backupStatusProvider);
      }
    }

    final offload = status.offload;
    final hasOffloadTarget =
        offload.availableTargets.isNotEmpty || offload.target != null;
    final canStartOffload =
        hasOffloadTarget && !offload.isActive && !status.isActive;
    final canCancelOffload = offload.canCancel;
    final offloadInfoValue = _offloadStatusLabel(context, offload);

    final infoTiles = <InfoTile>[
      InfoTile(
        label: context.tr('backup.info.transfer'),
        value: manifestValue,
        icon: Icons.layers,
      ),
      InfoTile(
        label: context.tr('backup.info.data'),
        value: _formatBytes(status.bytesCopied),
        icon: Icons.sd_storage,
      ),
      InfoTile(
        label: context.tr('backup.info.eta'),
        value: status.eta ?? '--',
        icon: Icons.hourglass_bottom,
      ),
      InfoTile(
        label: context.tr('backup.info.speed'),
        value: status.speed ?? '--',
        icon: Icons.speed,
      ),
    ];
    if (offloadInfoValue != null) {
      infoTiles.add(
        InfoTile(
          label: context.tr('backup.info.offload'),
          value: offloadInfoValue,
          icon: Icons.save_alt_rounded,
        ),
      );
    }
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
          title: context.tr('backup.section.actions'),
          subtitle: context.tr('backup.section.actions_subtitle'),
          iconAsset: 'assets/icons/trail/trail_marker.svg',
        ),
        SizedBox(height: spacing),
        JournalCard(
          padding: journalPadding,
          child: Wrap(
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
              FilledButton.icon(
                onPressed: canStartOffload
                    ? () {
                        triggerStartSsdExport();
                      }
                    : null,
                icon: const Icon(Icons.save_rounded),
                label: Text(context.tr('backup.actions.export')),
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
              OutlinedButton.icon(
                onPressed: canCancelOffload
                    ? () {
                        triggerCancelSsdExport();
                      }
                    : null,
                icon: const Icon(Icons.cancel_schedule_send_rounded),
                label: Text(context.tr('backup.actions.export_cancel')),
              ),
              OutlinedButton.icon(
                onPressed: status.isActive
                    ? null
                    : () {
                        triggerStartTranscription();
                      },
                icon: const Icon(Icons.mic_rounded),
                label: const Text('Start Transcriptie'),
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
        ),
        SizedBox(height: spacing),
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

              final proxyIndeterminate =
                  status.proxyJobsTotal <= 0 && status.proxyState == 'running';
              final transcriptionIndeterminate =
                  status.transcriptionTotal <= 0 &&
                      (status.transcriptionState == 'processing' ||
                          status.transcriptionState == 'pending');
              final gaugeConfigs = <_GaugeDescriptor>[
                _GaugeDescriptor(
                  label: context.tr('backup.gauge.label'),
                  caption: phase.caption,
                  value: _clampGaugeValue(gaugeValue),
                  indeterminate: isIndeterminate,
                ),
                _GaugeDescriptor(
                  label: context.tr('backup.gauge.proxy.label'),
                  caption: _proxyCaption(context, status),
                  value: _clampGaugeValue(status.proxyCompletion),
                  indeterminate: proxyIndeterminate,
                ),
                _GaugeDescriptor(
                  label: context.tr('backup.gauge.transcription.label'),
                  caption: _transcriptionCaption(context, status),
                  value: _clampGaugeValue(status.transcriptionCompletion),
                  indeterminate: transcriptionIndeterminate,
                ),
              ];
              final gaugeCount = gaugeConfigs.length;
              final safeWidth =
                  available.isFinite ? available : ScreenLayout.targetWidth;
              final gaugeSize = ScreenLayout.gaugeSizeForWidth(
                gaugeCount > 0 ? safeWidth / gaugeCount : safeWidth,
              );
              final gaugeWrap = Wrap(
                spacing: spacing,
                runSpacing: spacing,
                alignment: WrapAlignment.start,
                children: gaugeConfigs
                    .map(
                      (config) => SizedBox(
                        width: gaugeSize,
                        child: CompassGauge(
                          value: config.value,
                          indeterminate: config.indeterminate,
                          label: config.label,
                          caption: config.caption,
                          size: gaugeSize,
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
              final gaugeCluster = Align(
                alignment: Alignment.centerLeft,
                child: gaugeWrap,
              );

              final spacingWidget = SizedBox(height: spacing);
              final detailWidgets = _buildStatusDetails(
                context,
                status,
                phase,
                statusMessage: statusMessage,
                previewValue: previewValue,
                transcriptionValue: transcriptionValue,
              );
              final offloadMessage = offload.message?.trim();
              final combinedDetails = <Widget>[
                ...detailWidgets,
                if (offloadMessage != null && offloadMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      context.tr(
                        'backup.info.offload_message',
                        params: {'message': offloadMessage},
                      ),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.sage, height: 1.3),
                    ),
                  ),
              ];

              if (isTarget && available < compactThreshold) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    gaugeCluster,
                    spacingWidget,
                    infoTileBuilder,
                    const SizedBox(height: 20),
                    ...combinedDetails,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        flex: gaugeCount,
                        child: gaugeCluster,
                      ),
                      SizedBox(width: spacing),
                      Expanded(child: infoTileBuilder),
                    ],
                  ),
                  spacingWidget,
                  ...combinedDetails,
                ],
              );
            },
          ),
        ),
        if (recoveryCard != null) ...[
          SizedBox(height: spacing),
          recoveryCard,
        ],
      ],
    );
  }
}

List<Widget> _buildStatusDetails(
  BuildContext context,
  BackupStatus status,
  _PhaseDescriptor phase, {
  required String statusMessage,
  required String previewValue,
  String? transcriptionValue,
}) {
  final theme = Theme.of(context);
  final details = <Widget>[
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.charcoalAlt.withOpacity(0.65),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: phase.badgeColor.withOpacity(0.4), width: 1.2),
      ),
      child: Text(
        statusMessage,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: AppColors.kraft, height: 1.4),
      ),
    ),
  ];

  final currentFile = status.currentFile;
  if (currentFile != null && currentFile.isNotEmpty) {
    details.add(
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          context.tr('backup.info.current_file', params: {'file': currentFile}),
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: AppColors.amber, letterSpacing: 0.4),
        ),
      ),
    );
  }

  if (previewValue != '--') {
    details.add(
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_rounded, color: AppColors.sage, size: 18),
            const SizedBox(width: 8),
            Text(
              "${context.tr('backup.info.preview')}: $previewValue",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.sage, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }

  if (transcriptionValue != null) {
    final extras = <String>[];
    if (status.transcriptionPending > 0) {
      extras.add(
        context.tr('backup.info.transcription_pending',
            params: {'count': status.transcriptionPending.toString()}),
      );
    }
    if (status.transcriptionProcessing > 0) {
      extras.add(
        context.tr('backup.info.transcription_processing',
            params: {'count': status.transcriptionProcessing.toString()}),
      );
    }
    if (status.transcriptionError > 0) {
      extras.add(
        context.tr('backup.info.transcription_error',
            params: {'count': status.transcriptionError.toString()}),
      );
    }
    final suffix = extras.isEmpty ? '' : ' (${extras.join(' • ')})';
    details.add(
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, color: AppColors.sage, size: 18),
            const SizedBox(width: 8),
            Text(
              "${context.tr('backup.info.transcription')}: $transcriptionValue$suffix",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.sage, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }

  if (status.deviceLabel != null) {
    details.add(
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: _DeviceCallout(deviceLabel: status.deviceLabel!, phase: phase),
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

  return details;
}

double _clampGaugeValue(double value) {
  if (value.isNaN || value.isInfinite) {
    return 0.0;
  }
  return value.clamp(0.0, 1.0).toDouble();
}

class _GaugeDescriptor {
  const _GaugeDescriptor({
    required this.label,
    required this.value,
    this.caption,
    this.indeterminate = false,
  });

  final String label;
  final double value;
  final String? caption;
  final bool indeterminate;
}

String? _proxyCaption(BuildContext context, BackupStatus status) {
  final params = {
    'done': status.proxyJobsDone.toString(),
    'total':
        status.proxyJobsTotal > 0 ? status.proxyJobsTotal.toString() : '--',
  };
  return _localizedGaugeState(
    context,
    prefix: 'backup.gauge.proxy.state.',
    state: status.proxyState,
    params: params,
  );
}

String? _transcriptionCaption(BuildContext context, BackupStatus status) {
  final params = {
    'done': status.transcriptionDone.toString(),
    'total': status.transcriptionTotal > 0
        ? status.transcriptionTotal.toString()
        : '--',
    'pending': status.transcriptionPending.toString(),
    'processing': status.transcriptionProcessing.toString(),
    'error': status.transcriptionError.toString(),
  };
  return _localizedGaugeState(
    context,
    prefix: 'backup.gauge.transcription.state.',
    state: status.transcriptionState,
    params: params,
  );
}

String? _localizedGaugeState(
  BuildContext context, {
  required String prefix,
  required String state,
  required Map<String, String> params,
  Iterable<String> fallbackStates = const ['idle', 'unknown'],
}) {
  final normalized = _normalizeState(state);
  final candidates = <String>[normalized, ...fallbackStates];
  for (final candidate in candidates) {
    final key = '$prefix$candidate';
    final value = context.tr(key, params: params);
    if (value != key) {
      return value;
    }
  }
  return null;
}

String _normalizeState(String state) => state.trim().toLowerCase();

String? _offloadStatusLabel(BuildContext context, OffloadStatus offload) {
  final phase = offload.phase.trim().toLowerCase();
  switch (phase) {
    case 'copying':
      final percent = offload.progress.isNaN || offload.progress.isInfinite
          ? 0.0
          : (offload.progress * 100).clamp(0, 100);
      return context.tr(
        'backup.info.offload_copying',
        params: {'progress': percent.toStringAsFixed(0)},
      );
    case 'preparing':
      return context.tr('backup.info.offload_preparing');
    case 'cancelling':
      return context.tr('backup.info.offload_cancelling');
    case 'cancelled':
      return context.tr('backup.info.offload_cancelled');
    case 'done':
      return context.tr('backup.info.offload_done');
    case 'error':
      return context.tr('backup.info.offload_error');
  }
  if (offload.isActive) {
    return context.tr('backup.info.offload_preparing');
  }
  if (offload.hasAvailableTarget || offload.target != null) {
    return context.tr('backup.info.offload_ready');
  }
  return context.tr('backup.info.offload_unavailable');
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
