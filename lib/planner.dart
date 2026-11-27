import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import 'core.dart';

class DayLoad {
  final DateTime day;
  int newMin = 0, revMin = 0, dailyMin = 0, newN = 0, revN = 0, dailyN = 0;
  DayLoad(this.day);
  int get total => newMin + revMin + dailyMin;
}

/// Adaptive revision planner. All settings are editable in Settings and stored offline.
class Plan {
  // Interval factor per difficulty star (1 = very hard -> revise sooner, 5 = very easy -> later).
  static List<int> starPct = [60, 80, 100, 115, 130];
  static int adapt = 20; // % interval change per recall-rating step (1-5 stars after a revision)
  static int fade = 25; // % of the star factor lost per completed revision (performance takes over)
  static int lapseAt = 2; // revision rating <= this counts as a lapse
  static int lapseBack = 1; // steps moved back after a lapse
  static double minDays = 0.5, maxDays = 180;
  static int budget = 240; // daily study time limit (min), used by the forecast line
  static int dailyCap = 10; // max scheduled revisions (topics) per day
  static int balance = 1; // move a revision up to +-N days off an overloaded day
  static int newPerDay = 3; // forecast pace for unstudied topics
  static int practiceMin = 10; // minutes per everyday-practice topic per day
  static const int weakAt = 3; // latest rating <= this = weak topic (same rule as Review -> Needs review)
  static int horizon = 14; // forecast days
  static int notifyMin = 3; // remind this many minutes after leaving unrated
  static bool askNew = true, askRev = true, notify = true;
  static SharedPreferences? _p;

  static Map<String, dynamic> toMap() => {
        'starPct': starPct,
        'adapt': adapt,
        'fade': fade,
        'lapseAt': lapseAt,
        'lapseBack': lapseBack,
        'minDays': minDays,
        'maxDays': maxDays,
        'budget': budget,
        'dailyCap': dailyCap,
        'balance': balance,
        'newPerDay': newPerDay,
        'practiceMin': practiceMin,
        'horizon': horizon,
        'notifyMin': notifyMin,
        'askNew': askNew,
        'askRev': askRev,
        'notify': notify,
      };

  static void _apply(Map m) {
    int i(String k, int d, int lo, int hi) => m[k] is num ? (m[k] as num).toInt().clamp(lo, hi).toInt() : d;
    double f(String k, double d, double lo, double hi) => m[k] is num ? (m[k] as num).toDouble().clamp(lo, hi).toDouble() : d;
    bool b(String k, bool d) => m[k] is bool ? m[k] as bool : d;
    final sp = m['starPct'];
    if (sp is List && sp.length == 5) {
      starPct = [for (final e in sp) e is num ? e.toInt().clamp(20, 300).toInt() : 100];
    }
    adapt = i('adapt', adapt, 0, 100);
    fade = i('fade', fade, 0, 100);
    lapseAt = i('lapseAt', lapseAt, 0, 3);
    lapseBack = i('lapseBack', lapseBack, 0, 5);
    minDays = f('minDays', minDays, 0.5, 30);
    maxDays = f('maxDays', maxDays, 7, 730);
    if (maxDays < minDays) maxDays = minDays;
    budget = i('budget', budget, 30, 1440);
    dailyCap = i('dailyCap', dailyCap, 1, 60);
    balance = i('balance', balance, 0, 7);
    newPerDay = i('newPerDay', newPerDay, 0, 50);
    practiceMin = i('practiceMin', practiceMin, 1, 120);
    horizon = i('horizon', horizon, 7, 60);
    notifyMin = i('notifyMin', notifyMin, 1, 120);
    askNew = b('askNew', askNew);
    askRev = b('askRev', askRev);
    notify = b('notify', notify);
  }

  static Future<void> init() async {
    try {
      _p = await SharedPreferences.getInstance();
      final s = _p!.getString('plan');
      if (s != null) _apply(jsonDecode(s) as Map);
    } catch (_) {}
    await ensureSchema();
  }

  static Future<void> save() async {
    try {
      await _p?.setString('plan', jsonEncode(toMap()));
    } catch (_) {}
  }

  static Future<void> fromMap(Map<String, dynamic> m) async {
    _apply(m);
    await save();
  }

  static Future<void> reset() async {
    starPct = [60, 80, 100, 115, 130];
    adapt = 20;
    fade = 25;
    lapseAt = 2;
    lapseBack = 1;
    minDays = 0.5;
    maxDays = 180;
    budget = 240;
    dailyCap = 10;
    balance = 1;
    newPerDay = 3;
    practiceMin = 10;
    horizon = 14;
    notifyMin = 3;
    askNew = true;
    askRev = true;
    notify = true;
    await save();
  }

  static Future<void> ensureSchema() async {
    final info = await AppDb.db.rawQuery('PRAGMA table_info(sessions)');
    final have = info.map((c) => '${c['name']}').toSet();
    if (!have.contains('due')) await AppDb.db.execute('ALTER TABLE sessions ADD COLUMN due TEXT');
    if (!have.contains('rcb')) await AppDb.db.execute('ALTER TABLE sessions ADD COLUMN rcb INTEGER');
  }

  // ───────── Core math ─────────
  static Duration _dur(double d) => Duration(minutes: (d * 1440).round());
  static DateTime _tomorrow(DateTime d) => DateTime(d.year, d.month, d.day + 1);

  /// Interval in days for revision step [step] (0 = first revision after study).
  static double days(int step, int? diff, double ease) {
    final iv = Prefs.intervals;
    final base = iv[math.min(step, iv.length - 1)];
    final infl = math.max(0.0, 1 - step * fade / 100);
    final star = starPct[((diff ?? 3) - 1).clamp(0, 4).toInt()] / 100;
    final sf = math.pow(star, infl).toDouble();
    final d = (base * sf * ease * 2).round() / 2;
    return d.clamp(minDays, maxDays).toDouble();
  }

  // (latest difficulty stars, ease from recall ratings)
  static (int?, double) _fold(Iterable<Map<String, Object?>> rows) {
    int? diff;
    var e = 1.0;
    for (final r in rows) {
      final k = r['kind'];
      final v = (r['rating'] as num).toInt().clamp(1, 5).toInt();
      if (k == 'new') {
        diff = v;
      } else if (k == 'revision') {
        e = (e * (1 + adapt / 100 * (v - 3) / 2)).clamp(0.4, 2.5).toDouble();
      }
    }
    return (diff, e);
  }

  static Future<(int?, double)> _hist(int topicId) async {
    final rows = await AppDb.db.rawQuery(
        "SELECT kind, rating FROM sessions WHERE topicId=? AND completed=1 AND rating IS NOT NULL ORDER BY startedAt, id",
        [topicId]);
    return _fold(rows);
  }

  // Moves a revision up to +-[balance] days off a day that already holds [dailyCap] revisions (a count of topics).
  static Future<DateTime> _balanced(DateTime t, int topicId, double span) async {
    if (balance <= 0 || span < 3) return t;
    final rows = await AppDb.db.rawQuery(
        "SELECT substr(nextRevision,1,10) d, COUNT(*) c FROM topics WHERE nextRevision IS NOT NULL "
        "AND COALESCE(daily,0)=0 AND COALESCE(finished,0)=0 AND id<>? GROUP BY d",
        [topicId]);
    final load = {for (final r in rows) '${r['d']}': (r['c'] as num).toInt()};
    final now = DateTime.now();
    var best = 0, bestLoad = 1 << 30;
    for (var k = 0; k <= balance * 2; k++) {
      final off = k == 0 ? 0 : (k.isOdd ? -((k + 1) ~/ 2) : k ~/ 2);
      final c = DateTime(t.year, t.month, t.day + off, t.hour, t.minute);
      if (!c.isAfter(now)) continue;
      final l = (load[dayKey(c)] ?? 0) + 1;
      if (l <= dailyCap) return c;
      if (l < bestLoad) {
        bestLoad = l;
        best = off;
      }
    }
    return DateTime(t.year, t.month, t.day + best, t.hour, t.minute);
  }

  static Future<DateTime> nextAfterNew(Map<String, dynamic> topic, DateTime doneAt) async {
    if (flagOf(topic, 'daily')) return _tomorrow(doneAt);
    final id = (topic['id'] as num).toInt();
    final h = await _hist(id);
    final d = days(0, h.$1, h.$2);
    return _balanced(doneAt.add(_dur(d)), id, d);
  }

  /// Returns (new revision step, next due). [rating] null = not rated yet (neutral).
  static Future<(int, DateTime)> afterRevision({
    required int topicId,
    required bool daily,
    required int rcb,
    required DateTime? due,
    required DateTime doneAt,
    int? rating,
  }) async {
    final lapse = rating != null && rating <= lapseAt;
    final step = lapse ? math.max(0, rcb - lapseBack) : rcb + 1;
    if (daily) return (step, _tomorrow(doneAt));
    final h = await _hist(topicId);
    final d = days(step, h.$1, h.$2);
    // Interval counts from the day it was due, so a late revision does not push the schedule back.
    final anchor = (due != null && due.isBefore(doneAt)) ? due : doneAt;
    var next = anchor.add(_dur(d));
    if (!next.isAfter(doneAt)) next = _tomorrow(doneAt);
    return (step, await _balanced(next, topicId, d));
  }

  // ───────── Rating ─────────
  static bool wants(String kind) => (kind == 'new' && askNew) || ((kind == 'revision' || kind == 'friday') && askRev);

  static String get kindsSql {
    final k = [if (askNew) "'new'", if (askRev) "'revision'", if (askRev) "'friday'"];
    return k.isEmpty ? "('none')" : '(${k.join(',')})';
  }

  static int _pid(int sid) => 400000 + sid;

  /// Local notification in case the user leaves before rating.
  static Future<void> armPrompt(int sid, String title, String kind) async {
    if (!notify || !wants(kind)) return;
    await Notifier.at(_pid(sid), DateTime.now().add(Duration(minutes: notifyMin)),
        kind == 'new' ? 'How hard was it?' : 'How well did you recall it?', '$title · tap to rate',
        force: true);
  }

  static Future<List<Map<String, Object?>>> pending() => AppDb.db.rawQuery(
      "SELECT x.id, x.kind, x.startedAt, t.title FROM sessions x JOIN topics t ON t.id=x.topicId "
      "WHERE x.completed=1 AND x.rating IS NULL AND x.kind IN $kindsSql ORDER BY x.startedAt LIMIT 50");

  /// Saves a rating and re-plans the topic from it (only if it is the topic's latest session).
  static Future<void> rate(int sid, int stars) async {
    final db = AppDb.db;
    await db.update('sessions', {'rating': stars}, where: 'id=?', whereArgs: [sid]);
    await Notifier.cancel(_pid(sid));
    final ss = await db.query('sessions', where: 'id=?', whereArgs: [sid]);
    if (ss.isEmpty) return;
    final s = ss.first;
    final kind = '${s['kind']}';
    final tid = (s['topicId'] as num?)?.toInt();
    if (tid == null || (kind != 'new' && kind != 'revision')) return;
    final last = await db.rawQuery(
        "SELECT MAX(id) m FROM sessions WHERE topicId=? AND kind IN ('new','revision') AND completed=1", [tid]);
    if ((last.first['m'] as num?)?.toInt() != sid) {
      // An older session was (re)rated: the topic's history changed, so re-plan it from that history.
      await replanTopic(tid);
      await Notifier.refreshTopic(tid);
      return;
    }
    final ts = await db.query('topics', where: 'id=?', whereArgs: [tid]);
    if (ts.isEmpty) return;
    final t = ts.first;
    if (flagOf(t, 'finished')) return;
    final daily = flagOf(t, 'daily');
    final started = DateTime.tryParse('${s['startedAt']}') ?? DateTime.now();
    final doneAt = started.add(Duration(minutes: (s['minutes'] as num?)?.toInt() ?? 0));
    if (kind == 'new') {
      if (daily) return;
      final next = await nextAfterNew(t, DateTime.tryParse('${t['completedAt']}') ?? doneAt);
      await db.update('topics', {'nextRevision': next.toIso8601String()}, where: 'id=?', whereArgs: [tid]);
    } else {
      final rcb = (s['rcb'] as num?)?.toInt() ?? math.max(0, ((t['revisionCount'] as num?)?.toInt() ?? 1) - 1);
      final r = await afterRevision(
          topicId: tid,
          daily: daily,
          rcb: rcb,
          due: DateTime.tryParse('${s['due'] ?? ''}'),
          doneAt: doneAt,
          rating: stars);
      await db.update('topics', {'revisionCount': r.$1, 'nextRevision': r.$2.toIso8601String()},
          where: 'id=?', whereArgs: [tid]);
    }
    await Notifier.refreshTopic(tid);
  }

  /// Re-plans one topic's upcoming revision from its latest session and rating history.
  /// Returns false when nothing needed to change (no revision scheduled, already due, daily or finished).
  static Future<bool> _replanRow(Map<String, Object?> t, DateTime now) async {
    final db = AppDb.db;
    final id = (t['id'] as num).toInt();
    final due = DateTime.tryParse('${t['nextRevision']}');
    if (due == null || !due.isAfter(now)) return false;
    final ss = await db.rawQuery(
        "SELECT startedAt, minutes FROM sessions WHERE topicId=? AND kind IN ('new','revision') AND completed=1 ORDER BY id DESC LIMIT 1",
        [id]);
    if (ss.isEmpty) return false;
    final st = DateTime.tryParse('${ss.first['startedAt']}');
    if (st == null) return false;
    final done = st.add(Duration(minutes: (ss.first['minutes'] as num?)?.toInt() ?? 0));
    final h = await _hist(id);
    final d = days((t['revisionCount'] as num?)?.toInt() ?? 0, h.$1, h.$2);
    var next = done.add(_dur(d));
    if (!next.isAfter(now)) next = DateTime(now.year, now.month, now.day + 1, due.hour, due.minute);
    next = await _balanced(next, id, d);
    await db.update('topics', {'nextRevision': next.toIso8601String()}, where: 'id=?', whereArgs: [id]);
    return true;
  }

  /// Re-plans a single topic (used after any rating, including an older session's).
  static Future<void> replanTopic(int id) async {
    final ts = await AppDb.db.query('topics', where: 'id=?', whereArgs: [id]);
    if (ts.isEmpty) return;
    final t = ts.first;
    if (flagOf(t, 'daily') || flagOf(t, 'finished')) return;
    await _replanRow(t, DateTime.now());
  }

  /// Re-applies the current rules to every upcoming (not yet due) revision. Returns how many moved.
  static Future<int> replanAll() async {
    final now = DateTime.now();
    var n = 0;
    final ts = await AppDb.db.query('topics',
        where: 'nextRevision IS NOT NULL AND COALESCE(daily,0)=0 AND COALESCE(finished,0)=0');
    for (final t in ts) {
      if (await _replanRow(t, now)) n++;
    }
    await Notifier.rescheduleAll();
    return n;
  }

  // ───────── Weak topics / hardest-first / study rating ─────────
  /// Latest star rating per topic (study, revision or Friday review). Same rule as Review -> Needs review.
  static Future<Map<int, int>> latestRatings() async {
    final rows = await AppDb.db.rawQuery(
        "SELECT topicId, rating FROM sessions WHERE completed=1 AND rating IS NOT NULL ORDER BY startedAt, id");
    final m = <int, int>{};
    for (final r in rows) {
      final id = (r['topicId'] as num?)?.toInt();
      if (id == null) continue;
      m[id] = (r['rating'] as num).toInt().clamp(1, 5).toInt();
    }
    return m;
  }

  /// Latest difficulty rating given after studying (kind 'new') per topic.
  static Future<Map<int, int>> studyRatings() async {
    final rows = await AppDb.db.rawQuery(
        "SELECT topicId, rating FROM sessions WHERE completed=1 AND kind='new' AND rating IS NOT NULL ORDER BY startedAt, id");
    final m = <int, int>{};
    for (final r in rows) {
      final id = (r['topicId'] as num?)?.toInt();
      if (id == null) continue;
      m[id] = (r['rating'] as num).toInt().clamp(1, 5).toInt();
    }
    return m;
  }

  // ───────── Forecast: new study, scheduled revision and everyday practice kept apart ─────────
  static Future<List<DayLoad>> forecast() async {
    final db = AppDb.db;
    final now = DateTime.now();
    final n = horizon;
    final out = [for (var i = 0; i < n; i++) DayLoad(DateTime(now.year, now.month, now.day + i))];
    final topics = await db.rawQuery(
        "SELECT id, completedAt, nextRevision, revisionCount, daily FROM topics WHERE COALESCE(finished,0)=0 ORDER BY createdAt, id");
    final hist = await db.rawQuery(
        "SELECT topicId, kind, rating FROM sessions WHERE completed=1 AND rating IS NOT NULL ORDER BY startedAt, id");
    final byT = <int, List<Map<String, Object?>>>{};
    for (final r in hist) {
      byT.putIfAbsent((r['topicId'] as num).toInt(), () => []).add(r);
    }

    void chain(int start, int step, int? diff, double ease) {
      var i = math.max(0, start), s = step;
      while (i < n) {
        out[i].revMin += Prefs.revisionMin;
        out[i].revN++;
        i += math.max(1, days(s, diff, ease).round());
        s++;
      }
    }

    void practiceFrom(int from) {
      for (var i = math.max(0, from); i < n; i++) {
        out[i].dailyMin += practiceMin;
        out[i].dailyN++;
      }
    }

    var k = 0; // unstudied topic counter for the new-study pace
    for (final t in topics) {
      final id = (t['id'] as num).toInt();
      final daily = flagOf(t, 'daily');
      if (t['completedAt'] == null) {
        if (newPerDay <= 0) continue;
        final day = k ~/ newPerDay;
        k++;
        if (day >= n) continue;
        out[day].newMin += Prefs.studyMin;
        out[day].newN++;
        if (daily) {
          practiceFrom(day + 1);
        } else {
          chain(day + math.max(1, days(0, null, 1.0).round()), 1, null, 1.0);
        }
      } else if (daily) {
        practiceFrom(0);
      } else {
        final due = DateTime.tryParse('${t['nextRevision'] ?? ''}');
        if (due == null) continue;
        final h = _fold(byT[id] ?? const []);
        chain(daysFromToday(due), ((t['revisionCount'] as num?)?.toInt() ?? 0) + 1, h.$1, h.$2);
      }
    }
    return out;
  }

  // ───────── Priority, confidence and statistics ─────────
  // Everything here reads the intervals already configured in Settings (Prefs.intervals); nothing is duplicated.
  static const recent = 5; // ratings that count towards "repeated hard" and confidence

  /// How many of the last [recent] ratings were weak (<= weakAt). Oldest first.
  static int hardCount(List<int> ratings) {
    final r = ratings.length > recent ? ratings.sublist(ratings.length - recent) : ratings;
    return r.where((x) => x <= weakAt).length;
  }

  /// Higher = revise first. Overdue days (max 30) and repeated hard ratings drive it.
  static double priority({required int overdueDays, required int hard, int? latest}) =>
      math.min(math.max(overdueDays, 0), 30) * 2.0 + hard * 3.0 + ((latest ?? 99) <= weakAt ? 2.0 : 0.0);

  /// Confidence 0-100 from recent ratings (newer count more), scaled by how far the topic has
  /// progressed through the configured intervals, minus a penalty for being overdue.
  /// null = no ratings yet.
  static int? confidence({
    required List<int> ratings,
    required int revisionCount,
    required int overdueDays,
    required int steps,
  }) {
    if (ratings.isEmpty) return null;
    final r = ratings.length > recent ? ratings.sublist(ratings.length - recent) : ratings;
    var sum = 0.0, den = 0.0;
    for (var i = 0; i < r.length; i++) {
      final w = i + 1.0;
      sum += w * (r[i].clamp(1, 5) - 1) / 4;
      den += w;
    }
    final stage = 0.7 + 0.3 * math.min(1.0, revisionCount / math.max(1, steps));
    final pen = math.min(25, math.max(overdueDays, 0) * 3);
    return (sum / den * 100 * stage - pen).round().clamp(0, 100).toInt();
  }

  static String confLabel(int? c) => c == null ? 'No data' : (c >= 70 ? 'High' : (c >= 40 ? 'Medium' : 'Low'));

  /// Per-topic insight for every unfinished topic: ratings, repeated-hard count, overdue days, confidence, priority.
  static Future<Map<int, TopicInsight>> insights() async {
    final db = AppDb.db;
    final topics = await db.rawQuery(
        "SELECT t.id, t.title, t.revisionCount, t.nextRevision, t.completedAt, t.daily, s.name subject "
        "FROM topics t JOIN subjects s ON s.id=t.subjectId WHERE COALESCE(t.finished,0)=0");
    final rows = await db.rawQuery(
        "SELECT topicId, rating FROM sessions WHERE completed=1 AND rating IS NOT NULL ORDER BY startedAt, id");
    final byT = <int, List<int>>{};
    for (final r in rows) {
      final id = (r['topicId'] as num?)?.toInt();
      if (id == null) continue;
      byT.putIfAbsent(id, () => []).add((r['rating'] as num).toInt().clamp(1, 5).toInt());
    }
    final out = <int, TopicInsight>{};
    for (final t in topics) {
      final id = (t['id'] as num).toInt();
      final ratings = byT[id] ?? const <int>[];
      final due = DateTime.tryParse('${t['nextRevision'] ?? ''}');
      final d = due == null ? 0 : daysFromToday(due);
      final overdue = d < 0 ? -d : 0;
      final hard = hardCount(ratings);
            final latest = ratings.isEmpty ? null : ratings.last;
      out[id] = TopicInsight(
        id: id,
        title: '${t['title']}',
        subject: '${t['subject']}',
        studied: t['completedAt'] != null,
        daily: flagOf(t, 'daily'),
        ratings: ratings,
        hard: hard,
        overdue: overdue,
        latest: latest,
        confidence: confidence(
            ratings: ratings,
            revisionCount: (t['revisionCount'] as num?)?.toInt() ?? 0,
            overdueDays: overdue,
            steps: Prefs.intervals.length),
        priority: priority(overdueDays: overdue, hard: hard, latest: latest),
      );
    }
    return out;
  }
}

class TopicInsight {
  final int id, hard, overdue;
  final String title, subject;
  final bool studied, daily;
  final List<int> ratings;
  final int? latest, confidence;
  final double priority;
  const TopicInsight({
    required this.id,
    required this.title,
    required this.subject,
    required this.studied,
    required this.daily,
    required this.ratings,
    required this.hard,
    required this.overdue,
    required this.latest,
    required this.confidence,
    required this.priority,
  });
}

class SubjectRevStat {
  final String name;
  final int revisions;
  final double? avg;
  final int? confidence;
  const SubjectRevStat(this.name, this.revisions, this.avg, this.confidence);
}

/// Revision statistics for the Progress page.
class RevisionStats {
  int total = 0, last7 = 0, last30 = 0, rated = 0, lapses = 0, onTime = 0, timed = 0, overdueNow = 0, studied = 0;
  double avgRecall = 0;
  List<int> dist = List.filled(5, 0); // recall ratings 1..5
  int? confidence; // mean confidence of studied topics
  List<SubjectRevStat> subjects = [];
  List<TopicInsight> weakest = [];

  double get lapseRate => rated == 0 ? 0 : lapses / rated;
  double get onTimeRate => timed == 0 ? 0 : onTime / timed;

  static Future<RevisionStats> load() async {
    final db = AppDb.db;
    final s = RevisionStats();
    final now = DateTime.now();
    final rows = await db.rawQuery(
        "SELECT x.kind, x.rating, x.startedAt, x.due, s.name subject FROM sessions x "
        "JOIN topics t ON t.id=x.topicId JOIN subjects s ON s.id=t.subjectId "
        "WHERE x.completed=1 AND x.kind IN ('revision','friday')");
    final subjSum = <String, double>{};
    final subjN = <String, int>{};
    final subjRev = <String, int>{};
    var sum = 0;
    for (final r in rows) {
      s.total++;
      final at = DateTime.tryParse('${r['startedAt']}');
      if (at != null) {
        final age = now.difference(at).inDays;
        if (age < 7) s.last7++;
        if (age < 30) s.last30++;
      }
      final name = '${r['subject']}';
      subjRev[name] = (subjRev[name] ?? 0) + 1;
      final rating = (r['rating'] as num?)?.toInt();
      if (rating != null) {
        final v = rating.clamp(1, 5).toInt();
        s.rated++;
        sum += v;
        s.dist[v - 1]++;
        subjSum[name] = (subjSum[name] ?? 0) + v;
        subjN[name] = (subjN[name] ?? 0) + 1;
        if (r['kind'] == 'revision' && v <= lapseAt) s.lapses++;
      }
      final due = r['due'];
      if (r['kind'] == 'revision' && due != null && at != null) {
        s.timed++;
        if (dayKey(at).compareTo('${due}'.substring(0, math.min(10, '${due}'.length))) <= 0) s.onTime++;
      }
    }
    s.avgRecall = s.rated == 0 ? 0 : sum / s.rated;

    final ins = (await Plan.insights()).values.where((t) => t.studied).toList();
    s.studied = ins.length;
    s.overdueNow = ins.where((t) => !t.daily && t.overdue > 0).length;
    final confs = ins.map((t) => t.confidence).whereType<int>().toList();
    s.confidence = confs.isEmpty ? null : (confs.reduce((a, b) => a + b) / confs.length).round();

    final subjConf = <String, List<int>>{};
    for (final t in ins) {
      if (t.confidence != null) subjConf.putIfAbsent(t.subject, () => []).add(t.confidence!);
    }
    final names = {...subjRev.keys, ...subjConf.keys}.toList()..sort();
    s.subjects = [
      for (final n in names)
        SubjectRevStat(
          n,
          subjRev[n] ?? 0,
          (subjN[n] ?? 0) == 0 ? null : subjSum[n]! / subjN[n]!,
          subjConf[n] == null ? null : (subjConf[n]!.reduce((a, b) => a + b) / subjConf[n]!.length).round(),
        )
    ];
    final rated = ins.where((t) => t.confidence != null).toList()
      ..sort((a, b) => a.confidence!.compareTo(b.confidence!));
    s.weakest = rated.take(5).toList();
    return s;
  }
}
