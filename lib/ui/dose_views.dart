import 'package:flutter/material.dart';

import '../app_name.dart';
import '../domain/medication.dart';
import '../services/controller.dart';
import 'design.dart';
import 'medicine_editor.dart';

String statusLabel(DoseStatus status) => switch (status) {
  DoseStatus.taken => 'Taken',
  DoseStatus.skipped => 'Skipped',
  DoseStatus.missed => 'Missed',
};

Future<void> runAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } on Exception catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class TodayView extends StatelessWidget {
  const TodayView(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final doses = controller.today;
    final entries = controller.snapshot.entries;
    final pending = doses
        .where((dose) => !entries.containsKey(dose.id))
        .firstOrNull;
    final otherDoses = doses.where((dose) => dose.id != pending?.id);
    final count = doses
        .where((dose) => entries[dose.id]?.status == DoseStatus.taken)
        .length;
    return AppList(
      children: [
        PageTitle(
          'Today’s doses',
          eyebrow: MaterialLocalizations.of(
            context,
          ).formatFullDate(DateTime.now()),
          subtitle: '$count of ${doses.length} taken · Local time',
        ),
        if (doses.isEmpty)
          const SectionCard(child: Text('No doses scheduled today.')),
        if (pending != null) _DoseCard(controller, pending, featured: true),
        if (otherDoses.isNotEmpty) ...[
          Text(
            pending == null ? 'Today’s schedule' : 'Other doses',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final dose in otherDoses)
            _DoseCard(controller, dose, featured: false),
        ],
      ],
    );
  }
}

class _DoseCard extends StatelessWidget {
  const _DoseCard(this.controller, this.dose, {required this.featured});

  final AppController controller;
  final ScheduledDose dose;
  final bool featured;

  Future<void> _snooze(BuildContext context) async {
    final choices = ReminderPolicy.snoozeOptions(
      dose.scheduledAt,
      DateTime.now(),
    );
    final minutes = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Snooze this dose',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: Space.sm),
              Text(
                choices.isEmpty
                    ? 'The snooze window has ended.'
                    : 'Until ${timestamp(context, dose.scheduledAt.add(ReminderPolicy.maxSnooze))} at the latest.',
              ),
              const SizedBox(height: Space.md),
              AppActions(
                children: [
                  for (final choice in choices)
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context, choice),
                      child: Text(
                        choice < 60
                            ? '$choice min'
                            : '${choice ~/ 60} ${choice == 60 ? 'hour' : 'hours'}',
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (minutes == null || !context.mounted) return;
    await runAction(context, () async {
      if (!await controller.snooze(dose, minutes)) {
        throw const FormatException('This dose can no longer be snoozed.');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = controller.snapshot.entries[dose.id];
    final snooze = controller.snoozes[dose.id];
    final now = DateTime.now();
    final canSnooze =
        controller.reminders.supported &&
        !now.isBefore(dose.scheduledAt) &&
        ReminderPolicy.snoozeOptions(dose.scheduledAt, now).isNotEmpty;
    final slot = snooze?.toLocal();
    final time = clockLabel(
      context,
      slot == null ? dose.time.minutes : slot.hour * 60 + slot.minute,
    );
    return SectionCard(
      highlight: featured,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (featured) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  snooze == null ? 'Next dose' : 'Snoozed',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                StatusPill(time),
              ],
            ),
            const SizedBox(height: Space.md),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LeadingIcon(
                entry?.status == DoseStatus.taken
                    ? Icons.check_rounded
                    : Icons.medication_outlined,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dose.medicine.label,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      featured
                          ? 'Dose · ${dose.time.quantity}'
                          : '${clockLabel(context, dose.time.minutes)} · ${dose.time.quantity}',
                    ),
                    if (featured && dose.medicine.instructions.isNotEmpty)
                      Text(dose.medicine.instructions),
                    if (entry?.takenAt != null)
                      Text('Taken ${timestamp(context, entry!.takenAt!)}'),
                  ],
                ),
              ),
              if (!featured) ...[
                const SizedBox(width: Space.sm),
                StatusPill(
                  entry != null
                      ? statusLabel(entry.status)
                      : snooze == null
                      ? 'Upcoming'
                      : 'Snoozed',
                  warning: entry?.status == DoseStatus.missed,
                  complete: entry?.status == DoseStatus.taken,
                ),
              ],
            ],
          ),
          if (featured && entry == null) ...[
            const SizedBox(height: Space.md),
            AppActions(
              children: [
                FilledButton.icon(
                  onPressed: () => runAction(
                    context,
                    () => controller.setDose(dose, DoseStatus.taken),
                  ),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Mark taken'),
                ),
                OutlinedButton(
                  onPressed: canSnooze ? () => _snooze(context) : null,
                  child: const Text('Snooze'),
                ),
                TextButton(
                  onPressed: () => runAction(
                    context,
                    () => controller.setDose(dose, DoseStatus.skipped),
                  ),
                  child: const Text('Skip'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String scheduleLabel(BuildContext context, Medicine medicine) {
  if (medicine.frequency == Frequency.asNeeded) return 'As needed';
  final days = medicine.weekdays.toList()..sort();
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final interval = medicine.interval;
  final cadence = switch (medicine.frequency) {
    Frequency.daily => interval == 1 ? 'Daily' : 'Every $interval days',
    Frequency.weekly => interval == 1 ? 'Weekly' : 'Every $interval weeks',
    Frequency.asNeeded => 'As needed',
  };
  return [
    if (medicine.archived) 'Stopped' else if (medicine.paused) 'Paused',
    cadence,
    if (medicine.frequency == Frequency.weekly)
      days.map((d) => names[d - 1]).join(', '),
    medicine.times.map((time) => clockLabel(context, time.minutes)).join(', '),
  ].join(' · ');
}

class MedicinesView extends StatelessWidget {
  const MedicinesView(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final medicines = controller.snapshot.medicines;
    return AppList(
      children: [
        const PageTitle('Medicines'),
        FilledButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add medicine'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<Medicine>(
              builder: (_) => MedicineEditor(controller),
            ),
          ),
        ),
        if (medicines.isEmpty)
          const SectionCard(
            child: Text(
              'Add a medicine to set reminders or log doses as needed.',
            ),
          ),
        for (final medicine in medicines)
          SectionCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const LeadingIcon(Icons.medication_outlined),
              title: Text(medicine.label),
              subtitle: Text(scheduleLabel(context, medicine)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MedicineDetail(controller, medicine.id),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class MedicineDetail extends StatelessWidget {
  const MedicineDetail(this.controller, this.id, {super.key});

  final AppController controller;
  final String id;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final medicine = controller.snapshot.medicines
          .where((m) => m.id == id)
          .firstOrNull;
      return Scaffold(
        appBar: AppBar(title: const Text(appName)),
        body: SafeArea(
          child: medicine == null
              ? const Center(child: Text('Medicine unavailable'))
              : AppList(
                  children: [
                    PageTitle(
                      medicine.name,
                      subtitle: medicine.strength.isEmpty
                          ? null
                          : medicine.strength,
                    ),
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Schedule',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: Space.sm),
                          Text(scheduleLabel(context, medicine)),
                          if (medicine.instructions.isNotEmpty)
                            Text(medicine.instructions),
                          const SizedBox(height: Space.md),
                          AppActions(
                            children: [
                              OutlinedButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<Medicine>(
                                    builder: (_) => MedicineEditor(
                                      controller,
                                      medicine: medicine,
                                    ),
                                  ),
                                ),
                                child: const Text('Edit medicine'),
                              ),
                              if (medicine.frequency != Frequency.asNeeded &&
                                  !medicine.archived)
                                OutlinedButton(
                                  onPressed: () => runAction(
                                    context,
                                    () => controller.saveMedicine(
                                      medicine.withState(
                                        paused: !medicine.paused,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    medicine.paused
                                        ? 'Resume reminders'
                                        : 'Pause reminders',
                                  ),
                                ),
                              if (medicine.frequency != Frequency.asNeeded)
                                TextButton(
                                  onPressed: () async {
                                    if (medicine.archived ||
                                        await confirm(
                                          context,
                                          'Stop this schedule?',
                                          'Your dose history will still be available.',
                                          'Stop reminders',
                                        )) {
                                      if (context.mounted) {
                                        await runAction(
                                          context,
                                          () => controller.saveMedicine(
                                            medicine.withState(
                                              archived: !medicine.archived,
                                              paused: false,
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: Text(
                                    medicine.archived
                                        ? 'Restart schedule'
                                        : 'Stop reminders',
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              DoseEditor(controller, medicine: medicine),
                        ),
                      ),
                      child: const Text('Log unscheduled dose'),
                    ),
                    OutlinedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text(appName)),
                            body: SafeArea(
                              child: ListenableBuilder(
                                listenable: controller,
                                builder: (_, _) =>
                                    HistoryView(controller, medicineId: id),
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('View dose history'),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

class HistoryView extends StatelessWidget {
  const HistoryView(this.controller, {this.medicineId, super.key});

  final AppController controller;
  final String? medicineId;

  @override
  Widget build(BuildContext context) {
    final entries =
        controller.snapshot.entries.values
            .where(
              (entry) => medicineId == null || entry.medicineId == medicineId,
            )
            .toList()
          ..sort(
            (a, b) => (b.takenAt ?? b.scheduledAt ?? b.recordedAt).compareTo(
              a.takenAt ?? a.scheduledAt ?? a.recordedAt,
            ),
          );
    return AppList(
      children: [
        const PageTitle('Dose history', subtitle: 'Scheduled and actual times'),
        if (entries.isEmpty)
          const SectionCard(child: Text('No doses recorded yet.')),
        for (final entry in entries)
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '${entry.label} · ${entry.quantity}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    StatusPill(
                      statusLabel(entry.status),
                      warning: entry.status == DoseStatus.missed,
                      complete: entry.status == DoseStatus.taken,
                    ),
                  ],
                ),
                const SizedBox(height: Space.xs),
                Text(
                  entry.scheduledAt == null
                      ? 'Unscheduled'
                      : 'Scheduled ${timestamp(context, entry.scheduledAt!)}',
                ),
                if (entry.takenAt != null)
                  Text('Taken ${timestamp(context, entry.takenAt!)}'),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => DoseEditor(controller, entry: entry),
                    ),
                  ),
                  child: Text(
                    entry.status == DoseStatus.taken
                        ? 'Edit time'
                        : 'Log as taken',
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class DoseEditor extends StatefulWidget {
  const DoseEditor(this.controller, {this.medicine, this.entry, super.key});

  final AppController controller;
  final Medicine? medicine;
  final DoseEntry? entry;

  @override
  State<DoseEditor> createState() => _DoseEditorState();
}

class _DoseEditorState extends State<DoseEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _quantity;
  late DateTime _day;
  late int _time;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = (widget.entry?.takenAt ?? DateTime.now()).toLocal();
    _day = dayOnly(initial);
    _time = initial.hour * 60 + initial.minute;
    _quantity = TextEditingController(text: widget.entry?.quantity);
  }

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(appName)),
    body: SafeArea(
      child: Form(
        key: _form,
        child: AppList(
          children: [
            PageTitle(
              widget.entry == null ? 'Log dose' : 'Update dose',
              subtitle: widget.entry?.label ?? widget.medicine?.label,
            ),
            TextFormField(
              controller: _quantity,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a quantity'
                  : null,
              decoration: const InputDecoration(labelText: 'Dose quantity'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text(dateLabel(context, _day)),
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _day,
                  firstDate: DateTime(1900),
                  lastDate: DateTime.now(),
                );
                if (date != null && mounted) {
                  setState(() => _day = dayOnly(date));
                }
              },
            ),
            TimeField(
              label: 'Time taken',
              minutes: _time,
              onChanged: (time) => setState(() => _time = time),
            ),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
                      if (!_form.currentState!.validate()) return;
                      final time = DateTime(
                        _day.year,
                        _day.month,
                        _day.day,
                        _time ~/ 60,
                        _time % 60,
                      );
                      if (time.isAfter(DateTime.now())) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Choose a time in the past.'),
                          ),
                        );
                        return;
                      }
                      setState(() => _saving = true);
                      await runAction(context, () async {
                        await widget.controller.logDose(
                          medicine: widget.medicine,
                          entry: widget.entry,
                          quantity: _quantity.text.trim(),
                          time: time,
                        );
                        if (context.mounted) Navigator.pop(context);
                      });
                      if (mounted) setState(() => _saving = false);
                    },
              child: const Text('Save dose'),
            ),
            if (widget.entry?.status == DoseStatus.taken)
              TextButton(
                onPressed: _saving
                    ? null
                    : () async {
                        if (await confirm(
                              context,
                              'Undo Taken?',
                              'Remove this Taken entry from your history.',
                              'Undo',
                            ) &&
                            context.mounted) {
                          await runAction(context, () async {
                            await widget.controller.undo(widget.entry!);
                            if (context.mounted) Navigator.pop(context);
                          });
                        }
                      },
                child: const Text('Undo Taken'),
              ),
          ],
        ),
      ),
    ),
  );
}
