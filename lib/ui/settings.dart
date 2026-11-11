import 'package:flutter/material.dart';

import '../app_name.dart';
import '../domain/medication.dart';
import '../domain/snapshot.dart';
import '../services/controller.dart';
import '../services/backup_jobs.dart';
import '../services/drive_backup.dart';
import 'catalog_settings.dart';
import 'design.dart';
import 'dose_views.dart';

class DriveAccountAvatar extends StatelessWidget {
  const DriveAccountAvatar(this.snapshot, {this.radius = 21, super.key});

  final Snapshot snapshot;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = snapshot.backupDisplayName ?? snapshot.backupAccount!;
    final photo = snapshot.backupPhotoUrl;
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: radius,
        backgroundColor: colors.primaryContainer,
        foregroundColor: colors.onPrimaryContainer,
        foregroundImage: photo == null ? null : NetworkImage(photo),
        onForegroundImageError: photo == null ? null : (_, _) {},
        child: Text((label.characters.firstOrNull ?? '?').toUpperCase()),
      ),
    );
  }
}

class SettingsView extends StatelessWidget {
  const SettingsView(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final theme = AppPalette.fromName(snapshot.theme);
    final driveAccount = snapshot.backupAccount;
    final readiness = controller.readiness;
    return AppList(
      children: [
        const PageTitle('Settings'),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Color theme',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: Space.sm),
              AppActions(
                children: [
                  for (final palette in AppPalette.values)
                    ChoiceChip(
                      label: Text(palette.label),
                      selected: palette == theme,
                      avatar: CircleAvatar(
                        backgroundColor: palette.seed,
                        radius: 8,
                      ),
                      onSelected: (_) => runAction(
                        context,
                        () => controller.setTheme(palette.name),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: driveAccount == null
                ? const LeadingIcon(Icons.cloud_outlined)
                : DriveAccountAvatar(snapshot),
            title: const Text('Google Drive'),
            subtitle: Text(
              driveAccount == null
                  ? 'Optional backup and restore'
                  : 'Connected · $driveAccount',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => DriveSettings(controller),
              ),
            ),
          ),
        ),
        SectionCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const LeadingIcon(Icons.search),
            title: const Text('Medicine catalog'),
            subtitle: ListenableBuilder(
              listenable: controller.catalog,
              builder: (context, _) {
                final catalog = controller.catalog;
                final updatedAt = catalog.info?.updatedAt;
                if (catalog.sourcePresent && updatedAt != null) {
                  return CatalogLastUpdated(updatedAt);
                }
                return Text(
                  catalog.indexing
                      ? 'Preparing medicine suggestions…'
                      : 'Offline name suggestions',
                );
              },
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => CatalogSettings(controller.catalog),
              ),
            ),
          ),
        ),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reminders', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Space.sm),
              if (!controller.reminders.supported)
                const Text('Reminder delivery is available on Android.'),
              if (readiness != null && controller.reminders.supported) ...[
                Text(
                  readiness.ready
                      ? 'Notifications and exact alarms are enabled.'
                      : 'Allow notifications and exact alarms for reminders.',
                ),
                const SizedBox(height: Space.sm),
                AppActions(
                  children: [
                    if (!readiness.notifications)
                      OutlinedButton(
                        onPressed: () => runAction(context, () async {
                          await controller.reminders.requestNotifications();
                          await controller.refresh();
                        }),
                        child: const Text('Allow notifications'),
                      ),
                    if (!readiness.exact)
                      OutlinedButton(
                        onPressed: () => runAction(
                          context,
                          controller.reminders.requestExact,
                        ),
                        child: const Text('Allow exact alarms'),
                      ),
                    if (!readiness.ready)
                      TextButton(
                        onPressed: () => runAction(context, controller.refresh),
                        child: const Text('Check again'),
                      ),
                  ],
                ),
              ],
              if (controller.reminderError != null)
                Text(controller.reminderError!),
              const Divider(),
              const Text('Tablets in a bottle'),
              OutlinedButton.icon(
                onPressed: controller.reminders.supported
                    ? () => runAction(context, controller.reminders.playSound)
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play sound'),
              ),
              const Divider(),
              const Text('Time zone follows your phone automatically.'),
            ],
          ),
        ),
      ],
    );
  }
}

class DriveSettings extends StatefulWidget {
  const DriveSettings(this.controller, {this.connectOnOpen = false, super.key});

  final AppController controller;
  final bool connectOnOpen;

  @override
  State<DriveSettings> createState() => _DriveSettingsState();
}

class _DriveSettingsState extends State<DriveSettings> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.connectOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(_connect);
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await runAction(context, action);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _connect() async {
    await widget.controller.connectDrive();
    if (mounted) await _restore(quietIfMissing: true);
  }

  Future<void> _restore({bool quietIfMissing = false}) async {
    final backup = await widget.controller.previewRestore();
    if (!mounted) return;
    if (backup == null) {
      if (!quietIfMissing) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No backup found.')));
      }
      return;
    }
    final data = widget.controller.snapshot;
    final hasLocalData = data.medicines.isNotEmpty || data.entries.isNotEmpty;
    setState(() => _busy = false);
    if (await confirm(
          context,
          'Restore this backup?',
          '${backup.medicines.length} medicines and ${backup.entries.length} dose entries · '
              '${timestamp(context, backup.dataVersion)}'
              '${hasLocalData ? '\n\nRestoring replaces the data on this device.' : ''}',
          'Restore',
        ) &&
        mounted) {
      setState(() => _busy = true);
      await widget.controller.restore(backup);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Backup restored.')));
        if (widget.connectOnOpen) Navigator.pop(context, true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(appName)),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final snapshot = controller.snapshot;
          final background = controller.backgroundBackup;
          final backgroundIsLatest =
              background != null &&
              (snapshot.lastBackupAttempt == null ||
                  background.at.isAfter(snapshot.lastBackupAttempt!));
          final error = backgroundIsLatest
              ? background.error
              : snapshot.backupError;
          final latest =
              background?.error == null &&
                  background != null &&
                  (snapshot.lastBackup == null ||
                      background.at.isAfter(snapshot.lastBackup!))
              ? background.at
              : snapshot.lastBackup;
          return AppList(
            children: [
              const PageTitle('Google Drive', subtitle: 'Backup and restore'),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!controller.drive.configured)
                      const Text(
                        'Google Drive isn’t configured for this build.',
                      )
                    else if (snapshot.backupAccount == null) ...[
                      const Text(
                        'Allow $appName to read and write backups in its private Drive folder.',
                      ),
                      const SizedBox(height: Space.sm),
                      FilledButton(
                        onPressed: _busy ? null : () => _run(_connect),
                        child: const Text('Continue with Google'),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          DriveAccountAvatar(snapshot),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Connected account',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                                Text(
                                  snapshot.backupDisplayName ??
                                      snapshot.backupAccount!,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                if (snapshot.backupDisplayName != null)
                                  Text(snapshot.backupAccount!),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Text(
                        latest == null
                            ? 'No successful backup yet'
                            : 'Last backup · ${timestamp(context, latest)}',
                      ),
                      if (error != null)
                        Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const SizedBox(height: Space.sm),
                      AppActions(
                        children: [
                          FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _run(controller.backUpNow),
                            child: const Text('Back up now'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _run(_restore),
                            child: const Text('Preview restore'),
                          ),
                          if (snapshot.backupDisplayName == null &&
                              snapshot.backupPhotoUrl == null)
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                      () => controller.connectDrive(
                                        refreshProfile: true,
                                      ),
                                    ),
                              child: const Text('Refresh profile'),
                            ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(controller.disconnectDrive),
                            child: const Text('Disconnect'),
                          ),
                        ],
                      ),
                    ],
                    if (_busy) const LinearProgressIndicator(),
                  ],
                ),
              ),
              if (snapshot.backupAccount != null)
                const Text(
                  '$appName keeps the latest backup in its private Drive folder. '
                  'Each backup can be up to ${DriveBackup.maxBackupMb} MB.',
                ),
              if (snapshot.backupAccount != null && BackupJobs.supported)
                _BackupScheduleForm(
                  controller,
                  key: ValueKey(snapshot.backupAccount),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _BackupScheduleForm extends StatefulWidget {
  const _BackupScheduleForm(this.controller, {super.key});

  final AppController controller;

  @override
  State<_BackupScheduleForm> createState() => _BackupScheduleFormState();
}

class _BackupScheduleFormState extends State<_BackupScheduleForm> {
  final _form = GlobalKey<FormState>();
  late BackupFrequency _frequency;
  late int _weekday;
  late int _minutes;
  late final TextEditingController _interval;
  bool _saving = false;
  static const days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  @override
  void initState() {
    super.initState();
    final schedule = widget.controller.snapshot.backupSchedule;
    _frequency = schedule.frequency;
    _weekday = schedule.weekday;
    _minutes = schedule.minutes;
    _interval = TextEditingController(text: schedule.interval.toString());
  }

  @override
  void dispose() {
    _interval.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Automatic backup',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: Space.sm),
          DropdownButtonFormField<BackupFrequency>(
            initialValue: _frequency,
            decoration: const InputDecoration(labelText: 'Frequency'),
            items: const [
              DropdownMenuItem(value: BackupFrequency.off, child: Text('Off')),
              DropdownMenuItem(
                value: BackupFrequency.daily,
                child: Text('Daily'),
              ),
              DropdownMenuItem(
                value: BackupFrequency.weekly,
                child: Text('Weekly'),
              ),
              DropdownMenuItem(
                value: BackupFrequency.custom,
                child: Text('Custom interval'),
              ),
            ],
            onChanged: (value) => setState(() => _frequency = value!),
          ),
          if (_frequency == BackupFrequency.weekly) ...[
            const SizedBox(height: Space.sm),
            DropdownButtonFormField<int>(
              initialValue: _weekday,
              decoration: const InputDecoration(labelText: 'Day'),
              items: [
                for (final (index, name) in days.indexed)
                  DropdownMenuItem(value: index + 1, child: Text(name)),
              ],
              onChanged: (value) => setState(() => _weekday = value!),
            ),
          ],
          if (_frequency == BackupFrequency.custom) ...[
            const SizedBox(height: Space.sm),
            TextFormField(
              controller: _interval,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Repeat every',
                suffixText: 'days',
              ),
              validator: (value) {
                final number = int.tryParse(value ?? '');
                return number == null || number < 1 || number > 365
                    ? 'Enter 1–365 days'
                    : null;
              },
            ),
          ],
          if (_frequency != BackupFrequency.off) ...[
            const SizedBox(height: Space.sm),
            TimeField(
              label: 'Preferred backup time',
              minutes: _minutes,
              onChanged: (minutes) => setState(() => _minutes = minutes),
            ),
          ],
          const SizedBox(height: Space.sm),
          OutlinedButton(
            onPressed: _saving
                ? null
                : () async {
                    if (!_form.currentState!.validate()) return;
                    setState(() => _saving = true);
                    await runAction(context, () async {
                      await widget.controller.saveBackupSchedule(
                        BackupSchedule(
                          frequency: _frequency,
                          minutes: _minutes,
                          weekday: _weekday,
                          interval: int.tryParse(_interval.text) ?? 3,
                          anchor: dayKey(DateTime.now()),
                        ),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Backup schedule saved.'),
                          ),
                        );
                      }
                    });
                    if (mounted) setState(() => _saving = false);
                  },
            child: const Text('Save backup schedule'),
          ),
        ],
      ),
    ),
  );
}
