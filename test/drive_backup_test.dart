import 'package:flutter_test/flutter_test.dart';
import 'package:medisafe/domain/medication.dart';
import 'package:medisafe/domain/snapshot.dart';
import 'package:medisafe/services/drive_backup.dart';

void main() {
  test(
    'oversize UTF-8 backups are rejected before requesting Drive access',
    () async {
      final snapshot = Snapshot(
        medicines: [
          Medicine(
            id: 'size-test',
            name: 'Test medicine',
            strength: '',
            instructions: '💊' * 1250000,
            frequency: Frequency.asNeeded,
            interval: 1,
            weekdays: {},
            times: [],
            startDate: DateTime.utc(2026, 11, 11),
            end: ScheduleEnd.ongoing,
          ),
        ],
      );
      await expectLater(
        DriveBackup().upload(snapshot),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            contains('exceeds 5 MB'),
          ),
        ),
      );
    },
  );
}
