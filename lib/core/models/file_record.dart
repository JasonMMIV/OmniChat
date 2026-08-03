class FileRecord {
  const FileRecord({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.createdAt,
  });

  final String path;
  final String fileName;
  final int sizeBytes;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'path': path,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'createdAt': createdAt.toIso8601String(),
  };

  factory FileRecord.fromJson(Map<String, dynamic> json) {
    return FileRecord(
      path: json['path'] as String,
      fileName: json['fileName'] as String,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}
