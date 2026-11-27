import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core.dart';

/// Appearance + daily reminder settings.
class Extra {
  static const palette = <Color>[
    C.accent,
    C.cyan,
    C.blue,
    C.violet,
    C.orange,
    C.green,
  ];

  static final ValueNotifier<int> accent = ValueNotifier<int>(0);
  static bool dailyReminder = false;
  static int reminderHour = 19, reminderMinute = 0;
  static SharedPreferences? _p;

  static Color get color => palette[accent.value.clamp(0, palette.length - 1)];

  static Future<void> init() async {
    try {
      _p = await SharedPreferences.getInstance();
      accent.value = (_p!.getInt('accent') ?? 0).clamp(0, palette.length - 1);
      dailyReminder = _p!.getBool('dailyReminder') ?? false;
      reminderHour = _p!.getInt('reminderHour') ?? 19;
      reminderMinute = _p!.getInt('reminderMinute') ?? 0;
    } catch (_) {}
  }

  static Future<void> save() async {
    final p = _p;
    if (p == null) return;
    await p.setInt('accent', accent.value);
    await p.setBool('dailyReminder', dailyReminder);
    await p.setInt('reminderHour', reminderHour);
    await p.setInt('reminderMinute', reminderMinute);
  }

  /// How many days ahead reminders are scheduled (ids 3000+i daily, 3100+i Friday).
  static const horizonDays = 30;

  /// Schedules daily reminders for the next [horizonDays] days. Refreshed on every app open.
  static Future<void> applyDaily() async {
    for (var i = 0; i < horizonDays; i++) {
      await Notifier.cancel(3000 + i);
      await Notifier.cancel(3100 + i);
    }
    await Notifier.cancel(3200);
    final now = DateTime.now();
    if (dailyReminder) {
      for (var i = 0; i < horizonDays; i++) {
        final d = DateTime(now.year, now.month, now.day + i, reminderHour, reminderMinute);
        await Notifier.at(3000 + i, d, 'StudyOS – Daily reminder', 'Time to study and review your topics.', force: true);
      }
    }
    // Friday weak-topic spiral review reminder, 5 PM on each upcoming Friday.
    if (Prefs.fridayReview) {
      for (var i = 0; i < horizonDays; i++) {
        final d = DateTime(now.year, now.month, now.day + i, 17, 0);
        if (d.weekday == DateTime.friday) {
          await Notifier.at(3100 + i, d, 'StudyOS – Friday spiral review', 'Time to revisit your weak topics.');
        }
      }
    }
  }
}
