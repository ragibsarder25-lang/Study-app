import 'package:flutter/material.dart';
import 'autosave.dart';
import 'backup.dart';
import 'core.dart';
import 'extra.dart';
import 'plan_ui.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback onChanged;
  const SettingsPage({super.key, required this.onChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController intervals = TextEditingController(text: Prefs.intervals.join(', '));
  bool autoOn = false;

  @override
  void initState() {
    super.initState();
    Autosave.hasAccess().then((v) {
      if (mounted) setState(() => autoOn = v);
    });
  }

  @override
  void dispose() {
    intervals.dispose();
    super.dispose();
  }

  Future<void> _persist({bool resched = false}) async {
    await Prefs.save();
    await Extra.save();
    await Extra.applyDaily();
    if (resched) {
      await Notifier.rescheduleAll();
      await Extra.applyDaily();
    }
    widget.onChanged();
    if (mounted) setState(() {});
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _backup() async {
    try {
      await Backup.shareBackup();
    } catch (e) {
      _snack('Backup failed: $e');
    }
  }

  Future<void> _restore() async {
    final ok = await confirmDialog(context, 'Restore backup?',
        'This replaces ALL current subjects, topics, sessions and job applications with the backup.', 'Choose file');
    if (!ok) return;
    try {
      if (await Backup.restoreFromPicker()) {
        widget.onChanged();
        _snack('Backup restored');
      }
    } catch (e) {
      _snack('Restore failed: $e');
    }
  }

  Future<void> _auto() async {
    final ok = await Autosave.requestAccess();
    if (ok) await Autosave.save();
    if (mounted) setState(() => autoOn = ok);
    _snack(ok ? 'Auto-backup on' : 'File access not allowed');
  }

  Future<void> _recover() async {
    final ok = await confirmDialog(context, 'Recover from auto-backup?',
        'This replaces ALL current data with the saved copy in Documents/StudyApp.', 'Recover');
    if (!ok) return;
    try {
      await Autosave.restoreLatest();
      widget.onChanged();
      _snack('Data recovered');
    } catch (e) {
      _snack('Recover failed: $e');
    }
  }

  void _saveIntervals(String s) {
    final l = s.split(',').map((e) => int.tryParse(e.trim())).whereType<int>().where((e) => e > 0).toList();
    if (l.isEmpty) return;
    Prefs.intervals = l;
    _persist();
  }

  Widget stepper(String label, int value, int step, int min, int max, void Function(int) set) => Row(children: [
        Expanded(child: Text(label)),
        IconButton(
            onPressed: value - step >= min ? () { set(value - step); _persist(); } : null,
            icon: const Icon(Icons.remove_circle_outline)),
        Text('$value min', style: const TextStyle(fontWeight: FontWeight.w600)),
        IconButton(
            onPressed: value + step <= max ? () { set(value + step); _persist(); } : null,
            icon: const Icon(Icons.add_circle_outline)),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      pageTitle(context, 'Settings', 'Timers, adaptive rules, alarms and look'),
      Panel(
        child: Column(children: [
          stepper('Study session', Prefs.studyMin, 5, 5, 180, (v) => Prefs.studyMin = v),
          stepper('Revision session', Prefs.revisionMin, 5, 5, 120, (v) => Prefs.revisionMin = v),
        ]),
      ),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Revision intervals (days)', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: intervals,
            keyboardType: TextInputType.numberWithOptions(),
            decoration: const InputDecoration(hintText: '1, 3, 7, 14, 30, 60', border: OutlineInputBorder()),
            onChanged: _saveIntervals,
          ),
        ]),
      ),
      PlanSettings(onChanged: widget.onChanged),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(children: [
          SwitchListTile(
            title: const Text('Alarms'),
            subtitle: const Text('Notify when revisions and timers are due'),
            value: Prefs.alarms,
            onChanged: (v) {
              Prefs.alarms = v;
              _persist(resched: true);
            },
          ),
          SwitchListTile(
            title: const Text('Friday review'),
            value: Prefs.fridayReview,
            onChanged: (v) {
              Prefs.fridayReview = v;
              _persist();
            },
          ),
          SwitchListTile(
            title: const Text('Daily reminder'),
            subtitle: Text(
                'At ${Extra.reminderHour.toString().padLeft(2, '0')}:${Extra.reminderMinute.toString().padLeft(2, '0')}'),
            value: Extra.dailyReminder,
            onChanged: (v) {
              Extra.dailyReminder = v;
              _persist(resched: true);
            },
          ),
          if (Extra.dailyReminder)
            ListTile(
              title: const Text('Reminder time'),
              trailing: const Icon(Icons.access_time),
              onTap: () async {
                final t = await showTimePicker(
                    context: context, initialTime: TimeOfDay(hour: Extra.reminderHour, minute: Extra.reminderMinute));
                if (t != null) {
                  Extra.reminderHour = t.hour;
                  Extra.reminderMinute = t.minute;
                  _persist(resched: true);
                }
              },
            ),
          SwitchListTile(
            title: const Text('Missed-day alert'),
            subtitle: Text(
                'At ${Extra.nudgeHour.toString().padLeft(2, '0')}:${Extra.nudgeMinute.toString().padLeft(2, '0')} if the app was not opened that day'),
            value: Extra.nudge,
            onChanged: (v) {
              Extra.nudge = v;
              _persist();
            },
          ),
          if (Extra.nudge)
            ListTile(
              title: const Text('Missed-day alert time'),
              trailing: const Icon(Icons.access_time),
              onTap: () async {
                final t = await showTimePicker(
                    context: context, initialTime: TimeOfDay(hour: Extra.nudgeHour, minute: Extra.nudgeMinute));
                if (t != null) {
                  Extra.nudgeHour = t.hour;
                  Extra.nudgeMinute = t.minute;
                  _persist();
                }
              },
            ),
        ]),
      ),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Accent color', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(spacing: 12, children: [
            for (var i = 0; i < Extra.palette.length; i++)
              GestureDetector(
                onTap: () {
                  Extra.accent.value = i;
                  _persist();
                },
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Extra.palette[i],
                  child: Extra.accent.value == i ? const Icon(Icons.check, color: Colors.white) : null,
                ),
              ),
          ]),
        ]),
      ),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(children: [
          ListTile(
            leading: Icon(autoOn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
            title: const Text('Auto-backup'),
            subtitle: Text(autoOn
                ? 'On · Documents/StudyApp/study_data.json'
                : 'Off · tap to allow file access'),
            onTap: _auto,
          ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text('Recover from auto-backup'),
            subtitle: const Text('Use after reinstalling'),
            onTap: _recover,
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('Back up data'),
            subtitle: const Text('Share a backup file (study + jobs) to Drive, WhatsApp, etc.'),
            onTap: _backup,
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Restore from backup'),
            subtitle: const Text('Replaces everything currently in the app'),
            onTap: _restore,
          ),
        ]),
      ),
      Panel(
        onTap: () async {
          await Notifier.at(2, DateTime.now().add(const Duration(seconds: 5)), 'StudyOS – Test alarm',
              'Alarms are working.', force: true);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Test alarm in 5 seconds')));
        },
        child: const Row(children: [
          Icon(Icons.alarm),
          SizedBox(width: 12),
          Text('Send test alarm'),
        ]),
      ),
    ]);
  }
}
