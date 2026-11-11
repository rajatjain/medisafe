import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

import '../app_name.dart';
import '../domain/snapshot.dart';

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;
  @override
  String toString() => message;
}

class DriveBackup {
  static const maxBackupMb = 5;
  static const _maxBackupBytes = maxBackupMb * 1000000;
  static const _scope = ['https://www.googleapis.com/auth/drive.appdata'];
  static const _serverId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
  static const _iosId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static const _prefix = 'medisafe-v1-';
  static final _google = GoogleSignIn.instance;
  static Future<void>? _initialization;
  GoogleSignInAccount? _account;

  bool get configured => _serverId.isNotEmpty;
  String? get email => _account?.email;
  String? get displayName => _account?.displayName;
  String? get photoUrl => _account?.photoUrl;

  Future<void> _initialize() {
    if (!configured) {
      throw const BackupException(
        'Google Drive has not been configured for this build.',
      );
    }
    return _initialization ??= _google.initialize(
      serverClientId: _serverId,
      clientId: _iosId.isEmpty ? null : _iosId,
    );
  }

  Future<void> connect({
    bool interactive = false,
    String? expectedEmail,
  }) async {
    await _initialize();
    if (interactive) {
      try {
        final account = await _google.authenticate();
        if (expectedEmail != null && account.email != expectedEmail) {
          throw const BackupException(
            'Choose the Google account already connected to $appName.',
          );
        }
        await account.authorizationClient.authorizationForScopes(_scope) ??
            await account.authorizationClient.authorizeScopes(_scope);
        _account = account;
      } on GoogleSignInException catch (error) {
        if (error.code == GoogleSignInExceptionCode.canceled) {
          throw const BackupException(
            'Google connection canceled. Try again from Google Drive settings.',
          );
        }
        rethrow;
      }
    } else {
      _account ??= await _google.attemptLightweightAuthentication();
    }
  }

  Future<void> disconnect() async {
    if (configured) {
      await _initialize();
      await _google.signOut();
    }
    _account = null;
  }

  Future<String> _token(
    String? expectedEmail, {
    bool interactive = false,
  }) async {
    if (expectedEmail == null) {
      throw const BackupException('Connect your Google account first.');
    }
    await _initialize();
    // Android can authorize the already-connected account in a headless
    // worker. Credential Manager sign-in itself requires an Activity.
    if (_account == null && Platform.isAndroid) {
      final token = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: _scope,
                userId: null,
                email: expectedEmail,
                promptIfUnauthorized: interactive,
              ),
            ),
          );
      if (token != null) return token.accessToken;
      throw const BackupException(
        'Google Drive access expired. Reconnect your account.',
      );
    }
    await connect();
    final account = _account;
    if (account == null || account.email != expectedEmail) {
      throw const BackupException(
        'Reconnect the Google account configured for backup.',
      );
    }
    final authorization =
        await account.authorizationClient.authorizationForScopes(_scope) ??
        (interactive
            ? await account.authorizationClient.authorizeScopes(_scope)
            : null);
    if (authorization == null) {
      throw const BackupException(
        'Google Drive access expired. Reconnect your account.',
      );
    }
    return authorization.accessToken;
  }

  Future<String> _request(
    String method,
    Uri uri,
    String token, {
    String? body,
    String? contentType,
    bool ignoreMissing = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 25));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType!);
        final bytes = utf8.encode(body);
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (ignoreMissing && response.statusCode == 404) return '';
        if (response.statusCode == 403 &&
            text.contains('"storageQuotaExceeded"')) {
          throw const BackupException(
            'Google Drive storage is full. Free up space and try again.',
          );
        }
        throw BackupException(
          'Google Drive request failed (${response.statusCode}). Try again.',
        );
      }
      return text;
    } on SocketException {
      throw const BackupException(
        'Could not reach Google Drive. Check your connection.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<({String id, String name})>> _versions(String token) async {
    final files = <({String id, String name})>[];
    String? page;
    do {
      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
        'spaces': 'appDataFolder',
        'q': "name contains '$_prefix'",
        'fields': 'nextPageToken,files(id,name)',
        'pageSize': '1000',
        'pageToken': ?page,
      });
      final response =
          jsonDecode(await _request('GET', uri, token)) as Map<String, dynamic>;
      for (final file in (response['files'] as List? ?? [])) {
        final name = file['name'] as String;
        if (RegExp(r'^medisafe-v1-[0-9]{19}\.json$').hasMatch(name)) {
          files.add((id: file['id'] as String, name: name));
        }
      }
      page = response['nextPageToken'] as String?;
    } while (page != null);
    return files..sort((a, b) {
      final byName = b.name.compareTo(a.name);
      return byName == 0 ? b.id.compareTo(a.id) : byName;
    });
  }

  Future<void> _removeOlderVersions(
    List<({String id, String name})> files,
    String token,
  ) async {
    for (final older in files.skip(1)) {
      await _request(
        'DELETE',
        Uri.https('www.googleapis.com', '/drive/v3/files/${older.id}'),
        token,
        ignoreMissing: true,
      );
    }
  }

  String _name(Snapshot data) =>
      '$_prefix${data.dataVersion.microsecondsSinceEpoch.toString().padLeft(19, '0')}.json';

  Future<Snapshot?> download(String? expectedEmail) async {
    final token = await _token(expectedEmail, interactive: true);
    for (var attempt = 0; attempt < 2; attempt++) {
      final files = await _versions(token);
      if (files.isEmpty) return null;
      final newest = files.first;
      final uri = Uri.https(
        'www.googleapis.com',
        '/drive/v3/files/${newest.id}',
        {'alt': 'media'},
      );
      final data = await _request('GET', uri, token, ignoreMissing: true);
      if (data.isEmpty) continue; // Another device may have just replaced it.
      final result = Snapshot.fromJson(
        jsonDecode(data) as Map<String, dynamic>,
      );
      if (_name(result) != newest.name) {
        throw const BackupException(
          'The backup version could not be verified.',
        );
      }
      return result;
    }
    throw const BackupException(
      'The Drive backup is being updated. Try again.',
    );
  }

  Future<void> upload(
    Snapshot snapshot, {
    bool interactive = false,
    String? expectedEmail,
  }) async {
    final data = jsonEncode(snapshot.backupJson());
    if (utf8.encode(data).length > _maxBackupBytes) {
      throw const BackupException(
        'This backup exceeds $maxBackupMb MB. Your existing backup and local data are unchanged.',
      );
    }
    final token = await _token(expectedEmail, interactive: interactive);
    final files = await _versions(token);
    final name = _name(snapshot);
    if (files.isNotEmpty && files.first.name.compareTo(name) > 0) {
      throw const BackupException(
        'Drive already has a newer backup. Preview it before replacing local data.',
      );
    }
    // Clear leftovers from interrupted or simultaneous writes before creating
    // another file. Keep the newest usable backup until its replacement exists.
    await _removeOlderVersions(files, token);
    if (files.isNotEmpty && files.first.name == name) return;
    // Each write is a complete snapshot. Selecting the newest version avoids an
    // older upload replacing a newer one if two devices write concurrently.
    final boundary = 'medisafe_${DateTime.now().microsecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
    });
    final body =
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n--$boundary\r\nContent-Type: application/json\r\n\r\n'
        '$data\r\n--$boundary--\r\n';
    await _request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': 'id',
      }),
      token,
      body: body,
      contentType: 'multipart/related; boundary=$boundary',
    );
    try {
      await _removeOlderVersions(await _versions(token), token);
    } on Exception {
      // The replacement exists. Retry cleanup before the next upload.
    }
  }
}
