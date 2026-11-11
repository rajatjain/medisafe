import 'dart:math';

enum Frequency { daily, weekly, asNeeded }

enum ScheduleEnd { ongoing, date, scheduledDays }

enum DoseStatus { taken, skipped, missed }

DateTime dayOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

String dayKey(DateTime value) =>
    dayOnly(value).toIso8601String().split('T').first;

String newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class ReminderTime {
  const ReminderTime(this.minutes, this.quantity);

  final int minutes;
  final String quantity;

  factory ReminderTime.fromJson(Map<String, dynamic> json) =>
      ReminderTime(json['minutes'] as int, json['quantity'] as String);

  Map<String, dynamic> toJson() => {'minutes': minutes, 'quantity': quantity};
}

class Medicine {
  const Medicine({
    required this.id,
    required this.name,
    required this.strength,
    required this.instructions,
    required this.frequency,
    required this.interval,
    required this.weekdays,
    required this.times,
    required this.startDate,
    required this.end,
    this.endDate,
    this.dayLimit,
    this.paused = false,
    this.archived = false,
  });

  final String id;
  final String name;
  final String strength;
  final String instructions;
  final Frequency frequency;
  final int interval;
  final Set<int> weekdays;
  final List<ReminderTime> times;
  final DateTime startDate;
  final ScheduleEnd end;
  final DateTime? endDate;
  final int? dayLimit;
  final bool paused;
  final bool archived;

  String get label => strength.isEmpty ? name : '$name · $strength';

  Medicine withState({bool? paused, bool? archived}) => Medicine(
    id: id,
    name: name,
    strength: strength,
    instructions: instructions,
    frequency: frequency,
    interval: interval,
    weekdays: weekdays,
    times: times,
    startDate: startDate,
    end: end,
    endDate: endDate,
    dayLimit: dayLimit,
    paused: paused ?? this.paused,
    archived: archived ?? this.archived,
  );

  int? scheduledDayNumber(DateTime date) {
    final start = dayOnly(startDate);
    final day = dayOnly(date);
    final offset = day.difference(start).inDays;
    if (offset < 0 || frequency == Frequency.asNeeded || interval < 1) {
      return null;
    }
    if (frequency == Frequency.daily) {
      return offset % interval == 0 ? offset ~/ interval + 1 : null;
    }
    final mondayOffset = offset + start.weekday - 1;
    final week = mondayOffset ~/ 7;
    if (week % interval != 0 || !weekdays.contains(day.weekday)) return null;
    if (week == 0) {
      return weekdays
          .where((d) => d >= start.weekday && d <= day.weekday)
          .length;
    }
    return (week ~/ interval - 1) * weekdays.length +
        weekdays.where((d) => d >= start.weekday).length +
        weekdays.where((d) => d <= day.weekday).length;
  }

  bool occursOn(DateTime date) {
    if (paused || archived || times.isEmpty) return false;
    final number = scheduledDayNumber(date);
    if (number == null) return false;
    return switch (end) {
      ScheduleEnd.ongoing => true,
      ScheduleEnd.date => !dayOnly(date).isAfter(dayOnly(endDate!)),
      ScheduleEnd.scheduledDays => number <= dayLimit!,
    };
  }

  factory Medicine.fromJson(Map<String, dynamic> json) => Medicine(
    id: json['id'] as String,
    name: json['name'] as String,
    strength: json['strength'] as String,
    instructions: json['instructions'] as String,
    frequency: Frequency.values.byName(json['frequency'] as String),
    interval: json['interval'] as int,
    weekdays: (json['weekdays'] as List).cast<int>().toSet(),
    times: (json['times'] as List)
        .cast<Map<String, dynamic>>()
        .map(ReminderTime.fromJson)
        .toList(),
    startDate: DateTime.parse(json['startDate'] as String),
    end: ScheduleEnd.values.byName(json['end'] as String),
    endDate: json['endDate'] == null
        ? null
        : DateTime.parse(json['endDate'] as String),
    dayLimit: json['dayLimit'] as int?,
    paused: json['paused'] as bool? ?? false,
    archived: json['archived'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'strength': strength,
    'instructions': instructions,
    'frequency': frequency.name,
    'interval': interval,
    'weekdays': weekdays.toList(),
    'times': times.map((time) => time.toJson()).toList(),
    'startDate': dayKey(startDate),
    'end': end.name,
    'endDate': endDate == null ? null : dayKey(endDate!),
    'dayLimit': dayLimit,
    'paused': paused,
    'archived': archived,
  };
}

class ScheduledDose {
  const ScheduledDose(this.medicine, this.day, this.time);

  final Medicine medicine;
  final DateTime day;
  final ReminderTime time;

  String get id => '${medicine.id}/${dayKey(day)}/${time.minutes}';
  DateTime get scheduledAt => DateTime(
    day.year,
    day.month,
    day.day,
    time.minutes ~/ 60,
    time.minutes % 60,
  );
}

class DoseEntry {
  const DoseEntry({
    required this.id,
    required this.medicineId,
    required this.label,
    required this.quantity,
    required this.status,
    required this.recordedAt,
    this.scheduledAt,
    this.takenAt,
  });

  final String id;
  final String medicineId;
  final String label;
  final String quantity;
  final DoseStatus status;
  final DateTime recordedAt;
  final DateTime? scheduledAt;
  final DateTime? takenAt;

  factory DoseEntry.fromJson(Map<String, dynamic> json) => DoseEntry(
    id: json['id'] as String,
    medicineId: json['medicineId'] as String,
    label: json['label'] as String,
    quantity: json['quantity'] as String,
    status: DoseStatus.values.byName(json['status'] as String),
    recordedAt: DateTime.parse(json['recordedAt'] as String),
    scheduledAt: DateTime.tryParse(json['scheduledAt'] as String? ?? ''),
    takenAt: DateTime.tryParse(json['takenAt'] as String? ?? ''),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'medicineId': medicineId,
    'label': label,
    'quantity': quantity,
    'status': status.name,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'scheduledAt': scheduledAt?.toUtc().toIso8601String(),
    'takenAt': takenAt?.toUtc().toIso8601String(),
  };
}

class ReminderPolicy {
  static const alertMinutes = [0, 15, 30, 60];
  static const snoozeMinutes = [15, 30, 60, 120];
  static const grace = Duration(minutes: 15);
  static const maxSnooze = Duration(hours: 2);

  static List<int> snoozeOptions(DateTime scheduled, DateTime now) {
    final minute = DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch ~/ 60000 * 60000,
    );
    return snoozeMinutes
        .where(
          (minutes) => !minute
              .add(Duration(minutes: minutes))
              .isAfter(scheduled.add(maxSnooze)),
        )
        .toList();
  }
}
