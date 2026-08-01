import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../models/backup.dart';

class DropboxAuthService {
  // Default Client ID for OmniChat App in Dropbox Console
  static const String defaultClientId = 'm02i0u20zupvshq';

  static String _generateRandomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  static String _base64UrlEncode(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Initiates OAuth 2.0 PKCE login flow.
  /// Spawns a local HTTP server at port [port] to handle redirect callback.
  /// Launches system default browser for user authorization.
  static Future<DropboxConfig> authenticate({
    String? customClientId,
    int port = 8976,
  }) async {
    final clientId = (customClientId != null && customClientId.trim().isNotEmpty)
        ? customClientId.trim()
        : defaultClientId;

    if (clientId.isEmpty) {
      throw Exception('請先輸入 Dropbox App Key (Client ID)。您可在 https://www.dropbox.com/developers/apps 建立 App，並將 Redirect URI 設定為 http://localhost:8976/callback');
    }

    final redirectUri = 'http://localhost:$port/callback';
    final codeVerifier = _generateRandomString(64);
    final codeChallenge = _base64UrlEncode(sha256.convert(utf8.encode(codeVerifier)).bytes);

    final authorizeUrl = Uri.https('www.dropbox.com', '/oauth2/authorize', {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'token_access_type': 'offline',
    });

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
    } catch (e) {
      throw Exception('無法建立本地監聽伺服器 (Port $port 被佔用或尚未釋放): $e');
    }
    final completer = Completer<String>();

    server.listen((HttpRequest request) async {
      if (request.uri.path == '/callback') {
        final code = request.uri.queryParameters['code'];
        final error = request.uri.queryParameters['error'];

        request.response
          ..headers.contentType = ContentType.html
          ..write('''
            <!DOCTYPE html>
            <html>
            <head><title>OmniChat - Dropbox Authorization</title></head>
            <body style="font-family: system-ui, sans-serif; display: flex; height: 100vh; align-items: center; justify-content: center; background: #f4f4f9;">
              <div style="text-align: center; background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.1);">
                <h2 style="color: #0061FE;">OmniChat</h2>
                <p style="font-size: 16px; color: #333;">${code != null ? 'Authorization successful! You can close this window and return to OmniChat.' : 'Authorization failed: ' + (error ?? 'Unknown error')}</p>
              </div>
            </body>
            </html>
          ''');
        await request.response.close();

        if (code != null) {
          if (!completer.isCompleted) completer.complete(code);
        } else {
          if (!completer.isCompleted) completer.completeError(Exception('Authorization failed: $error'));
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });

    try {
      if (await canLaunchUrl(authorizeUrl)) {
        await launchUrl(authorizeUrl, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not launch browser for URL: $authorizeUrl');
      }

      final authCode = await completer.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => throw TimeoutException('Dropbox authorization timed out.'),
      );

      final tokenUri = Uri.https('api.dropboxapi.com', '/oauth2/token');
      final res = await http.post(
        tokenUri,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'code': authCode,
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'code_verifier': codeVerifier,
        },
      );

      if (res.statusCode != 200) {
        throw Exception('Failed to obtain token from Dropbox (${res.statusCode}): ${res.body}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final accessToken = json['access_token'] as String;
      final refreshToken = (json['refresh_token'] as String?) ?? '';
      final expiresIn = (json['expires_in'] as int?) ?? 14400;
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60));

      String email = '';
      String name = '';
      try {
        final accInfo = await getAccountInfo(accessToken);
        email = accInfo['email'] ?? '';
        name = accInfo['name'] ?? '';
      } catch (_) {}

      return DropboxConfig(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        clientId: clientId,
        accountEmail: email,
        accountName: name,
        includeChats: true,
        includeFiles: true,
      );
    } finally {
      await server.close(force: true);
    }
  }

  /// Refreshes the access token using the refresh token if available.
  static Future<DropboxConfig> refreshAccessToken(DropboxConfig cfg) async {
    if (cfg.refreshToken.isEmpty) return cfg;

    final clientId = cfg.clientId.isNotEmpty ? cfg.clientId : defaultClientId;
    final tokenUri = Uri.https('api.dropboxapi.com', '/oauth2/token');

    final res = await http.post(
      tokenUri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': cfg.refreshToken,
        'client_id': clientId,
      },
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to refresh Dropbox token (${res.statusCode}): ${res.body}');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final newAccessToken = json['access_token'] as String;
    final expiresIn = (json['expires_in'] as int?) ?? 14400;
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60));

    return cfg.copyWith(
      accessToken: newAccessToken,
      expiresAt: expiresAt,
    );
  }

  /// Fetches account info for the current token.
  static Future<Map<String, String>> getAccountInfo(String accessToken) async {
    final uri = Uri.https('api.dropboxapi.com', '/2/users/get_current_account');
    final res = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: 'null',
    ).timeout(const Duration(seconds: 30));

    if (res.statusCode == 200) {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final email = (json['email'] as String?) ?? '';
      final nameObj = json['name'] as Map<String, dynamic>?;
      final displayName = (nameObj?['display_name'] as String?) ?? '';
      return {'email': email, 'name': displayName};
    }
    throw Exception('Failed to get account info (${res.statusCode}): ${res.body}');
  }
}
