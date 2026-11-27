import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'extra.dart';

class C {
  static const bg = Color(0xFF0B0B0D);
  static const card = Color(0xFF151518);
  static const accent = Color(0xFF8B7CFF);
  static const cyan = Color(0xFF06B6D4);
  static const blue = Color(0xFF3B82F6);
  static const violet = Color(0xFF6C5CE7);
  static const orange = Color(0xFFFF9F43);
  static const green = Color(0xFF34D399);
}

// ───────── Settings (SharedPreferences) ─────────
class Prefs {
  static List<int> intervals = [1, 3, 7, 14, 30, 60];
  static int revisionMin = 20, studyMin = 70;
  static bool fridayReview = true, alarms = true;
  static SharedPreferences? _p;

  static Future<void> init() async {
    try {
      _p = await SharedPreferences.getInstance();
      final s = _p!.getString('intervals');
      if (s != null) {
        final l = s.split(',').map((e) => int.tryParse(e.trim())).whereType<int>().where((e) => e > 0).toList();
        if (l.isNotEmpty) intervals = l;
      }
      revisionMin = _p!.getInt('revisionMin') ?? 20;
      studyMin = _p!.getInt('studyMin') ?? 70;
      fridayReview = _p!.getBool('fridayReview') ?? true;
      alarms = _p!.getBool('alarms') ?? true;
    } catch (_) {}
  }

  static Future<void> save() async {
    final p0 = _p;
    if (p0 == null) return;
    await p0.setString('intervals', intervals.join(','));
    await p0.setInt('revisionMin', revisionMin);
    await p0.setInt('studyMin', studyMin);
    await p0.setBool('fridayReview', fridayReview);
    await p0.setBool('alarms', alarms);
  }

  static int afterNew() => intervals.first;
  static int afterRevision(int doneBefore) => intervals[math.min(doneBefore + 1, intervals.length - 1)];
}

// ───────── Alarms / notifications ─────────
// IDs: 10 = long (study) timer, 11 = short (revision) timer, 2 = test,
// 1000+topicId = topic revision alarm, 3000+ = daily reminders,
// 100000+ = job application alarms.
class Notifier {
  static final plugin = FlutterLocalNotificationsPlugin();
  static bool ready = false;

  // Revision alert per topic: 1000+id = due now (old 5000+/7000+ ids are only cleaned up).
  static Future<void> scheduleRevision(int topicId, DateTime when, String title, String subject) =>
      at(1000 + topicId, when, 'Time to revise', '$title · $subject');

  static Future<void> cancelRevision(int topicId) async {
    await cancel(1000 + topicId);
    await cancel(5000 + topicId);
    await cancel(7000 + topicId);
  }

  // Re-creates the revision alarm of one topic from its current DB state.
  static Future<void> refreshTopic(int id) async {
    await cancelRevision(id);
    final r = await AppDb.db.rawQuery(
        "SELECT t.title, t.nextRevision, t.daily, t.finished, s.name subject FROM topics t JOIN subjects s ON s.id=t.subjectId WHERE t.id=?",
        [id]);
    if (r.isEmpty) return;
    final t = r.first;
    if (flagOf(t, 'finished') || flagOf(t, 'daily')) return;
    final when = DateTime.tryParse((t['nextRevision'] as String?) ?? '');
    if (when != null) await scheduleRevision(id, when, '${t['title']}', '${t['subject']}');
  }

  // Job application alarms: 100000 + jobId*2 (+0 = evening before, +1 = morning of).
  static int _jobId(int id, int k) => 100000 + id * 2 + k;

  static Future<void> cancelJob(int id) async {
    await cancel(_jobId(id, 0));
    await cancel(_jobId(id, 1));
  }

  static Future<void> scheduleJob(int id, String title, String org, String status, DateTime? date) async {
    await cancelJob(id);
    if (date == null || status == 'Selected' || status == 'Rejected') return;
    final body = org.isEmpty ? title : '$title · $org';
    await at(_jobId(id, 0), DateTime(date.year, date.month, date.day - 1, 18, 0), '$status tomorrow', body);
    await at(_jobId(id, 1), DateTime(date.year, date.month, date.day, 8, 0), '$status today', body);
  }

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      await plugin.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      ready = true;
      try { await plugin.cancelAll(); } catch (_) {}
      await requestPermissions();
    } catch (_) {}
  }

  static Future<void> requestPermissions() async {
    try {
      final a = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await a?.requestNotificationsPermission();
      await a?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  static const _native = MethodChannel('study/alarm');

  // Native AlarmManager (setAlarmClock) + BroadcastReceiver: fires even when the app is closed.
  static Future<void> at(int id, DateTime when, String title, String body, {bool force = false}) async {
    if (!Prefs.alarms && !force) return;
    if (!when.isAfter(DateTime.now())) return;
    try {
      await _native.invokeMethod('schedule',
          {'id': id, 'when': when.millisecondsSinceEpoch, 'title': title, 'body': body});
    } catch (_) {}
  }

  static Future<void> cancel(int id) async {
    try {
      await _native.invokeMethod('cancel', {'id': id});
    } catch (_) {}
  }

  static Future<void> cancelAll() async {
    try {
      await _native.invokeMethod('cancelAll');
    } catch (_) {}
  }

  static Future<void> rescheduleAll() async {
    if (!ready) return;
    await cancelAll();
    if (!Prefs.alarms) {
      await TimerStore.rearmAll(); // timer alarms always ring, even with Alarms off
      return;
    }
    final rows = await AppDb.db.rawQuery(
        "SELECT t.id, t.title, t.nextRevision, s.name subject FROM topics t JOIN subjects s ON s.id=t.subjectId WHERE t.nextRevision IS NOT NULL AND COALESCE(t.daily,0)=0");
    for (final r in rows) {
      final when = DateTime.tryParse((r['nextRevision'] as String?) ?? '');
      if (when != null) {
        await scheduleRevision(r['id'] as int, when, '${r['title']}', '${r['subject']}');
      }
    }
    try {
      final jobs = await AppDb.db.rawQuery(
          "SELECT id, title, org, status, deadline FROM job_applications WHERE deadline IS NOT NULL");
      for (final j in jobs) {
        await scheduleJob(j['id'] as int, '${j['title']}', '${j['org'] ?? ''}', '${j['status']}',
            DateTime.tryParse('${j['deadline']}'));
      }
    } catch (_) {} // table not created yet
    await TimerStore.rearmAll();
  }
}

// ───────── Persistent timers ─────────
class ActiveTimer {
  final String slot, kind, title, subject;
  final int topicId, minutes;
  int startMs, endMs, remainingMs;
  bool running;

  ActiveTimer({
    required this.slot,
    required this.kind,
    required this.title,
    required this.subject,
    required this.topicId,
    required this.minutes,
    required this.startMs,
    required this.endMs,
    required this.remainingMs,
    required this.running,
  });

  int get totalMs => minutes * 60000;

  int leftMs([int? nowMs]) =>
      running ? math.max(0, endMs - (nowMs ?? DateTime.now().millisecondsSinceEpoch)) : remainingMs;

  Map<String, dynamic> toJson() => {
        'slot': slot,
        'kind': kind,
        'title': title,
        'subject': subject,
        'topicId': topicId,
        'minutes': minutes,
        'startMs': startMs,
        'endMs': endMs,
        'remainingMs': remainingMs,
        'running': running,
      };

  static ActiveTimer? fromJson(String s) {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return ActiveTimer(
        slot: m['slot'] as String,
        kind: m['kind'] as String,
        title: m['title'] as String,
        subject: (m['subject'] as String?) ?? '',
        topicId: (m['topicId'] as num).toInt(),
        minutes: (m['minutes'] as num).toInt(),
        startMs: (m['startMs'] as num).toInt(),
        endMs: (m['endMs'] as num).toInt(),
        remainingMs: (m['remainingMs'] as num).toInt(),
        running: m['running'] as bool,
      );
    } catch (_) {
      return null;
    }
  }
}

class TimerStore {
  static SharedPreferences? _p;
  static bool _busy = false;

  static Future<SharedPreferences> get _prefs async => _p ??= await SharedPreferences.getInstance();

  // 'new' -> long (study) slot; 'revision' and 'friday' -> short slot
  static String slotOf(String kind) => kind == 'new' ? 'long' : 'short';
  static int idOf(String slot) => slot == 'long' ? 10 : 11;

  static String notifTitle(ActiveTimer t) => t.kind == 'new'
      ? 'StudyOS – Study Session Completed'
      : (t.kind == 'friday' ? 'StudyOS – Friday Review Completed' : 'StudyOS – Revision Completed');

  static String notifBody(ActiveTimer t) => t.kind == 'new'
      ? 'Your ${t.minutes}-minute study session has finished. Time for a break!'
      : 'Your ${t.minutes}-minute ${t.kind == 'friday' ? 'review' : 'revision'} session has finished.';

  static Future<ActiveTimer?> get(String slot) async {
    final p0 = await _prefs;
    final s = p0.getString('timer_$slot');
    if (s == null) return null;
    final t = ActiveTimer.fromJson(s);
    if (t == null) {
      await p0.remove('timer_$slot');
      return null;
    }
    // Clock moved backwards while the app was closed: never exceed the full session length.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (t.running && t.endMs - now > t.totalMs + 60000) {
      t.endMs = now + t.totalMs;
      await _put(t);
      await _arm(t);
    }
    return t;
  }

  static Future<void> _put(ActiveTimer t) async {
    final p0 = await _prefs;
    await p0.setString('timer_${t.slot}', jsonEncode(t.toJson()));
  }

  static Future<void> _clear(String slot) async {
    final p0 = await _prefs;
    await p0.remove('timer_$slot');
  }

  // The alarm and the on-screen countdown both use t.endMs.
  // force: true -> timer alarms ring even when the Alarms switch is off.
  static Future<void> _arm(ActiveTimer t) async {
    await Notifier.at(
      idOf(t.slot),
      DateTime.fromMillisecondsSinceEpoch(t.endMs),
      notifTitle(t),
      notifBody(t),
      force: true,
    );
  }

  static Future<ActiveTimer> start({
    required String kind,
    required int topicId,
    required String title,
    required String subject,
    required int minutes,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final t = ActiveTimer(
      slot: slotOf(kind),
      kind: kind,
      title: title,
      subject: subject,
      topicId: topicId,
      minutes: minutes,
      startMs: now,
      endMs: now + minutes * 60000,
      remainingMs: minutes * 60000,
      running: true,
    );
    await _put(t);
    await _arm(t);
    return t;
  }

  static Future<ActiveTimer?> pause(String slot) async {
    final t = await get(slot);
    if (t == null || !t.running) return t;
    t.remainingMs = t.leftMs();
    t.running = false;
    await _put(t);
    await Notifier.cancel(idOf(slot));
    await Notifier.cancel(idOf(slot) + 2);
    return t;
  }

  static Future<ActiveTimer?> resume(String slot) async {
    final t = await get(slot);
    if (t == null || t.running) return t;
    t.endMs = DateTime.now().millisecondsSinceEpoch + t.remainingMs;
    t.running = true;
    await _put(t);
    await _arm(t);
    return t;
  }

  static Future<void> cancel(String slot) async {
    await _clear(slot);
    await Notifier.cancel(idOf(slot));
    await Notifier.cancel(idOf(slot) + 2);
  }

  // Records the session and schedules the next revision. Safe to call twice.
  static Future<int?> finalize(ActiveTimer t) async {
    final left = t.leftMs();
    final early = left > 0;
    final elapsedMs = t.totalMs - left;
    final mins = early ? math.min(t.minutes, math.max(1, (elapsedMs / 60000).ceil())) : t.minutes;
    final startedAt = DateTime.fromMillisecondsSinceEpoch(t.startMs).toIso8601String();
    final doneAt = early ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(t.endMs);
    final db = AppDb.db;
    final topics = await db.query('topics', where: 'id=?', whereArgs: [t.topicId]);
    final topic = topics.isEmpty ? null : topics.first;
    DateTime? next;
    int? sid;
    await db.transaction((txn) async {
      final dup = await txn.query('sessions',
          where: 'topicId=? AND kind=? AND startedAt=?', whereArgs: [t.topicId, t.kind, startedAt]);
      if (dup.isNotEmpty) {
        sid = dup.first['id'] as int?;
        return;
      }
      sid = await txn.insert('sessions', {
        'topicId': t.topicId,
        'kind': t.kind,
        'minutes': mins,
        'startedAt': startedAt,
        'completed': 1,
        // Lets Plan.rate() and the statistics know which revision this was and when it was due.
        if (t.kind == 'revision' && topic != null) 'due': topic['nextRevision'], // NEW
        if (t.kind == 'revision' && topic != null) 'rcb': (topic['revisionCount'] as num?)?.toInt() ?? 0, // NEW
      });
      if (topic != null && t.kind == 'new') {
        next = _isDaily(topic) ? _startOfTomorrow(doneAt) : doneAt.add(Duration(days: Prefs.afterNew()));
        await txn.update('topics',
            {'completedAt': doneAt.toIso8601String(), 'revisionCount': 0, 'nextRevision': next!.toIso8601String()},
            where: 'id=?', whereArgs: [t.topicId]);
      } else if (topic != null && t.kind == 'revision') {
        final rc = (topic['revisionCount'] as int?) ?? 0;
        next = _nextAfterRevision(topic, rc, doneAt);
        await txn.update('topics', {'revisionCount': rc + 1, 'nextRevision': next!.toIso8601String()},
            where: 'id=?', whereArgs: [t.topicId]);
      }
    });
    await _clear(t.slot);
    // A natural finish lets the already-scheduled alarm notify; only an early finish cancels it.
    await Notifier.cancel(idOf(t.slot) + 2);
    if (early) {
      await Notifier.cancel(idOf(t.slot));
    }
    final n = next;
    if (n != null) {
      await Notifier.cancelRevision(t.topicId);
      // Daily topics are covered by the daily reminder; no per-topic alarm.
      if (!_isDaily(topic)) await Notifier.scheduleRevision(t.topicId, n, t.title, t.subject);
    }
    await Extra.applyDaily();
    return sid;
  }

  static bool _isDaily(Map<String, dynamic>? t) => ((t?['daily'] as num?)?.toInt() ?? 0) == 1;
  static DateTime _startOfTomorrow(DateTime d) => DateTime(d.year, d.month, d.day + 1);

  // Next revision date after a revision is done.
  // - Daily topics: always tomorrow.
  // - Otherwise the interval is counted from the day it was DUE, not the day it was done,
  //   so a late revision does not push the whole schedule back.
  // - Missed revisions never pile up: if the result is already in the past, it becomes
  //   a single revision tomorrow.
  static DateTime _nextAfterRevision(Map<String, dynamic> topic, int rc, DateTime doneAt) {
    if (_isDaily(topic)) return _startOfTomorrow(doneAt);
    final due = DateTime.tryParse((topic['nextRevision'] as String?) ?? '');
    final anchor = (due != null && due.isBefore(doneAt)) ? due : doneAt;
    final next = anchor.add(Duration(days: Prefs.afterRevision(rc)));
    return next.isAfter(doneAt) ? next : _startOfTomorrow(doneAt);
  }

  // Finalizes timers that ended while the app was closed; drops timers of deleted topics.
  static Future<void> sweep() async {
    if (_busy) return;
    _busy = true;
    try {
      for (final slot in ['long', 'short']) {
        final t = await get(slot);
        if (t == null) continue;
        final exists = await AppDb.db.query('topics', columns: ['id'], where: 'id=?', whereArgs: [t.topicId]);
        if (exists.isEmpty) {
          await cancel(slot);
          continue;
        }
        if (t.running && t.leftMs() <= 0) await finalize(t);
      }
    } finally {
      _busy = false;
    }
  }

  // Raw timer JSON per slot, used by backup/restore.
  static Future<Map<String, String>> exportRaw() async {
    final p0 = await _prefs;
    final out = <String, String>{};
    for (final slot in ['long', 'short']) {
      final s = p0.getString('timer_$slot');
      if (s != null) out[slot] = s;
    }
    return out;
  }

  static Future<void> importRaw(Map<String, String> raw) async {
    final p0 = await _prefs;
    for (final slot in ['long', 'short']) {
      final s = raw[slot];
      if (s == null) continue;
      final t = ActiveTimer.fromJson(s);
      if (t == null || t.slot != slot) continue;
      await p0.setString('timer_$slot', s);
    }
  }

  static Future<void> rearmAll() async {
    for (final slot in ['long', 'short']) {
      final t = await get(slot);
      if (t != null && t.running && t.leftMs() > 0) await _arm(t);
    }
  }
}

// ───────── Database (schema v5: topics.daily/finished, sessions.rating) ─────────
class AppDb {
  static late Database db;

  static Future<void> _addCol(Database d, String table, String col, String def) async {
    final info = await d.rawQuery('PRAGMA table_info($table)');
    if (!info.any((c) => c['name'] == col)) await d.execute('ALTER TABLE $table ADD COLUMN $col $def');
  }

  static Future<void> init() async {
    db = await openDatabase(
      p.join(await getDatabasesPath(), 'recursive_study.db'),
      version: 5, // 5: repairs installs created without topics.daily
      onUpgrade: (db, oldV, newV) async {
        await _addCol(db, 'topics', 'daily', 'INTEGER DEFAULT 0');
        await _addCol(db, 'topics', 'finished', 'INTEGER DEFAULT 0');
        await _addCol(db, 'sessions', 'rating', 'INTEGER');
      },
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE subjects(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)');
        await db.execute('''CREATE TABLE topics(
          id INTEGER PRIMARY KEY AUTOINCREMENT, subjectId INTEGER NOT NULL,
          title TEXT NOT NULL, notes TEXT DEFAULT '', createdAt TEXT NOT NULL,
          completedAt TEXT, revisionCount INTEGER DEFAULT 0, nextRevision TEXT,
          daily INTEGER DEFAULT 0, finished INTEGER DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, topicId INTEGER, kind TEXT NOT NULL,
          minutes INTEGER NOT NULL, startedAt TEXT NOT NULL, completed INTEGER DEFAULT 0,
          rating INTEGER
        )''');
      },
    );
  }

  static Future<void> setRating(int sessionId, int rating) async {
    await db.update('sessions', {'rating': rating}, where: 'id=?', whereArgs: [sessionId]);
  }

  // Fully finished: leaves every schedule and list, shown only in Review -> Finished.
  static Future<void> markFinished(int id) async {
    await db.rawUpdate(
        "UPDATE topics SET finished=1, nextRevision=NULL, completedAt=COALESCE(completedAt, ?) WHERE id=?",
        [DateTime.now().toIso8601String(), id]);
    await Notifier.cancelRevision(id);
  }

  static Future<void> reopen(int id) async {
    final n = DateTime.now();
    await db.update(
        'topics',
        {
          'finished': 0,
          'revisionCount': 0,
          'nextRevision': DateTime(n.year, n.month, n.day + 1).toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [id]);
    await Notifier.refreshTopic(id);
  }

  static Future<void> deleteTopic(int id) async {
    await db.transaction((txn) async {
      await txn.delete('sessions', where: 'topicId=?', whereArgs: [id]);
      await txn.delete('topics', where: 'id=?', whereArgs: [id]);
    });
    await Notifier.cancelRevision(id);
  }

  static Future<void> deleteSubject(int id) async {
    final ids = await db.query('topics', columns: ['id'], where: 'subjectId=?', whereArgs: [id]);
    await db.transaction((txn) async {
      await txn.rawDelete('DELETE FROM sessions WHERE topicId IN (SELECT id FROM topics WHERE subjectId=?)', [id]);
      await txn.delete(  static Future<void> deleteTopic(int id) async {
    await db.transaction((txn) async {
      await txn.delete('sessions', where: 'topicId=?', whereArgs: [id]);
      await txn.delete('topics', where: 'id=?', whereArgs: [id]);
    });
    await Notifier.cancelRevision(id);
  }

  static Future<void> deleteSubject(int id) async {
    final ids = await db.query('topics', columns: ['id'], where: 'subjectId=?', whereArgs: [id]);
    await db.transaction((txn) async {
      await txn.rawDelete('DELETE FROM sessions WHERE topicId IN (SELECT id FROM topics WHERE subjectId=?)', [id]);
      await txn.delete('topics', where: 'subjectId=?', whereArgs: [id]);
      await txn.delete('subjects', where: 'id=?', whereArgs: [id]);
    });
    for (final r in ids) {
      await Notifier.cancelRevision(r['id'] as int);
    }
  }
}

// ───────── Helpers / stats ─────────
bool flagOf(Map<String, dynamic> t, String k) => ((t[k] as num?)?.toInt() ?? 0) == 1;

String starsText(Object? r) {
  final n = (r as num?)?.toInt();
  return n == null ? '' : '  ·  ★$n';
}

/// 1-5 star picker. Returns null when dismissed ("Later").
Future<int?> rateDialog(BuildContext context, String title, {int initial = 0}) {
  var v = initial;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Rate this session'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: () => setD(() => v = i),
                icon: Icon(i <= v ? Icons.star_rounded : Icons.star_outline_rounded, color: C.orange, size: 32),
              ),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton(onPressed: v == 0 ? null : () => Navigator.pop(ctx, v), child: const Text('Save')),
        ],
      ),
    ),
  );
}

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
DateTime dayAgo(DateTime d, int n) => DateTime(d.year, d.month, d.day - n);

int daysFromToday(DateTime d) {
  final n = DateTime.now();
  return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
}

String fmtMin(int m) => m < 60 ? '${m}m' : (m % 60 == 0 ? '${m ~/ 60}h' : '${m ~/ 60}h ${m % 60}m');

String kindLabel(String k) => k == 'new' ? 'Study' : (k == 'friday' ? 'Friday review' : 'Revision');

String fmtCountdown(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  final days = d.inDays, h = d.inHours % 24, m = d.inMinutes % 60, s = d.inSeconds % 60;
  if (days > 0) return '${days}d ${two(h)}h ${two(m)}m ${two(s)}s';
  if (d.inHours > 0) return '${d.inHours}h ${two(m)}m ${two(s)}s';
  return '${two(m)}m ${two(s)}s';
}

class Stats {
  int streak = 0, todayMin = 0, todaySessions = 0, totalMin = 0, totalSessions = 0, revisionSessions = 0;
  List<int> week = List.filled(7, 0);
  List<DateTime> weekDays = [];

  static Future<Stats> load() async {
    final s = Stats();
    final rows = await AppDb.db.rawQuery(
        "SELECT substr(startedAt,1,10) d, SUM(minutes) m, COUNT(*) c FROM sessions WHERE completed=1 GROUP BY d");
    final mins = <String, int>{};
    final cnt = <String, int>{};
    for (final r in rows) {
      final d = r['d'] as String?;
      if (d == null) continue;
      final m = (r['m'] as num?)?.toInt() ?? 0;
      final c = (r['c'] as num?)?.toInt() ?? 0;
      mins[d] = m;
      cnt[d] = c;
      s.totalMin += m;
      s.totalSessions += c;
    }
    final today = DateTime.now();
    s.todayMin = mins[dayKey(today)] ?? 0;
    s.todaySessions = cnt[dayKey(today)] ?? 0;
    var d = mins.containsKey(dayKey(today)) ? today : dayAgo(today, 1);
    while (mins.containsKey(dayKey(d))) {
      s.streak++;
      d = dayAgo(d, 1);
    }
    s.weekDays = List.generate(7, (i) => dayAgo(today, 6 - i));
    s.week = s.weekDays.map((x) => mins[dayKey(x)] ?? 0).toList();
    s.revisionSessions = Sqflite.firstIntValue(await AppDb.db
            .rawQuery("SELECT COUNT(*) FROM sessions WHERE completed=1 AND kind IN ('revision','friday')")) ??
        0;
    return s;
  }
}

// ───────── Shared widgets ─────────
Future<bool> confirmDialog(BuildContext context, String title, String body, String action) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r == true;
}

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap, onLongPress;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.onLongPress});
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(20);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: C.card,
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(borderRadius: r, border: Border.all(color: Colors.white.withOpacity(0.06))),
            child: child,
          ),
        ),
      ),
    );
  }
}

class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const IconBadge(this.icon, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: color.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
        child: Icon(icon, color: color, size: 22),
      );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyState(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
        child: Row(children: [
          Icon(icon, color: Colors.white38),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white54))),
        ]),
      );
}

Widget pageTitle(BuildContext context, String t, [String? sub]) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        if (sub != null) ...[const SizedBox(height: 4), Text(sub, style: const TextStyle(color: Colors.grey))],
      ]),
    );
