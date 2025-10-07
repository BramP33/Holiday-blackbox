class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.filename,
    required this.storedRel,
    this.originalRel,
    this.folder,
    this.kind,
    this.size,
    this.sizeDisplay,
    this.trashedAt,
    this.trashedAtDisplay,
  });

  final String id;
  final String filename;
  final String storedRel;
  final String? originalRel;
  final String? folder;
  final String? kind;
  final int? size;
  final String? sizeDisplay;
  final String? trashedAt;
  final String? trashedAtDisplay;

  factory TrashEntry.fromJson(Map<String, dynamic> json) {
    return TrashEntry(
      id: json['id']?.toString() ?? '',
      filename: json['filename']?.toString() ?? 'Unknown',
      storedRel: json['stored_rel']?.toString() ?? '',
      originalRel: json['original_rel']?.toString(),
      folder: json['folder']?.toString(),
      kind: json['kind']?.toString(),
      size: (json['size'] as num?)?.toInt(),
      sizeDisplay: json['size_display']?.toString(),
      trashedAt: json['trashed_at']?.toString(),
      trashedAtDisplay: json['trashed_at_display']?.toString(),
    );
  }

  bool get isPhoto => kind == 'photo';
  bool get isVideo => kind == 'video';
  bool get isOther => !isPhoto && !isVideo;
}
