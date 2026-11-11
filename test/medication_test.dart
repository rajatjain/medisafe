import 'package:flutter_test/flutter_test.dart';
import 'package:medisafe/domain/medication.dart';
import 'package:medisafe/domain/snapshot.dart';

Medicine sample({
  Frequency frequency = Frequency.weekly,
  int interval = 1,
  Set<int> weekdays = const {DateTime.monday, DateTime.wednesday},
  ScheduleEnd end = ScheduleEnd.ongoing,
  int? limit,
  DateTime? endDate,
}) => Medicine(
  id: 'example',
  name: 'Medicine A',
  strength: '10 mg',
  instructions: '',
  frequency: frequency,
  interval: interval,
  weekdays: weekdays,
  times: const [ReminderTime(480, '1 tablet'), ReminderTime(1200, '½ tablet')],
  startDate: DateTime.utc(2026, 11, 11),
  end: end,
  dayLimit: limit,
  endDate: endDate,
);

void main() {
  test('counts scheduled days with two doses and a partial first week', () {
    final medicine = sample(end: ScheduleEnd.scheduledDays, limit: 2);
    final data = Snapshot(medicines: [medicine]);
    expect(data.dosesOn(DateTime(2026, 11, 11)), hasLength(2));
    expect(data.dosesOn(DateTime(2026, 11, 12)), isEmpty);
    expect(
      data.dosesOn(DateTime(2026, 11, 16)).map((dose) => dose.time.quantity),
      ['1 tablet', '½ tablet'],
    );
    expect(data.dosesOn(DateTime(2026, 11, 18)), isEmpty);
  });

  test('every four weeks is a 28-day schedule', () {
    final medicine = sample(interval: 4, weekdays: {DateTime.wednesday});
    expect(medicine.occursOn(DateTime(2026, 11, 11)), isTrue);
    expect(medicine.occursOn(DateTime(2026, 12, 2)), isFalse);
    expect(medicine.occursOn(DateTime(2026, 12, 9)), isTrue);
    expect(medicine.occursOn(DateTime(2026, 12, 11)), isFalse);
  });

  test('end date is inclusive and paused medicines keep saved history', () {
    final medicine = sample(
      frequency: Frequency.daily,
      end: ScheduleEnd.date,
      endDate: DateTime(2026, 11, 12),
    );
    final dose = ScheduledDose(
      medicine,
      DateTime(2026, 11, 12),
      medicine.times.first,
    );
    final taken = DateTime.utc(2026, 11, 12, 8, 4);
    final data = Snapshot(
      medicines: [medicine],
      entries: {
        dose.id: DoseEntry(
          id: dose.id,
          medicineId: medicine.id,
          label: medicine.label,
          quantity: dose.time.quantity,
          status: DoseStatus.taken,
          scheduledAt: dose.scheduledAt,
          recordedAt: taken,
          takenAt: taken,
        ),
      },
    );
    expect(data.dosesOn(DateTime(2026, 11, 12)), hasLength(2));
    expect(data.dosesOn(DateTime(2026, 11, 13)), isEmpty);
    data.medicines[0] = medicine.withState(paused: true);
    final restored = Snapshot.fromJson(data.backupJson());
    expect(restored.dosesOn(DateTime(2026, 11, 12)), isEmpty);
    expect(restored.entries[dose.id]?.takenAt, taken);
  });

  test('snooze options respect the original two-hour window', () {
    final scheduled = DateTime(2026, 11, 11, 8);
    expect(
      ReminderPolicy.snoozeOptions(
        scheduled,
        scheduled.add(const Duration(seconds: 20)),
      ),
      [15, 30, 60, 120],
    );
    expect(
      ReminderPolicy.snoozeOptions(scheduled, DateTime(2026, 11, 11, 9, 15)),
      [15, 30],
    );
    expect(
      ReminderPolicy.snoozeOptions(scheduled, DateTime(2026, 11, 11, 9, 46)),
      isEmpty,
    );
  });

  test('weekly backup rolls forward after the chosen time', () {
    const schedule = BackupSchedule(
      frequency: BackupFrequency.weekly,
      weekday: DateTime.wednesday,
      minutes: 21 * 60,
    );
    expect(
      schedule.nextAfter(DateTime(2026, 11, 11, 20, 59)),
      DateTime(2026, 11, 11, 21),
    );
    expect(
      schedule.nextAfter(DateTime(2026, 11, 11, 21)),
      DateTime(2026, 11, 18, 21),
    );
  });
}
