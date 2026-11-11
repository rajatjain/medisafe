import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

const catalogZipName = 'CommonDrugCodesForIndia_FlatFilePackage.zip';
const _catalogUrl = String.fromEnvironment('MEDISAFE_CATALOG_URL');
const _catalogPollInterval = Duration(days: 1);
const _catalogRetryInterval = Duration(minutes: 15);
const _downloadTimeout = Duration(seconds: 30);
const _maxCatalogZipBytes = 16 * 1024 * 1024;
const _maxTableBytes = 32 * 1024 * 1024;
const _maxNoticeBytes = 64 * 1024;
final _nonSearchCharacters = RegExp(r'[^a-z0-9]+');

String catalogSearchKey(String name) => name
    .toLowerCase()
    .replaceAll(RegExp('[µμ]'), 'u')
    .replaceAll(_nonSearchCharacters, ' ')
    .trim();

typedef CatalogContents = ({List<String> names, String license});

/// Reads only the names and accompanying licence from the official flat files.
CatalogContents readCatalogZip(Uint8List bytes) {
  if (bytes.length > _maxCatalogZipBytes) {
    throw const FormatException('Choose a catalog ZIP smaller than 16 MB.');
  }

  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final members = <String, ArchiveFile>{};
  const expected = {'BrandMaster.txt', 'GenericMaster.txt', 'License.txt'};
  for (final entry in archive) {
    final name = entry.name.split('/').last;
    if (!expected.contains(name)) continue;
    if (!entry.isFile || entry.isSymbolicLink || members.containsKey(name)) {
      throw const FormatException('The catalog ZIP contains invalid files.');
    }
    members[name] = entry;
  }
  if (members.length != expected.length) {
    throw const FormatException(
      'Choose the Common Drug Codes for India Flat Files ZIP.',
    );
  }

  String readMember(String name, int limit) {
    final file = members[name]!;
    if (file.size <= 0 || file.size > limit) {
      throw const FormatException('A file in the catalog has an invalid size.');
    }
    final content = file.content;
    if (content.length != file.size) {
      throw const FormatException('A file in the catalog is incomplete.');
    }
    return utf8.decode(content).replaceFirst('\uFEFF', '');
  }

  final notice = readMember('License.txt', _maxNoticeBytes).trim();
  if (notice.isEmpty) {
    throw const FormatException('The catalog licence is missing.');
  }
  final names = <String, String>{};

  void addNames(String filename, String column) {
    final lines = const LineSplitter().convert(
      readMember(filename, _maxTableBytes),
    );
    if (lines.isEmpty) {
      throw const FormatException('A medicine table is empty.');
    }
    final header = lines.first
        .split('\t')
        .map((value) => value.trim())
        .toList();
    final nameColumn = header.indexOf(column);
    if (nameColumn < 0 || !header.contains('Identifier')) {
      throw const FormatException(
        'The catalog uses an unrecognized table format.',
      );
    }
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final fields = line.split('\t');
      if (fields.length <= nameColumn) {
        throw const FormatException(
          'A medicine table contains an incomplete record.',
        );
      }
      final name = fields[nameColumn].trim();
      if (name.isNotEmpty && catalogSearchKey(name).isNotEmpty) {
        names.putIfAbsent(name.toLowerCase(), () => name);
      }
    }
  }

  addNames('BrandMaster.txt', 'Brand Name');
  addNames('GenericMaster.txt', 'Generic Name');
  if (names.isEmpty) {
    throw const FormatException(
      'No searchable medicines were found in the ZIP.',
    );
  }
  return (names: names.values.toList(), license: notice);
}

typedef CatalogInfo = ({
  int count,
  String license,
  String? fingerprint,
  DateTime? updatedAt,
});

class MedicineCatalog extends ChangeNotifier {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<Database>? _database;
  CatalogInfo? info;
  bool sourcePresent = false;
  bool indexing = false;
  String? error;
  String? downloadError;
  Completer<void>? _scan;
  DateTime? _nextDownloadAttempt;
  String? _failedFingerprint;

  Future<Database?> _open(Directory directory, {bool create = false}) async {
    final existing = _database;
    if (existing != null) return existing;
    final path = '${directory.path}/medicine-catalog.sqlite';
    if (!create && !await File(path).exists()) return null;
    final opening = _database ??= openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await _createNames(db, 'medicine_names');
        await _createNames(db, 'staged_names');
        await db.execute(
          'CREATE TABLE catalog_info (id INTEGER PRIMARY KEY, count INTEGER NOT NULL, license TEXT NOT NULL, fingerprint TEXT, updated_at INTEGER)',
        );
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await _createNames(db, 'staged_names');
          await db.execute(
            'ALTER TABLE catalog_info ADD COLUMN fingerprint TEXT',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE catalog_info ADD COLUMN updated_at INTEGER',
          );
        }
      },
    );
    try {
      return await opening;
    } on Exception {
      if (identical(_database, opening)) _database = null;
      rethrow;
    }
  }

  static Future<void> _createNames(Database db, String table) async {
    await db.execute(
      'CREATE TABLE $table (name TEXT PRIMARY KEY, lookup TEXT NOT NULL)',
    );
    await db.execute('CREATE INDEX ${table}_lookup ON $table (lookup, name)');
  }

  Future<void> checkForUpdates() async {
    if (!supported || _scan != null) return;
    final scan = _scan = Completer<void>();
    String? fingerprint;
    final previousError = error;
    final wasAvailable = sourcePresent;
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/$catalogZipName');
      if (!await file.exists()) {
        if (sourcePresent || error != null) {
          sourcePresent = false;
          error = null;
          _failedFingerprint = null;
        }
        return;
      }
      if (await file.length() > _maxCatalogZipBytes) {
        throw const FormatException('The catalog ZIP exceeds 16 MB.');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (builder.length + chunk.length > _maxCatalogZipBytes) {
          throw const FormatException('The catalog ZIP exceeds 16 MB.');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      final checksum = await Isolate.run(
        () => sha256.convert(bytes).toString(),
      );
      fingerprint = checksum;
      if (checksum == _failedFingerprint) return;

      final db = (await _open(directory, create: true))!;
      final row = (await db.query('catalog_info', where: 'id = 1')).firstOrNull;
      final updatedAt = row?['updated_at'] as int?;
      info = row == null
          ? null
          : (
              count: row['count'] as int,
              license: row['license'] as String,
              fingerprint: row['fingerprint'] as String?,
              updatedAt: updatedAt == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
            );
      sourcePresent = true;
      error = null;
      if (info?.fingerprint == checksum && updatedAt != null) return;

      final contents = await Isolate.run(() => readCatalogZip(bytes));
      await db.delete('staged_names');
      indexing = true;
      notifyListeners();
      await _buildIndex(db, contents, checksum);
      _failedFingerprint = null;
    } on FormatException catch (exception) {
      _failedFingerprint = fingerprint;
      error = exception.message;
    } on Exception {
      error = 'Could not read or index the catalog. The app will retry.';
    } finally {
      final wasIndexing = indexing;
      indexing = false;
      _scan = null;
      scan.complete();
      if (wasIndexing ||
          previousError != error ||
          wasAvailable != sourcePresent) {
        notifyListeners();
      }
      unawaited(_refreshDownload());
    }
  }

  Future<void> _refreshDownload() async {
    if (_catalogUrl.isEmpty ||
        (_nextDownloadAttempt?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    final previousError = downloadError;
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/$catalogZipName');
      if (await _downloadIfDue(file)) await checkForUpdates();
    } on Exception {
      downloadError =
          'Could not download the medicine catalog. The app will retry.';
    }
    if (previousError != downloadError) notifyListeners();
  }

  Future<bool> _downloadIfDue(File file) async {
    final now = DateTime.now();
    if (_nextDownloadAttempt?.isAfter(now) ?? false) return false;
    _nextDownloadAttempt = now.add(_catalogRetryInterval);
    var uri = Uri.tryParse(_catalogUrl);
    final stamp = File('${file.path}.last-check');
    if (await file.exists() && await stamp.exists()) {
      final checkedAt = await stamp.lastModified();
      if (await stamp.readAsString() == _catalogUrl &&
          checkedAt.add(_catalogPollInterval).isAfter(now)) {
        _nextDownloadAttempt = checkedAt.add(_catalogPollInterval);
        return false;
      }
    }

    final client = HttpClient()..connectionTimeout = _downloadTimeout;
    try {
      for (var redirects = 0; redirects <= 5; redirects++) {
        final target = uri;
        if (target == null ||
            target.scheme != 'https' ||
            target.host.isEmpty ||
            target.userInfo.isNotEmpty) {
          throw const FormatException('Expected an HTTPS catalog URL.');
        }
        final request = await client.getUrl(target).timeout(_downloadTimeout);
        request.followRedirects = false;
        final response = await request.close().timeout(_downloadTimeout);
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          uri = location == null ? null : target.resolve(location);
          await response.drain<void>().timeout(_downloadTimeout);
          continue;
        }
        if (response.statusCode != HttpStatus.ok ||
            response.contentLength > _maxCatalogZipBytes) {
          throw const FormatException('The catalog download is unavailable.');
        }
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(_downloadTimeout)) {
          if (buffer.length + chunk.length > _maxCatalogZipBytes) {
            throw const FormatException('The catalog ZIP exceeds 16 MB.');
          }
          buffer.add(chunk);
        }
        final bytes = buffer.takeBytes();
        await Isolate.run(() {
          readCatalogZip(bytes);
        });
        final temporary = File('${file.path}.download');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        await stamp.writeAsString(_catalogUrl, flush: true);
        _nextDownloadAttempt = DateTime.now().add(_catalogPollInterval);
        downloadError = null;
        return true;
      }
      throw const FormatException('Too many catalog download redirects.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _buildIndex(
    Database db,
    CatalogContents contents,
    String fingerprint,
  ) async {
    const batchSize = 750;
    final names = contents.names;
    for (var offset = 0; offset < names.length; offset += batchSize) {
      final batch = db.batch();
      for (final name in names.skip(offset).take(batchSize)) {
        batch.insert('staged_names', {
          'name': name,
          'lookup': catalogSearchKey(name),
        });
      }
      await batch.commit(noResult: true);
    }
    final updatedAt = await db.transaction((transaction) async {
      await transaction.delete('medicine_names');
      await transaction.execute(
        'INSERT INTO medicine_names SELECT name, lookup FROM staged_names',
      );
      final completedAt = DateTime.now().toUtc();
      await transaction.insert('catalog_info', {
        'id': 1,
        'count': names.length,
        'license': contents.license,
        'fingerprint': fingerprint,
        'updated_at': completedAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.delete('staged_names');
      return completedAt;
    });
    info = (
      count: names.length,
      license: contents.license,
      fingerprint: fingerprint,
      updatedAt: updatedAt,
    );
  }

  Future<List<String>> suggest(String query, {int limit = 8}) async {
    final prefix = catalogSearchKey(query);
    if (prefix.length < 2 || limit < 1) return [];
    final matches = await _lookup(prefix, limit);
    final scan = _scan;
    if (matches.isNotEmpty || scan == null || info != null) return matches;
    await scan.future;
    return _lookup(prefix, limit);
  }

  Future<List<String>> _lookup(String prefix, int limit) async {
    if (!sourcePresent) return [];
    final db = await _database;
    if (db == null || (info == null && !indexing)) return [];
    final rows = await db.query(
      info == null ? 'staged_names' : 'medicine_names',
      columns: ['name'],
      where: 'lookup >= ? AND lookup < ?',
      whereArgs: [prefix, '$prefix~'],
      orderBy: 'lookup, name',
      limit: limit,
    );
    return rows.map((row) => row['name'] as String).toList();
  }
}
