import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core.dart';
import 'jobs_page.dart';
import 'plan_ui.dart';
import 'planner.dart';
import 'timer_page.dart';

export 'progress_page.dart';

// ───────────────────────── Today ─────────────────────────
class Dashboard extends StatefulWidget {
  final VoidCallback onChanged;
  const Dashboard({super.key, required this.onChanged});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  List<Map<String, dynamic>> revisions = [], newTopics = [], upcoming = [], friday = [], jobDates = [], practice = [];
  Map<int, int> studyR = {};
  int pendingRate = 0;
  List<ActiveTimer> active = [];
  Stats stats = Stats();
  Timer? tick;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    load();
    tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    tick?.cancel();
    super.dispose();
  }

  Future<void> _onTick() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final now = DateTime.now();
    final finished = active.any((a) => a.running && a.leftMs() <= 0);
    final due = upcoming.isNotEmpty && !DateTime.parse(upcoming.first['nextRevision'] as String).isAfter(now);
    if (finished) {
      await TimerStore.sweep();
      await load();
    } else if (due) {
      await load();
    } else {
      setState(() {});
    }
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    try {
      final now = DateTime.now();
      final nowS = now.toIso8601String();
      const base = "SELECT t.*, s.name subject FROM topics t JOIN subjects s ON s.id=t.subjectId";
      revisions = await AppDb.db.rawQuery(
          "$base WHERE t.nextRevision IS NOT NULL AND t.nextRevision <= ? AND COALESCE(t.daily,0)=0 AND COALESCE(t.finished,0)=0 ORDER BY t.nextRevision",
          [nowS]);
      practice = await AppDb.db.rawQuery(
          "$base WHERE t.nextRevision IS NOT NULL AND t.nextRevision <= ? AND COALESCE(t.daily,0)=1 AND COALESCE(t.finished,0)=0 ORDER BY s.name, t.title",
          [nowS]);
      pendingRate = (await Plan.pending()).length;
      newTopics = await AppDb.db.rawQuery("$base WHERE t.completedAt IS NULL ORDER BY t.createdAt");
      upcoming = await AppDb.db.rawQuery("$base WHERE t.nextRevision IS NOT NULL AND t.nextRevision > ? ORDER BY t.nextRevision LIMIT 3", [nowS]);
      final rated = await Plan.latestRatings();
      studyR = await Plan.studyRatings();
      friday = (now.weekday == DateTime.friday && Prefs.fridayReview)
          ? await AppDb.db.rawQuery(
              "$base WHERE t.completedAt IS NOT NULL AND COALESCE(t.finished,0)=0 AND t.id NOT IN (SELECT topicId FROM sessions WHERE kind='friday' AND completed=1 AND substr(startedAt,1,10)=?) ORDER BY s.name, t.title",
              [dayKey(now)])
          : [];
      // Friday = spiral revision: only weak topics (latest rating <= 3 stars), weakest first.
      friday = [
        for (final t in friday)
          if ((rated[t['id'] as int] ?? 99) <= Plan.weakAt) <String, dynamic>{...t, 'rating': rated[t['id'] as int]}
      ]..sort((a, b) {
          final c = (a['rating'] as int).compareTo(b['rating'] as int);
          return c != 0 ? c : '${a['subject']}${a['title']}'.compareTo('${b['subject']}${b['title']}');
        });
      try {
        await JobDb.ensure();
        jobDates = await AppDb.db.rawQuery(
            "SELECT * FROM job_applications WHERE deadline IS NOT NULL AND deadline >= ? AND status NOT IN ('Selected','Rejected') ORDER BY deadline LIMIT 5",
            [dayKey(now)]);
      } catch (_) {
        jobDates = [];
      }
      final a = await Future.wait([TimerStore.get('long'), TimerStore.get('short')]);
      active = a.whereType<ActiveTimer>().toList();
      // A topic with a running/paused timer lives only in "In progress"; cancelling returns it to its list.
      bool busy(Map<String, dynamic> t, String kind) => active.any((x) => x.topicId == t['id'] && x.kind == kind);
      revisions = revisions.where((t) => !busy(t, 'revision')).toList();
      practice = practice.where((t) => !busy(t, 'revision')).toList();
      newTopics = newTopics.where((t) => !busy(t, 'new')).toList();
      friday = friday.where((t) => !busy(t, 'friday')).toList();
      // Hardest first (lowest latest rating, unrated = neutral 3), then longest overdue.
      int hard(Map<String, dynamic> t) => rated[t['id'] as int] ?? 3;
      revisions.sort((a, b) {
        final c = hard(a).compareTo(hard(b));
        return c != 0 ? c : '${a['nextRevision']}'.compareTo('${b['nextRevision']}');
      });
      stats = await Stats.load();
    } finally {
      loading = false;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isFriday = DateTime.now().weekday == DateTime.friday && Prefs.fridayReview;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20), children: [
        _hero(),
        const SizedBox(height: 22),
        if (pendingRate > 0) ...[_rateBanner(), const SizedBox(height: 14)],
        if (active.isNotEmpty) ...[_activeSection(), const SizedBox(height: 14)],
        if (upcoming.isNotEmpty) ...[_upcomingSection(), const SizedBox(height: 14)],
        if (jobDates.isNotEmpty) ...[_jobDatesSection(), const SizedBox(height: 14)],
        if (isFriday) ...[
          _section('Friday spiral review', friday, 'friday', 'No weak topics left to revisit. Great work!'),
          const SizedBox(height: 14),
        ],
        _section('Revision', revisions, 'revision', 'No revisions due.'),
        const SizedBox(height: 14),
        if (practice.isNotEmpty) ...[
          _section('Everyday practice', practice, 'revision', ''),
          const SizedBox(height: 14),
        ],
        _section('New study', newTopics, 'new', 'No new topics. Add one from Subjects.'),
        const SizedBox(height: 20),
      ]),
    );
  }

  Widget _hero() {
    final h = DateTime.now().hour;
    final greet = h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [C.violet, C.blue, C.cyan]),
        boxShadow: [BoxShadow(color: C.violet.withOpacity(0.35), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(greet, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 4),
        Text(DateFormat('EEEE, MMM d').format(DateTime.now()), style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 22),
        Row(children: [
          _pill(Icons.local_fire_department, '${stats.streak}', 'day streak'),
          const SizedBox(width: 10),
          _pill(Icons.timer_outlined, fmtMin(stats.todayMin), 'today'),
          const SizedBox(width: 10),
          _pill(Icons.event_repeat, '${revisions.length + practice.length}', 'due'),
        ]),
      ]),
    );
  }

  Widget _pill(IconData icon, String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.22), borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ]),
        ),
      );

  Widget _heading(String title, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
            child: Text('$count', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ]),
      );  Widget _rateBanner() => Panel(
        onTap: () async {
          final p = await Plan.pending();
          if (p.isEmpty || !mounted) return;
          await rateSession(context, p.first['id'] as int, '${p.first['title']}', '${p.first['kind']}');
          await load();
          widget.onChanged();
        },
        child: Row(children: [
          const IconBadge(Icons.star_outline_rounded, C.orange),
          const SizedBox(width: 14),
          Expanded(
            child: Text('$pendingRate session${pendingRate == 1 ? '' : 's'} to rate',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const Text('Rate', style: TextStyle(color: C.orange, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _activeSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('In progress', active.length),
      ...active.map((a) {
        final left = Duration(milliseconds: a.leftMs());
        return Panel(
          onTap: () => _openTimer(a.title, a.minutes, a.topicId, a.kind, a.subject),
          child: Row(children: [
            IconBadge(a.running ? Icons.timer : Icons.pause_circle_outline, C.green),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text('${a.subject}  ·  ${kindLabel(a.kind)}  ·  ${a.minutes} min', style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ]),
            ),
            Text(a.running ? fmtCountdown(left) : 'Paused ${fmtCountdown(left)}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: C.green, fontSize: 13)),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () async {
                final ok = await confirmDialog(context, 'Cancel session?', 'The timer and its alarm will be removed.', 'Cancel session');
                if (ok) {
                  await TimerStore.cancel(a.slot);
                  await load();
                }
              },
            ),
          ]),
        );
      }),
    ]);
  }

  Widget _upcomingSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('Next revisions', upcoming.length),
      ...upcoming.map((t) {
        final d = daysFromToday(DateTime.parse(t['nextRevision'] as String));
        final when = d <= 0 ? 'Today' : (d == 1 ? 'Tomorrow' : 'In ${d}d');

        return Panel(
          child: Row(children: [
            const IconBadge(Icons.hourglass_bottom_rounded, C.cyan),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text('${t['subject']}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                if (((t['notes'] as String?) ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(((t['notes'] as String?) ?? '').trim(),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ]),
            ),
            Text(when, style: const TextStyle(fontWeight: FontWeight.w700, color: C.cyan, fontSize: 13)),
          ]),
        );
      }),
    ]);
  }

  Widget _jobDatesSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('Upcoming job dates', jobDates.length),
      ...jobDates.map((j) {
        final dl = DateTime.parse(j['deadline'] as String);
        final d = daysFromToday(dl);
        final when = d <= 0 ? 'Today' : (d == 1 ? 'Tomorrow' : 'in ${d}d');
        final color = d <= 1 ? C.orange : C.cyan;
        final org = ((j['org'] as String?) ?? '').trim();
        return Panel(
          child: Row(children: [
            IconBadge(Icons.work_outline, color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(j['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text('${org.isEmpty ? '' : '$org  ·  '}${j['status']}  ·  ${DateFormat('d MMM').format(dl)}',
                    style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ]),
            ),
            Text(when, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13)),
          ]),
        );
      }),
    ]);
  }

  final Set<String> collapsed = {};

  Widget _section(String title, List<Map<String, dynamic>> items, String kind, String emptyText) {
    // Group by subject, keeping the order in which each subject first appears.
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final t in items) {
      groups.putIfAbsent('${t['subject']}', () => []).add(t);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(title, items.length),
      if (items.isEmpty) EmptyState(kind == 'new' ? Icons.library_add_outlined : Icons.check_circle_outline, emptyText),
      ...groups.entries.map((e) => _group(kind, e.key, e.value)),
    ]);
  }

  Widget _group(String kind, String subject, List<Map<String, dynamic>> list) {
    final key = '$kind|$subject';
    final open = !collapsed.contains(key);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => open ? collapsed.add(key) : collapsed.remove(key)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Row(children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 20, color: Colors.white54),
            const SizedBox(width: 6),
            Text(subject, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white70)),
            const SizedBox(width: 8),
            Text('${list.length}', style: const TextStyle(fontSize: 13, color: Colors.white38)),
          ]),
        ),
      ),
      if (open) ...list.map((t) => _tile(t, kind)),
      const SizedBox(height: 4),
    ]);
  }

  Widget _tile(Map<String, dynamic> t, String kind) {
    String sub;
    Color color;
    IconData icon;
    if (kind == 'revision') {
      final days = daysFromToday(DateTime.parse(t['nextRevision'] as String));
      final sr = studyR[t['id'] as int];
      sub = '${days < 0 ? 'Overdue ${-days}d' : 'Due now'}  ·  Study ${sr == null ? 'not rated' : '★$sr'}';
      color = days < 0 ? Colors.redAccent : C.orange;
      icon = Icons.refresh_rounded;
    } else if (kind == 'friday') {
      sub = '${Prefs.revisionMin} min${starsText(t['rating'])}';
      color = C.green;
      icon = Icons.event_available;
    } else {
      sub = '${Prefs.studyMin} min';
      color = C.accent;
      icon = Icons.auto_stories;
    }
    return Panel(
      onTap: () => _start(t, kind),
      child: Row(children: [
        IconBadge(icon, color),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('${kindLabel(kind)}  ·  $sub${((t['daily'] as num?)?.toInt() ?? 0) == 1 ? '  ·  Daily' : ''}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
            if (((t['notes'] as String?) ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(((t['notes'] as String?) ?? '').trim(),
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ]),
        ),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: color.withOpacity(0.18), shape: BoxShape.circle),
          child: Icon(Icons.play_arrow_rounded, color: color),
        ),
      ]),
    );
  }

  Future<void> _start(Map<String, dynamic> t, String kind) async {
    final slot = TimerStore.slotOf(kind);
    final cur = await TimerStore.get(slot);
    if (cur != null && !(cur.topicId == t['id'] && cur.kind == kind)) {
      if (!mounted) return;
      final ok = await confirmDialog(context, 'Replace running session?',
          'A ${cur.minutes}-minute session for "${cur.title}" is in progress. Discard it?', 'Discard');
      if (!ok) return;
      await TimerStore.cancel(slot);
    }
    final minutes = cur != null && cur.topicId == t['id'] && cur.kind == kind
        ? cur.minutes
        : (kind == 'new' ? Prefs.studyMin : Prefs.revisionMin);
    await _openTimer(t['title'] as String, minutes, t['id'] as int, kind, '${t['subject']}');
  }

  Future<void> _openTimer(String title, int minutes, int topicId, String kind, String subject) async {
    await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => TimerPage(title: title, minutes: minutes, topicId: topicId, kind: kind, subject: subject)));
    await load();
    widget.onChanged();
  }
}
