import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../domain/medication.dart';
import '../domain/snapshot.dart';
import 'drive_backup.dart';
import 'local_store.dart';

@pragma('vm:entry-point')
void backupDispatcher() {
  Workmanager().executeTask((_, input) async {
    final account = input?['account'] as String?;
    if (account == null) return true;
    final snapshot = await LocalStore().load();
    if (snapshot.backupAccount != account ||
        snapshot.backupSchedule.frequency == BackupFrequency.off) {
      return true;
    }
    final signature = jsonEncode(snapshot.backupSchedule.toJson());
    if (input?['schedule'] != signature) return true;
    final now = DateTime.now();
    String? error;
    try {
      final events = await BackupJobs.readReminderEvents();
      var changed = false;
      for (final entry in events) {
        if (!snapshot.entries.containsKey(entry.id)) {
          snapshot.entries[entry.id] = entry;
          changed = true;
        }
      }
      if (changed) {
        final latest = events
            .map((entry) => entry.recordedAt)
            .fold(snapshot.dataVersion, (a, b) => a.isAfter(b) ? a : b);
        snapshot.dataVersion = latest.add(const Duration(microseconds: 1));
      }
      await DriveBackup().upload(snapshot, expectedEmail: account);
    } on Exception catch (exception) {
      error = exception is BackupException
          ? exception.message
          : 'Automatic backup could not finish. Open the app and try again.';
    }
    await BackupJobs.writeResult(BackupResult(account, now, error));
    final current = await LocalStore().load();
    if (current.backupAccount == account &&
        jsonEncode(current.backupSchedule.toJson()) == signature) {
      await BackupJobs.enqueue(current);
    }
    return true;
  });
}

class BackupResult {
  const BackupResult(this.account, this.at, this.error);

  final String account;
  final DateTime at;
  final String? error;
}

class BackupJobs {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const _tag = 'medisafe-auto-backup';

  static Future<void> initialize() async {
    if (supported) await Workmanager().initialize(backupDispatcher);
  }

  static Future<void> schedule(Snapshot snapshot) async {
    if (!supported) return;
    await Workmanager().cancelByTag(_tag);
    await enqueue(snapshot);
  }

  static Future<void> enqueue(Snapshot snapshot) async {
    final now = DateTime.now();
    final next = snapshot.backupSchedule.nextAfter(now);
    final account = snapshot.backupAccount;
    if (!supported || next == null || account == null) return;
    await Workmanager().registerOneOffTask(
      '$_tag-${dayKey(next)}-${snapshot.backupSchedule.minutes}',
      _tag,
      tag: _tag,
      initialDelay: next.difference(now),
      constraints: Constraints(networkType: NetworkType.connected),
      inputData: {
        'account': account,
        'schedule': jsonEncode(snapshot.backupSchedule.toJson()),
      },
    );
  }

  static Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/medisafe-backup-status.json');
  }

  static Future<List<DoseEntry>> readReminderEvents() async {
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/medisafe-reminder-state.json');
    if (!await file.exists()) return [];
    final state = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final events = state['events'] as Map<String, dynamic>? ?? {};
    return events.values
        .cast<Map<String, dynamic>>()
        .map(DoseEntry.fromJson)
        .toList();
  }

  static Future<BackupResult?> latestResult() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return BackupResult(
      data['account'] as String,
      DateTime.parse(data['at'] as String),
      data['error'] as String?,
    );
  }

  static Future<void> writeResult(BackupResult result) async {
    final file = await _file();
    final temporary = File('${file.path}.next');
    await temporary.writeAsString(
      jsonEncode({
        'account': result.account,
        'at': result.at.toUtc().toIso8601String(),
        'error': result.error,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
