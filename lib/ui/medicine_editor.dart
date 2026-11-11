import 'package:flutter/material.dart';

import '../domain/medication.dart';
import '../services/controller.dart';
import 'design.dart';

class MedicineEditor extends StatefulWidget {
  const MedicineEditor(this.controller, {this.medicine, super.key});

  final AppController controller;
  final Medicine? medicine;

  @override
  State<MedicineEditor> createState() => _MedicineEditorState();
}

class _TimeDraft {
  _TimeDraft([ReminderTime? time])
    : minutes = time?.minutes,
      quantity = TextEditingController(text: time?.quantity);

  int? minutes;
  final TextEditingController quantity;
}

class _MedicineEditorState extends State<MedicineEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  final _nameFocus = FocusNode();
  late final TextEditingController _strength;
  late final TextEditingController _instructions;
  late final TextEditingController _interval;
  late final TextEditingController _limit;
  late final List<_TimeDraft> _times;
  late final Set<int> _weekdays;
  late Frequency _frequency;
  late ScheduleEnd _end;
  late DateTime _start;
  DateTime? _endDate;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final m = widget.medicine;
    _name = TextEditingController(text: m?.name);
    _strength = TextEditingController(text: m?.strength);
    _instructions = TextEditingController(text: m?.instructions);
    _interval = TextEditingController(text: (m?.interval ?? 1).toString());
    _limit = TextEditingController(text: m?.dayLimit?.toString());
    _times = m == null || m.times.isEmpty
        ? [_TimeDraft()]
        : m.times.map(_TimeDraft.new).toList();
    _weekdays = {...?m?.weekdays};
    _frequency = m?.frequency ?? Frequency.daily;
    _end = m?.end ?? ScheduleEnd.ongoing;
    _start = m?.startDate ?? dayOnly(DateTime.now());
    _endDate = m?.endDate;
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    for (final field in [
      _name,
      _strength,
      _instructions,
      _interval,
      _limit,
      ..._times.map((draft) => draft.quantity),
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  String? _required(String? text) =>
      (text?.trim().isEmpty ?? true) ? 'Required' : null;

  Future<Iterable<String>> _medicineOptions(TextEditingValue value) async {
    try {
      return await widget.controller.catalog.suggest(value.text);
    } on Exception {
      return [];
    }
  }

  String? _positive(String? text) {
    final number = int.tryParse(text ?? '');
    return number == null || number < 1 || number > 36500
        ? 'Enter 1–36500'
        : null;
  }

  Future<void> _chooseDate({bool end = false}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: (end ? _endDate : _start) ?? _start,
      firstDate: end ? _start : DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (end) {
        _endDate = dayOnly(selected);
      } else {
        _start = dayOnly(selected);
        if (_endDate?.isBefore(_start) ?? false) _endDate = null;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    final scheduled = _frequency != Frequency.asNeeded;
    if (_name.text.trim().isEmpty ||
        (scheduled &&
            (_positive(_interval.text) != null ||
                _times.any(
                  (time) =>
                      time.minutes == null || time.quantity.text.trim().isEmpty,
                )))) {
      setState(
        () => _error =
            'Enter the medicine name, repeat interval, and every reminder time and dose.',
      );
      return;
    }
    if (_frequency == Frequency.weekly && _weekdays.isEmpty) {
      setState(() => _error = 'Choose at least one day of the week.');
      return;
    }
    if (scheduled &&
        _times.map((draft) => draft.minutes).toSet().length != _times.length) {
      setState(() => _error = 'Choose a different time for each reminder.');
      return;
    }
    if (scheduled && _end == ScheduleEnd.date && _endDate == null) {
      setState(() => _error = 'Choose an end date.');
      return;
    }
    if (scheduled &&
        _end == ScheduleEnd.scheduledDays &&
        _positive(_limit.text) != null) {
      setState(() => _error = 'Enter a valid number of scheduled days.');
      return;
    }
    setState(() => _saving = true);
    final m = widget.medicine;
    final medicine = Medicine(
      id: m?.id ?? newId(),
      name: _name.text.trim(),
      strength: _strength.text.trim(),
      instructions: _instructions.text.trim(),
      frequency: _frequency,
      interval: scheduled ? int.parse(_interval.text) : 1,
      weekdays: {..._weekdays},
      times: scheduled
          ? _times
                .map(
                  (draft) =>
                      ReminderTime(draft.minutes!, draft.quantity.text.trim()),
                )
                .toList()
          : [],
      startDate: _start,
      end: scheduled ? _end : ScheduleEnd.ongoing,
      endDate: _endDate,
      dayLimit: int.tryParse(_limit.text),
      paused: m?.paused ?? false,
      archived: m?.archived ?? false,
    );
    try {
      await widget.controller.saveMedicine(medicine);
      if (mounted) Navigator.pop(context, medicine);
    } on Exception {
      if (mounted) {
        setState(() {
          _error = 'Could not save the medicine. Try again.';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheduled = _frequency != Frequency.asNeeded;
    final date = dateLabel(context, _start);
    final weekdays = MaterialLocalizations.of(context).narrowWeekdays;
    const weekdayNames = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Medisafe')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: AppList(
            children: [
              PageTitle(
                widget.medicine == null ? 'Add medicine' : 'Edit medicine',
              ),
              Autocomplete<String>(
                textEditingController: _name,
                focusNode: _nameFocus,
                optionsBuilder: _medicineOptions,
                fieldViewBuilder: (context, controller, focus, _) =>
                    TextFormField(
                      controller: controller,
                      focusNode: focus,
                      validator: _required,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Medicine name',
                      ),
                    ),
              ),
              TextFormField(
                controller: _strength,
                decoration: const InputDecoration(
                  labelText: 'Strength (optional)',
                ),
              ),
              TextFormField(
                controller: _instructions,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Instructions (optional)',
                ),
              ),
              DropdownButtonFormField<Frequency>(
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'Reminders'),
                items: const [
                  DropdownMenuItem(
                    value: Frequency.daily,
                    child: Text('Daily'),
                  ),
                  DropdownMenuItem(
                    value: Frequency.weekly,
                    child: Text('Weekly'),
                  ),
                  DropdownMenuItem(
                    value: Frequency.asNeeded,
                    child: Text('As needed'),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _frequency = value!;
                  _error = null;
                }),
              ),
              if (scheduled) ...[
                TextFormField(
                  controller: _interval,
                  validator: _positive,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Repeat every',
                    suffixText: _frequency == Frequency.daily
                        ? 'days'
                        : 'weeks',
                  ),
                ),
                if (_frequency == Frequency.weekly)
                  AppActions(
                    children: List.generate(7, (i) {
                      final number = i + 1;
                      return Tooltip(
                        message: weekdayNames[i],
                        child: FilterChip(
                          label: Text(weekdays[number % 7]),
                          selected: _weekdays.contains(number),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _weekdays.add(number);
                            } else {
                              _weekdays.remove(number);
                            }
                          }),
                        ),
                      );
                    }),
                  ),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reminder times',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: Space.sm),
                      for (final (index, draft) in _times.indexed)
                        Padding(
                          key: ObjectKey(draft),
                          padding: const EdgeInsets.only(bottom: Space.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TimeField(
                                      label: 'Time ${index + 1} (required)',
                                      minutes: draft.minutes,
                                      onChanged: (minutes) => setState(
                                        () => draft.minutes = minutes,
                                      ),
                                    ),
                                  ),
                                  if (_times.length > 1)
                                    IconButton(
                                      tooltip: 'Remove time ${index + 1}',
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                      ),
                                      onPressed: () {
                                        setState(() => _times.remove(draft));
                                        WidgetsBinding.instance
                                            .addPostFrameCallback(
                                              (_) => draft.quantity.dispose(),
                                            );
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              TextFormField(
                                controller: draft.quantity,
                                validator: _required,
                                decoration: const InputDecoration(
                                  labelText: 'Dose quantity',
                                  hintText: 'e.g. ½ tablet',
                                ),
                              ),
                            ],
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _times.add(_TimeDraft())),
                        icon: const Icon(Icons.add),
                        label: const Text('Add time'),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _chooseDate,
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text('Start date · $date'),
                ),
                DropdownButtonFormField<ScheduleEnd>(
                  initialValue: _end,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'End schedule'),
                  items: const [
                    DropdownMenuItem(
                      value: ScheduleEnd.ongoing,
                      child: Text('Until stopped'),
                    ),
                    DropdownMenuItem(
                      value: ScheduleEnd.date,
                      child: Text('On a date'),
                    ),
                    DropdownMenuItem(
                      value: ScheduleEnd.scheduledDays,
                      child: Text('After scheduled days'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _end = value!),
                ),
                if (_end == ScheduleEnd.date)
                  OutlinedButton.icon(
                    onPressed: () => _chooseDate(end: true),
                    icon: const Icon(Icons.event),
                    label: Text(
                      _endDate == null
                          ? 'Choose last day'
                          : 'Last day · ${dateLabel(context, _endDate!)}',
                    ),
                  ),
                if (_end == ScheduleEnd.scheduledDays)
                  TextFormField(
                    controller: _limit,
                    validator: _positive,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Number of scheduled days',
                    ),
                  ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save medicine'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
