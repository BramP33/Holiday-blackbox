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

  double get previewProgress {
    if (previewsTotal <= 0) {
      return 0.0;
    }
    return (previewsDone / previewsTotal).clamp(0.0, 1.0);
  }

  factory BackupStatus.fromJson(Map<String, dynamic> json) {
    final phase = _parsePhase(json['phase']?.toString());
    final errors = (json['errors'] as List<dynamic>? ?? [])
        .map((entry) => entry.toString())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    return BackupStatus(
      phase: phase,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
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
      previewsDone: json['previews_done'] as int? ?? 0,
      previewsTotal: json['previews_total'] as int? ?? 0,
      currentFile: json['current_file']?.toString(),
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
  );
}
