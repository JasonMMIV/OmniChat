import 'dart:convert';

enum RestoreMode {
  overwrite, // 完全覆盖：清空本地后恢复
  merge,     // 增量合并：智能去重
}

class WebDavConfig {
  final String url;
  final String username;
  final String password;
  final String path;
  final bool includeChats; // Hive boxes
  final bool includeFiles; // uploads/

  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.path = 'omnichat_backups',
    this.includeChats = true,
    this.includeFiles = true,
  });

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? path,
    bool? includeChats,
    bool? includeFiles,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      path: path ?? this.path,
      includeChats: includeChats ?? this.includeChats,
      includeFiles: includeFiles ?? this.includeFiles,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'password': password,
        'path': path,
        'includeChats': includeChats,
        'includeFiles': includeFiles,
      };

  static WebDavConfig fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: (json['url'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      password: (json['password'] as String?) ?? '',
      path: (json['path'] as String?)?.trim().isNotEmpty == true
          ? (json['path'] as String).trim()
          : 'omnichat_backups',
      includeChats: json['includeChats'] as bool? ?? true,
      includeFiles: json['includeFiles'] as bool? ?? true,
    );
  }

  static WebDavConfig fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return WebDavConfig.fromJson(map);
    } catch (_) {
      return const WebDavConfig();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

class DropboxConfig {
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;
  final String clientId;
  final String path;
  final String accountEmail;
  final String accountName;
  final bool includeChats;
  final bool includeFiles;

  const DropboxConfig({
    this.accessToken = '',
    this.refreshToken = '',
    this.expiresAt,
    this.clientId = '',
    this.path = 'omnichat_backups',
    this.accountEmail = '',
    this.accountName = '',
    this.includeChats = true,
    this.includeFiles = true,
  });

  bool get isConnected => accessToken.isNotEmpty || refreshToken.isNotEmpty;

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  DropboxConfig copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? clientId,
    String? path,
    String? accountEmail,
    String? accountName,
    bool? includeChats,
    bool? includeFiles,
  }) {
    return DropboxConfig(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      clientId: clientId ?? this.clientId,
      path: path ?? this.path,
      accountEmail: accountEmail ?? this.accountEmail,
      accountName: accountName ?? this.accountName,
      includeChats: includeChats ?? this.includeChats,
      includeFiles: includeFiles ?? this.includeFiles,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt?.toIso8601String(),
        'clientId': clientId,
        'path': path,
        'accountEmail': accountEmail,
        'accountName': accountName,
        'includeChats': includeChats,
        'includeFiles': includeFiles,
      };

  static DropboxConfig fromJson(Map<String, dynamic> json) {
    DateTime? exp;
    if (json['expiresAt'] != null) {
      try {
        exp = DateTime.parse(json['expiresAt'] as String);
      } catch (_) {}
    }
    return DropboxConfig(
      accessToken: (json['accessToken'] as String?)?.trim() ?? '',
      refreshToken: (json['refreshToken'] as String?)?.trim() ?? '',
      expiresAt: exp,
      clientId: (json['clientId'] as String?)?.trim() ?? '',
      path: (json['path'] as String?)?.trim().isNotEmpty == true
          ? (json['path'] as String).trim()
          : 'omnichat_backups',
      accountEmail: (json['accountEmail'] as String?) ?? '',
      accountName: (json['accountName'] as String?) ?? '',
      includeChats: json['includeChats'] as bool? ?? true,
      includeFiles: json['includeFiles'] as bool? ?? true,
    );
  }

  static DropboxConfig fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return DropboxConfig.fromJson(map);
    } catch (_) {
      return const DropboxConfig();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}


class BackupFileItem {
  final Uri href; // absolute
  final String displayName;
  final int size;
  final DateTime? lastModified;
  const BackupFileItem({
    required this.href,
    required this.displayName,
    required this.size,
    required this.lastModified,
  });
}

