import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/medication.dart';
import '../domain/snapshot.dart';
import 'backup_jobs.dart';
import 'drive_backup.dart';
import 'local_store.dart';
import 'medicine_catalog.dart';
import 'reminders.dart';

class AppController extends ChangeNotifier {
  AppController({
    LocalStore? store,
    DriveBackup? drive,
    MedicineCatalog? catalog,
  }) : _store = store ?? LocalStore(),
       drive = drive ?? DriveBackup(),
       catalog = catalog ?? MedicineCatalog();

  final LocalStore _store;
  final reminders = const ReminderGateway();
  final DriveBackup drive;
  final MedicineCatalog catalog;
  Snapshot snapshot = Snapshot();
  Map<String, DateTime> snoozes = {};
  ReminderReadiness? readiness;
  BackupResult? backgroundBackup;
  String? reminderError;
  Future<void> _tail = Future.value();

  List<ScheduledDose> get today => snapshot.dosesOn(DateTime.now());

  bool get shouldOfferDrive =>
      drive.configured &&
      snapshot.backupAccount == null &&
      !snapshot.driveIntroSeen;

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Snapshot _copy() => Snapshot.fromJson(snapshot.toJson());

  Future<void> initialize() => _serial(() async {
    snapshot = await _store.load();
    await _refreshReminders();
    await _refreshBackup();
    notifyListeners();
  });

  Future<void> refresh() => _serial(() async {
    await _refreshReminders();
    await _refreshBackup();
    notifyListeners();
  });

  Future<void> _refreshBackup() async {
    if (snapshot.backupAccount == null || !BackupJobs.supported) {
      backgroundBackup = null;
      return;
    }
    try {
      final result = await BackupJobs.latestResult();
      backgroundBackup = result?.account == snapshot.backupAccount
          ? result
          : null;
    } on Exception {
      backgroundBackup = null;
    }
  }

  Future<void> _refreshReminders({DateTime? resetAfter}) async {
    try {
      var events = <DoseEntry>[];
      if (resetAfter == null) {
        events = await reminders.events();
        final changed = events
            .where((entry) => !snapshot.entries.containsKey(entry.id))
            .toList();
        if (changed.isNotEmpty) {
          final next = _copy();
          for (final entry in changed) {
            next.entries[entry.id] = entry;
          }
          final lastEvent = changed
              .map((entry) => entry.recordedAt)
              .reduce((a, b) => a.isAfter(b) ? a : b);
          _bump(next, at: lastEvent.add(const Duration(microseconds: 1)));
          await _store.write(next);
          snapshot = next;
        }
      }
      await reminders.configure(snapshot, resetAfter: resetAfter);
      await reminders.acknowledge(events);
      snoozes = await reminders.snoozes();
      readiness = await reminders.readiness();
      reminderError = null;
    } on PlatformException {
      reminderError =
          'Could not update Android reminders. Try again from Settings.';
    }
  }

  void _bump(Snapshot next, {DateTime? at}) {
    final now = (at ?? DateTime.now()).toUtc();
    next.dataVersion = now.isAfter(next.dataVersion)
        ? now
        : next.dataVersion.add(const Duration(microseconds: 1));
  }

  Future<void> _update(
    void Function(Snapshot) change, {
    bool clinicalData = true,
    bool reschedule = true,
  }) => _serial(() async {
    final next = _copy();
    change(next);
    if (clinicalData) _bump(next);
    await _store.write(next);
    snapshot = next;
    if (reschedule) await _refreshReminders();
    notifyListeners();
  });

  Future<void> saveMedicine(Medicine medicine) => _update((data) {
    final index = data.medicines.indexWhere((item) => item.id == medicine.id);
    if (index < 0) {
      data.medicines.add(medicine);
    } else {
      data.medicines[index] = medicine;
    }
  });

  Future<void> setTheme(String name) => _update(
    (data) => data.theme = name,
    clinicalData: false,
    reschedule: false,
  );

  Future<void> dismissDriveIntro() => _update(
    (data) => data.driveIntroSeen = true,
    clinicalData: false,
    reschedule: false,
  );

  Future<void> setDose(ScheduledDose dose, DoseStatus status) =>
      _update((data) {
        final now = DateTime.now();
        data.entries[dose.id] = DoseEntry(
          id: dose.id,
          medicineId: dose.medicine.id,
          label: dose.medicine.label,
          quantity: dose.time.quantity,
          status: status,
          recordedAt: now,
          scheduledAt: dose.scheduledAt,
          takenAt: status == DoseStatus.taken ? now : null,
        );
      });

  Future<void> logDose({
    Medicine? medicine,
    DoseEntry? entry,
    required String quantity,
    required DateTime time,
  }) => _update((data) {
    final id = entry?.id ?? newId();
    data.entries[id] = DoseEntry(
      id: id,
      medicineId: entry?.medicineId ?? medicine!.id,
      label: entry?.label ?? medicine!.label,
      quantity: quantity,
      status: DoseStatus.taken,
      recordedAt: DateTime.now(),
      scheduledAt: entry?.scheduledAt,
      takenAt: time,
    );
  });

  Future<void> undo(DoseEntry entry) => _update((data) {
    data.entries.remove(entry.id);
  });

  Future<bool> snooze(ScheduledDose dose, int minutes) => _serial(() async {
    final accepted = await reminders.snooze(dose, minutes);
    snoozes = await reminders.snoozes();
    notifyListeners();
    return accepted;
  });

  Future<void> connectDrive({bool refreshProfile = false}) => _serial(() async {
    await drive.connect(
      interactive: true,
      expectedEmail: refreshProfile ? snapshot.backupAccount : null,
    );
    final account = drive.email;
    if (account == null || account.isEmpty) {
      throw const BackupException('Google sign-in was not completed.');
    }
    final next = _copy();
    if (next.backupAccount != account) {
      next.lastBackup = null;
      next.lastBackupAttempt = null;
      next.backupError = null;
      next.backupSchedule = const BackupSchedule();
    }
    next.backupAccount = account;
    final name = drive.displayName?.trim();
    next.backupDisplayName = name == null || name.isEmpty ? null : name;
    final photo = Uri.tryParse(drive.photoUrl ?? '');
    next.backupPhotoUrl =
        photo != null && photo.scheme == 'https' && photo.hasAuthority
        ? photo.toString()
        : null;
    next.driveIntroSeen = true;
    await _store.write(next);
    snapshot = next;
    notifyListeners();
    if (!refreshProfile &&
        next.backupSchedule.frequency != BackupFrequency.off) {
      await BackupJobs.schedule(next);
    }
  });

  Future<void> disconnectDrive() => _serial(() async {
    await drive.disconnect();
    final next = _copy()
      ..backupAccount = null
      ..backupDisplayName = null
      ..backupPhotoUrl = null
      ..lastBackup = null
      ..lastBackupAttempt = null
      ..backupError = null
      ..backupSchedule = const BackupSchedule();
    await _store.write(next);
    snapshot = next;
    backgroundBackup = null;
    notifyListeners();
    await BackupJobs.schedule(next);
  });

  Future<void> saveBackupSchedule(BackupSchedule schedule) => _serial(() async {
    final next = _copy()..backupSchedule = schedule;
    await _store.write(next);
    snapshot = next;
    notifyListeners();
    await BackupJobs.schedule(next);
  });

  Future<void> backUpNow() => _serial(() async {
    await _refreshReminders();
    final next = _copy()..lastBackupAttempt = DateTime.now();
    try {
      await drive.upload(
        next,
        interactive: true,
        expectedEmail: next.backupAccount,
      );
      next.lastBackup = DateTime.now();
      next.backupError = null;
    } on Exception catch (error) {
      next.backupError = error is BackupException
          ? error.message
          : 'Backup failed. Try again.';
    }
    await _store.write(next);
    snapshot = next;
    notifyListeners();
    if (next.backupError != null) throw BackupException(next.backupError!);
  });

  Future<Snapshot?> previewRestore() =>
      _serial(() => drive.download(snapshot.backupAccount));

  Future<void> restore(Snapshot backup) => _serial(() async {
    final next = _copy()
      ..medicines.clear()
      ..entries.clear()
      ..dataVersion = backup.dataVersion;
    next.medicines.addAll(backup.medicines);
    next.entries.addAll(backup.entries);
    await _store.write(next);
    snapshot = next;
    await _refreshReminders(resetAfter: DateTime.now());
    notifyListeners();
  });
}
