import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/medication.dart';
import '../domain/snapshot.dart';

class ReminderReadiness {
  const ReminderReadiness({required this.notifications, required this.exact});

  final bool notifications;
  final bool exact;
  bool get ready => notifications && exact;
}

class ReminderGateway {
  const ReminderGateway();

  static const _channel = MethodChannel('medisafe/reminders');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> configure(Snapshot snapshot, {DateTime? resetAfter}) async {
    if (!supported) return;
    await _channel.invokeMethod<void>('configure', {
      'snapshot': jsonEncode(snapshot.backupJson()),
      'resetAfter': resetAfter?.millisecondsSinceEpoch,
      'alerts': ReminderPolicy.alertMinutes,
      'snoozes': ReminderPolicy.snoozeMinutes,
      'grace': ReminderPolicy.grace.inMinutes,
      'maxSnooze': ReminderPolicy.maxSnooze.inMinutes,
    });
  }

  Future<List<DoseEntry>> events() async {
    if (!supported) return [];
    final raw = await _channel.invokeMethod<String>('events');
    return (jsonDecode(raw ?? '[]') as List)
        .cast<Map<String, dynamic>>()
        .map(DoseEntry.fromJson)
        .toList();
  }

  Future<void> acknowledge(List<DoseEntry> entries) async {
    if (!supported || entries.isEmpty) return;
    await _channel.invokeMethod<void>(
      'acknowledge',
      entries.map((entry) => entry.id).toList(),
    );
  }

  Future<Map<String, DateTime>> snoozes() async {
    if (!supported) return {};
    final map = await _channel.invokeMapMethod<String, int>('snoozes') ?? {};
    return map.map(
      (id, epoch) => MapEntry(id, DateTime.fromMillisecondsSinceEpoch(epoch)),
    );
  }

  Future<bool> snooze(ScheduledDose dose, int minutes) async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('snooze', {
          'id': dose.id,
          'minutes': minutes,
        }) ??
        false;
  }

  Future<ReminderReadiness> readiness() async {
    if (!supported) {
      return const ReminderReadiness(notifications: false, exact: false);
    }
    final map = await _channel.invokeMapMethod<String, bool>('readiness') ?? {};
    return ReminderReadiness(
      notifications: map['notifications'] ?? false,
      exact: map['exact'] ?? false,
    );
  }

  Future<void> requestNotifications() async {
    if (supported) await _channel.invokeMethod<void>('requestNotifications');
  }

  Future<void> requestExact() async {
    if (supported) await _channel.invokeMethod<void>('requestExact');
  }

  Future<void> playSound() async {
    if (supported) await _channel.invokeMethod<void>('playSound');
  }
}
