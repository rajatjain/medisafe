import 'medication.dart';

enum BackupFrequency { off, daily, weekly, custom }

class BackupSchedule {
  const BackupSchedule({
    this.frequency = BackupFrequency.off,
    this.minutes = 21 * 60,
    this.weekday = DateTime.sunday,
    this.interval = 3,
    this.anchor = '2026-01-01',
  });

  final BackupFrequency frequency;
  final int minutes;
  final int weekday;
  final int interval;
  final String anchor;

  DateTime? nextAfter(DateTime now) {
    if (frequency == BackupFrequency.off) return null;
    final origin = dayOnly(DateTime.parse(anchor));
    for (var i = 0; i <= (interval > 7 ? interval : 7); i++) {
      final day = dayOnly(now).add(Duration(days: i));
      final offset = day.difference(origin).inDays;
      final matches = switch (frequency) {
        BackupFrequency.off => false,
        BackupFrequency.daily => true,
        BackupFrequency.weekly => day.weekday == weekday,
        BackupFrequency.custom => offset % interval == 0,
      };
      final date = DateTime(
        day.year,
        day.month,
        day.day,
        minutes ~/ 60,
        minutes % 60,
      );
      if (matches && date.isAfter(now)) return date;
    }
    return null;
  }

  factory BackupSchedule.fromJson(Map<String, dynamic> json) => BackupSchedule(
    frequency: BackupFrequency.values.byName(json['frequency'] as String),
    minutes: json['minutes'] as int,
    weekday: json['weekday'] as int,
    interval: json['interval'] as int,
    anchor: json['anchor'] as String,
  );

  Map<String, dynamic> toJson() => {
    'frequency': frequency.name,
    'minutes': minutes,
    'weekday': weekday,
    'interval': interval,
    'anchor': anchor,
  };
}

class Snapshot {
  Snapshot({
    List<Medicine>? medicines,
    Map<String, DoseEntry>? entries,
    DateTime? dataVersion,
    this.theme = 'plum',
    this.backupSchedule = const BackupSchedule(),
    this.lastBackup,
    this.backupError,
    this.backupAccount,
    this.backupDisplayName,
    this.backupPhotoUrl,
    this.lastBackupAttempt,
    this.driveIntroSeen = false,
  }) : medicines = medicines ?? [],
       entries = entries ?? {},
       dataVersion =
           dataVersion ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final List<Medicine> medicines;
  final Map<String, DoseEntry> entries;
  DateTime dataVersion;
  String theme;
  BackupSchedule backupSchedule;
  DateTime? lastBackup;
  DateTime? lastBackupAttempt;
  String? backupError;
  String? backupAccount;
  String? backupDisplayName;
  String? backupPhotoUrl;
  bool driveIntroSeen;

  List<ScheduledDose> dosesOn(DateTime day) {
    final doses = [
      for (final medicine in medicines)
        if (medicine.occursOn(day))
          for (final time in medicine.times) ScheduledDose(medicine, day, time),
    ];
    return doses..sort((a, b) => a.time.minutes.compareTo(b.time.minutes));
  }

  factory Snapshot.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported backup format.');
    }
    final medicines = (json['medicines'] as List)
        .cast<Map<String, dynamic>>()
        .map(Medicine.fromJson)
        .toList();
    final entries = (json['entries'] as List).cast<Map<String, dynamic>>().map(
      DoseEntry.fromJson,
    );
    return Snapshot(
      medicines: medicines,
      entries: {for (final entry in entries) entry.id: entry},
      dataVersion: DateTime.parse(json['dataVersion'] as String),
      theme: json['theme'] as String? ?? 'plum',
      backupSchedule: json['backupSchedule'] == null
          ? const BackupSchedule()
          : BackupSchedule.fromJson(
              json['backupSchedule'] as Map<String, dynamic>,
            ),
      lastBackup: DateTime.tryParse(json['lastBackup'] as String? ?? ''),
      lastBackupAttempt: DateTime.tryParse(
        json['lastBackupAttempt'] as String? ?? '',
      ),
      backupError: json['backupError'] as String?,
      backupAccount: json['backupAccount'] as String?,
      backupDisplayName: json['backupDisplayName'] as String?,
      backupPhotoUrl: json['backupPhotoUrl'] as String?,
      driveIntroSeen: json['driveIntroSeen'] as bool? ?? false,
    );
  }

  Map<String, dynamic> backupJson() => {
    'schema': 1,
    'dataVersion': dataVersion.toUtc().toIso8601String(),
    'medicines': medicines.map((m) => m.toJson()).toList(),
    'entries': entries.values.map((entry) => entry.toJson()).toList(),
  };

  Map<String, dynamic> toJson() => {
    ...backupJson(),
    'theme': theme,
    'backupSchedule': backupSchedule.toJson(),
    'lastBackup': lastBackup?.toUtc().toIso8601String(),
    'lastBackupAttempt': lastBackupAttempt?.toUtc().toIso8601String(),
    'backupAccount': backupAccount,
    'backupDisplayName': backupDisplayName,
    'backupPhotoUrl': backupPhotoUrl,
    'backupError': backupError,
    'driveIntroSeen': driveIntroSeen,
  };
}
