import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medisafe/domain/medication.dart';
import 'package:medisafe/domain/snapshot.dart';
import 'package:medisafe/main.dart';
import 'package:medisafe/services/controller.dart';
import 'package:medisafe/services/drive_backup.dart';
import 'package:medisafe/services/local_store.dart';
import 'package:medisafe/services/medicine_catalog.dart';
import 'package:medisafe/ui/design.dart';
import 'package:medisafe/ui/dose_views.dart';
import 'package:medisafe/ui/medicine_editor.dart';
import 'package:medisafe/ui/settings.dart';

class _TestCatalog extends MedicineCatalog {
  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async =>
      query == 'crocin' ? ['Crocin Advance 500 mg oral tablet'] : [];

  void finishIndexing(DateTime at) {
    sourcePresent = true;
    info = (
      count: 1,
      license: 'Test licence',
      fingerprint: 'test',
      updatedAt: at,
    );
    notifyListeners();
  }
}

class _MemoryStore extends LocalStore {
  Snapshot saved = Snapshot();

  @override
  Future<Snapshot> load() async => Snapshot.fromJson(saved.toJson());

  @override
  Future<void> write(Snapshot snapshot) async {
    saved = Snapshot.fromJson(snapshot.toJson());
  }
}

class _TestDrive extends DriveBackup {
  _TestDrive(this.backup);

  final Snapshot backup;
  final calls = <String>[];

  @override
  bool get configured => true;

  @override
  String? get email => 'tester@example.com';

  @override
  String? get displayName => 'Medisafe Tester';

  @override
  Future<void> connect({
    bool interactive = false,
    String? expectedEmail,
  }) async {
    calls.add('connect');
  }

  @override
  Future<Snapshot?> download(String? expectedEmail) async {
    expect(expectedEmail, email);
    calls.add('download');
    return backup;
  }
}

void main() {
  test('featured card text and actions contrast with every theme tint', () {
    double contrast(Color foreground, Color background) {
      final tones = [
        foreground.computeLuminance(),
        background.computeLuminance(),
      ]..sort();
      return (tones.last + 0.05) / (tones.first + 0.05);
    }

    for (final palette in AppPalette.values) {
      for (final brightness in Brightness.values) {
        final colors = appTheme(palette, brightness).colorScheme;
        for (final color in [colors.onSurface, colors.primary]) {
          expect(
            contrast(color, colors.primaryContainer),
            greaterThanOrEqualTo(4.5),
            reason: '${palette.label} ${brightness.name}',
          );
        }
        expect(
          contrast(colors.onPrimary, colors.primary),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  testWidgets('Today shows the featured dose once', (tester) async {
    final medicine = Medicine(
      id: 'featured',
      name: 'Test reminder',
      strength: '',
      instructions: '',
      frequency: Frequency.daily,
      interval: 1,
      weekdays: {},
      times: [const ReminderTime(8 * 60, '1')],
      startDate: dayOnly(DateTime.now()),
      end: ScheduleEnd.ongoing,
    );
    final controller = AppController()
      ..snapshot = Snapshot(medicines: [medicine]);
    await tester.pumpWidget(MaterialApp(home: TodayView(controller)));
    expect(find.text('Next dose'), findsOneWidget);
    expect(find.text('Test reminder'), findsOneWidget);
    expect(find.text('Mark taken'), findsOneWidget);
    expect(find.text('Today’s schedule'), findsNothing);
  });

  testWidgets('shows medicine suggestions while Android composes a word', (
    tester,
  ) async {
    final controller = AppController(catalog: _TestCatalog());
    await tester.pumpWidget(MaterialApp(home: MedicineEditor(controller)));
    final nameField = find.byType(TextFormField).first;
    await tester.showKeyboard(nameField);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'crocin',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.pumpAndSettle();
    final suggestion = find.text('Crocin Advance 500 mg oral tablet');
    expect(suggestion, findsOneWidget);
    await tester.tap(suggestion);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(nameField).controller!.text,
      'Crocin Advance 500 mg oral tablet',
    );
  });

  testWidgets('Settings shows when the catalog finishes updating', (
    tester,
  ) async {
    final catalog = _TestCatalog();
    final controller = AppController(catalog: catalog);
    await tester.pumpWidget(MaterialApp(home: SettingsView(controller)));
    expect(find.textContaining('Last updated '), findsNothing);

    catalog.finishIndexing(DateTime(2026, 11, 11, 20, 14));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last updated '), findsOneWidget);
    await tester.tap(find.text('Medicine catalog'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last updated '), findsOneWidget);
  });

  testWidgets(
    'skipping Drive onboarding keeps the app offline on the next launch',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _MemoryStore();
      final drive = _TestDrive(Snapshot());
      await tester.pumpWidget(
        MedisafeApp(
          controller: AppController(store: store, drive: drive),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Back up with Google Drive'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Add medicine'), findsOneWidget);
      expect(store.saved.driveIntroSeen, isTrue);
      expect(drive.calls, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MedisafeApp(
          controller: AppController(store: store, drive: drive),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Back up with Google Drive'), findsNothing);
      expect(find.text('Add medicine'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('onboarding offers to restore an existing backup after consent', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final medicine = Medicine(
      id: 'restore-test',
      name: 'Test medicine',
      strength: '',
      instructions: '',
      frequency: Frequency.asNeeded,
      interval: 1,
      weekdays: {},
      times: [],
      startDate: DateTime.utc(2026, 11, 11),
      end: ScheduleEnd.ongoing,
    );
    final drive = _TestDrive(Snapshot(medicines: [medicine]));
    final store = _MemoryStore();
    await tester.pumpWidget(
      MedisafeApp(
        controller: AppController(store: store, drive: drive),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Google account'), findsNothing);
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(drive.calls, ['connect', 'download']);
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(store.saved.medicines, isEmpty);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(store.saved.medicines.single.name, medicine.name);
    expect(find.text(medicine.name), findsOneWidget);
    expect(store.saved.backupDisplayName, drive.displayName);
    expect(store.saved.backupJson().containsKey('backupDisplayName'), isFalse);
    await tester.tap(find.byTooltip('Google account'));
    await tester.pumpAndSettle();
    expect(find.text('Connected account'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Connected · ${drive.email}'), findsOneWidget);
    await tester.tap(find.text('Google Drive'));
    await tester.pumpAndSettle();
    expect(find.text('Connected account'), findsOneWidget);
    expect(find.text(drive.displayName!), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'opens offline, creates an as-needed medicine, and saves the theme',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _MemoryStore();
      final controller = AppController(store: store);
      await tester.pumpWidget(MedisafeApp(controller: controller));
      await tester.pumpAndSettle();

      final logo = find.descendant(
        of: find.byType(AppBrand),
        matching: find.byType(DecoratedBox),
      );
      Color? logoColor() =>
          (tester.widget<DecoratedBox>(logo).decoration as BoxDecoration).color;
      expect(logoColor(), AppPalette.plum.seed);
      expect(find.text('Add medicine'), findsOneWidget);
      await tester.tap(find.text('Add medicine'));
      await tester.pumpAndSettle();
      final timeLabel = find.text('Time 1 (required)');
      final timeHint = find.text('Select time');
      expect(timeHint, findsOneWidget);
      expect(
        tester.getRect(timeLabel).overlaps(tester.getRect(timeHint)),
        isFalse,
      );
      await tester.enterText(find.byType(TextFormField).first, 'Medicine A');
      await tester.tap(find.text('Daily'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('As needed').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save medicine'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save medicine'));
      await tester.pumpAndSettle();
      expect(find.text('Medicine A'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sage'));
      await tester.pumpAndSettle();

      expect(store.saved.theme, 'sage');
      expect(logoColor(), AppPalette.sage.seed);
      expect(store.saved.medicines.single.name, 'Medicine A');
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('a fresh local store reads the last saved snapshot', () async {
    final directory = Directory.systemTemp.createTempSync('medisafe_test_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/store.json');
    final store = LocalStore(file: file);
    expect((await store.load()).theme, 'plum');
    await store.write(Snapshot(theme: 'ocean'));
    await store.write(Snapshot(theme: 'terracotta'));
    expect((await LocalStore(file: file).load()).theme, 'terracotta');
    expect(await File('${file.path}.next').exists(), isFalse);
  });
}
