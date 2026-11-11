import 'dart:async';

import 'package:flutter/material.dart';

import 'domain/medication.dart';
import 'services/backup_jobs.dart';
import 'services/controller.dart';
import 'ui/design.dart';
import 'ui/dose_views.dart';
import 'ui/settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MedisafeApp(controller: AppController()));
}

class MedisafeApp extends StatefulWidget {
  const MedisafeApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<MedisafeApp> createState() => _MedisafeAppState();
}

class _MedisafeAppState extends State<MedisafeApp> with WidgetsBindingObserver {
  late Future<void> _load;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load = _initialize();
    _startTimer();
  }

  Future<void> _initialize() async {
    await widget.controller.initialize();
    try {
      await BackupJobs.initialize();
      await BackupJobs.enqueue(widget.controller.snapshot);
    } on Exception {
      // Offline reminders and history remain available without the backup worker.
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      await widget.controller.refresh();
    } on Exception {
      // Retry on the next refresh without replacing stored data.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      unawaited(_refresh());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final palette = AppPalette.fromName(widget.controller.snapshot.theme);
      return MaterialApp(
        title: 'Medisafe',
        theme: appTheme(palette, Brightness.light),
        darkTheme: appTheme(palette, Brightness.dark),
        debugShowCheckedModeBanner: false,
        home: FutureBuilder<void>(
          future: _load,
          builder: (context, state) {
            if (state.hasError) {
              return Scaffold(
                body: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Medisafe could not open your saved data.',
                          ),
                          TextButton(
                            onPressed: () =>
                                setState(() => _load = _initialize()),
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
            if (state.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return _Home(widget.controller);
          },
        ),
      );
    },
  );
}

class _Home extends StatefulWidget {
  const _Home(this.controller);

  final AppController controller;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late int _page = widget.controller.today.isEmpty ? 1 : 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerDriveBackup());
  }

  Future<void> _offerDriveBackup() async {
    final controller = widget.controller;
    if (!mounted || !controller.shouldOfferDrive) return;
    final connect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back up with Google Drive'),
        content: const Text(
          'Keep a copy of your medicines, schedules, and dose history in '
          'Medisafe’s private Drive folder. You can also use Medisafe offline.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue with Google'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await runAction(context, controller.dismissDriveIntro);
    if (connect != true || !mounted) return;
    final restored = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DriveSettings(controller, connectOnOpen: true),
      ),
    );
    if (restored == true && mounted) {
      setState(() => _page = controller.today.isEmpty ? 1 : 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final showReminderSetup =
        _page != 3 &&
        controller.reminders.supported &&
        (controller.readiness?.ready != true ||
            controller.reminderError != null) &&
        controller.snapshot.medicines.any(
          (medicine) =>
              medicine.frequency != Frequency.asNeeded &&
              !medicine.paused &&
              !medicine.archived,
        );
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const LeadingIcon(Icons.medication_outlined),
            const SizedBox(width: Space.sm),
            const Text('Medisafe'),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (showReminderSetup)
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Finish reminder setup'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => setState(() => _page = 3),
              ),
            Expanded(
              child: switch (_page) {
                0 => TodayView(controller),
                1 => MedicinesView(controller),
                2 => HistoryView(controller),
                _ => SettingsView(controller),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: (index) => setState(() => _page = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.medication_outlined),
            label: 'Medicines',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
