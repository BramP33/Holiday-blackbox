enum BackupPhase {
  idle,
  preparing,
  copying,
  verifying,
  done,
  error,
  cancelling
}

BackupPhase _parsePhase(String? value) {
  switch (value) {
    case 'preparing':
      return BackupPhase.preparing;
    case 'copying':
      return BackupPhase.copying;
    case 'verifying':
      return BackupPhase.verifying;
    case 'done':
      return BackupPhase.done;
    case 'error':
      return BackupPhase.error;
    case 'cancelling':
      return BackupPhase.cancelling;
    default:
      return BackupPhase.idle;
  }
}

double _normalizeProgress(num? explicitValue, int done, int total) {
  final double raw;
  if (explicitValue != null) {
    raw = explicitValue.toDouble();
  } else if (total > 0) {
    raw = done / total;
  } else {
    raw = 0.0;
  }
  if (raw.isNaN || raw.isInfinite) {
    return 0.0;
  }
  final num clamped = raw.clamp(0.0, 1.0);
  return clamped.toDouble();
}

class BackupStatus {
  const BackupStatus({
    required this.phase,
    required this.progress,
    required this.copiedFiles,
    required this.totalFiles,
    required this.bytesCopied,
    required this.deviceLabel,
    required this.eta,
    required this.speed,
    required this.message,
    required this.errors,
    required this.updatedAt,
    required this.canCancel,
    required this.skippedFiles,
    required this.replacedFiles,
    required this.previewsDone,
    required this.previewsTotal,
    required this.currentFile,
    required this.proxyJobsDone,
    required this.proxyJobsTotal,
    required this.proxyProgress,
    required this.proxyState,
    required this.transcriptionTotal,
    required this.transcriptionDone,
    required this.transcriptionPending,
    required this.transcriptionProcessing,
    required this.transcriptionError,
    required this.transcriptionProgress,
    required this.transcriptionState,
    required this.transcriptionUpdatedAt,
  });

  final BackupPhase phase;
  final double progress;
  final int copiedFiles;
  final int totalFiles;
  final int bytesCopied;
  final String? deviceLabel;
  final String? eta;
  final String? speed;
  final String? message;
  final List<String> errors;
  final DateTime updatedAt;
  final bool canCancel;
  final int skippedFiles;
  final int replacedFiles;
  final int previewsDone;
  final int previewsTotal;
  final String? currentFile;
  final int proxyJobsDone;
  final int proxyJobsTotal;
  final double proxyProgress;
  final String proxyState;
  final int transcriptionTotal;
  final int transcriptionDone;
  final int transcriptionPending;
  final int transcriptionProcessing;
  final int transcriptionError;
  final double transcriptionProgress;
  final String transcriptionState;
  final DateTime? transcriptionUpdatedAt;

  bool get isActive {
    switch (phase) {
      case BackupPhase.preparing:
      case BackupPhase.copying:
      case BackupPhase.verifying:
      case BackupPhase.cancelling:
        return true;
      default:
        return false;
    }
  }

  double get previewProgress => proxyProgress;

  double get proxyCompletion => proxyProgress;

  double get transcriptionCompletion => transcriptionProgress;

  factory BackupStatus.fromJson(Map<String, dynamic> json) {
    final phase = _parsePhase(json['phase']?.toString());
    final errors = (json['errors'] as List<dynamic>? ?? [])
        .map((entry) => entry.toString())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    final rawProgress = (json['progress'] as num?)?.toDouble() ?? 0.0;
    final backupProgress = rawProgress.isNaN || rawProgress.isInfinite
        ? 0.0
        : rawProgress.clamp(0.0, 1.0).toDouble();
    final previewsDone = json['previews_done'] as int? ?? 0;
    final previewsTotal = json['previews_total'] as int? ?? 0;
    final proxyJobsDone = json['proxy_jobs_done'] as int? ?? previewsDone;
    final proxyJobsTotal = json['proxy_jobs_total'] as int? ?? previewsTotal;
    final proxyProgress = _normalizeProgress(
      json['proxy_progress'] as num?,
      proxyJobsDone,
      proxyJobsTotal,
    );
    final proxyState =
        (json['proxy_state']?.toString() ?? 'idle').trim().toLowerCase();
    final transcriptionTotal = json['transcription_total'] as int? ?? 0;
    final transcriptionDone = json['transcription_done'] as int? ?? 0;
    final transcriptionPending = json['transcription_pending'] as int? ?? 0;
    final transcriptionProcessing =
        json['transcription_processing'] as int? ?? 0;
    final transcriptionError = json['transcription_error'] as int? ?? 0;
    final transcriptionProgress = _normalizeProgress(
      json['transcription_progress'] as num?,
      transcriptionDone,
      transcriptionTotal,
    );
    final transcriptionState =
        (json['transcription_state']?.toString() ?? 'idle').trim().toLowerCase();
    final transcriptionUpdatedAt = DateTime.tryParse(
      json['transcription_updated_at']?.toString() ?? '',
    );

    return BackupStatus(
      phase: phase,
      progress: backupProgress,
      copiedFiles: json['copied_files'] as int? ?? 0,
      totalFiles: json['total_files'] as int? ?? 0,
      bytesCopied: json['bytes_copied'] as int? ?? 0,
      deviceLabel: json['device_label']?.toString(),
      eta: json['eta']?.toString(),
      speed: json['speed']?.toString(),
      message: json['message']?.toString(),
      errors: errors,
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
      canCancel: json['can_cancel'] as bool? ?? false,
      skippedFiles: json['skipped_files'] as int? ?? 0,
      replacedFiles: json['replaced_files'] as int? ?? 0,
      previewsDone: previewsDone,
      previewsTotal: previewsTotal,
      currentFile: json['current_file']?.toString(),
      proxyJobsDone: proxyJobsDone,
      proxyJobsTotal: proxyJobsTotal,
      proxyProgress: proxyProgress,
      proxyState: proxyState,
      transcriptionTotal: transcriptionTotal,
      transcriptionDone: transcriptionDone,
      transcriptionPending: transcriptionPending,
      transcriptionProcessing: transcriptionProcessing,
      transcriptionError: transcriptionError,
      transcriptionProgress: transcriptionProgress,
      transcriptionState: transcriptionState,
      transcriptionUpdatedAt: transcriptionUpdatedAt,
    );
  }

  static final empty = BackupStatus(
    phase: BackupPhase.idle,
    progress: 0,
    copiedFiles: 0,
    totalFiles: 0,
    bytesCopied: 0,
    deviceLabel: null,
    eta: null,
    speed: null,
    message: null,
    errors: <String>[],
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    canCancel: false,
    skippedFiles: 0,
    replacedFiles: 0,
    previewsDone: 0,
    previewsTotal: 0,
    currentFile: null,
    proxyJobsDone: 0,
    proxyJobsTotal: 0,
    proxyProgress: 0,
    proxyState: 'idle',
    transcriptionTotal: 0,
    transcriptionDone: 0,
    transcriptionPending: 0,
    transcriptionProcessing: 0,
    transcriptionError: 0,
    transcriptionProgress: 0,
    transcriptionState: 'idle',
    transcriptionUpdatedAt: null,
  );
}
