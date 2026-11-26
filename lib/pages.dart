import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core.dart';
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
  List<Map<String, dynamic>> revisions = [], newTopics = [], upcoming = [], friday = [];
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
      revisions = await AppDb.db.rawQuery("$base WHERE t.nextRevision IS NOT NULL AND t.nextRevision <= ? ORDER BY t.nextRevision", [nowS]);
      newTopics = await AppDb.db.rawQuery("$base WHERE t.completedAt IS NULL ORDER BY t.createdAt");
      upcoming = await AppDb.db.rawQuery("$base WHERE t.nextRevision IS NOT NULL AND t.nextRevision > ? ORDER BY t.nextRevision LIMIT 3", [nowS]);
      friday = (now.weekday == DateTime.friday && Prefs.fridayReview)
          ? await AppDb.db.rawQuery(
              "$base WHERE t.completedAt IS NOT NULL AND t.id NOT IN (SELECT topicId FROM sessions WHERE kind='friday' AND completed=1 AND substr(startedAt,1,10)=?) ORDER BY s.name, t.title",
              [dayKey(now)])
          : [];
      final a = await Future.wait([TimerStore.get('long'), TimerStore.get('short')]);
      active = a.whereType<ActiveTimer>().toList();
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
        if (active.isNotEmpty) ...[_activeSection(), const SizedBox(height: 14)],
        if (upcoming.isNotEmpty) ...[_upcomingSection(), const SizedBox(height: 14)],
        if (isFriday) ...[
          _section('Friday full review', friday, 'friday', 'All topics reviewed today. Great work!'),
          const SizedBox(height: 14),
        ],
        _section('Revision', revisions, 'revision', 'No revisions due.'),
        const SizedBox(height: 14),
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
          _pill(Icons.event_repeat, '${revisions.length}', 'due'),
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
    final now = DateTime.now();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('Next revisions', upcoming.length),
      ...upcoming.map((t) {
        final left = DateTime.parse(t['nextRevision'] as String).difference(now);
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
            Text(fmtCountdown(left), style: const TextStyle(fontWeight: FontWeight.w700, color: C.cyan, fontSize: 13)),
          ]),
        );
      }),
    ]);
  }

  Widget _section(String title, List<Map<String, dynamic>> items, String kind, String emptyText) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(title, items.length),
      if (items.isEmpty) EmptyState(kind == 'new' ? Icons.library_add_outlined : Icons.check_circle_outline, emptyText),
      ...items.map((t) => _tile(t, kind)),
    ]);
  }

  Widget _tile(Map<String, dynamic> t, String kind) {
    String sub;
    Color color;
    IconData icon;
    if (kind == 'revision') {
      final days = daysFromToday(DateTime.parse(t['nextRevision'] as String));
      sub = days < 0 ? 'Overdue ${-days}d' : 'Due now';
      color = days < 0 ? Colors.redAccent : C.orange;
      icon = Icons.refresh_rounded;
    } else if (kind == 'friday') {
      sub = '${Prefs.revisionMin} min';
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
            Text('${t['subject']}  ·  ${kindLabel(kind)}  ·  $sub', style: const TextStyle(color: Colors.grey, fontSize: 13)),
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


// ───────────────────────── Subjects ─────────────────────────
Future<bool> topicDialog(BuildContext context, {required int subjectId, Map<String, dynamic>? topic}) async {
  final title = TextEditingController(text: (topic?['title'] ?? '') as String);
  final notes = TextEditingController(text: (topic?['notes'] ?? '') as String);
  var changed = false;
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(topic == null ? 'Add topic' : 'Edit topic'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: title,
            autofocus: topic == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Topic / chapter')),
        const SizedBox(height: 8),
        TextField(
            controller: notes,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes (optional)')),
      ]),
      actions: [
        if (topic != null)
          TextButton(
            onPressed: () async {
              final ok = await confirmDialog(ctx, 'Delete topic?', 'This also removes its sessions.', 'Delete');
              if (!ok) return;
              await AppDb.deleteTopic(topic['id'] as int);
              changed = true;
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final t = title.text.trim();
            if (t.isNotEmpty) {
              if (topic == null) {
                await AppDb.db.insert('topics', {
                  'subjectId': subjectId,
                  'title': t,
                  'notes': notes.text.trim(),
                  'createdAt': DateTime.now().toIso8601String(),
                  'revisionCount': 0
                });
              } else {
                await AppDb.db.update('topics', {'title': t, 'notes': notes.text.trim()}, where: 'id=?', whereArgs: [topic['id']]);
              }
              changed = true;
            }
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return changed;
}

class SubjectsPage extends StatefulWidget {
  final VoidCallback onChanged;
  const SubjectsPage({super.key, required this.onChanged});
  @override
  State<SubjectsPage> createState() => _SubjectsPageState();
}

class _SubjectsPageState extends State<SubjectsPage> {
  List<Map<String, dynamic>> subjects = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    subjects = await AppDb.db.rawQuery(
        "SELECT s.id, s.name, COUNT(t.id) total, SUM(CASE WHEN t.completedAt IS NOT NULL THEN 1 ELSE 0 END) done FROM subjects s LEFT JOIN topics t ON t.subjectId=s.id GROUP BY s.id ORDER BY s.name");
    if (mounted) setState(() {});
  }

  Future<void> addSubject() async {
    final c = TextEditingController();
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Add subject'),
                content: TextField(
                    controller: c,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(hintText: 'e.g. English')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (c.text.trim().isNotEmpty) {
                          await AppDb.db.insert('subjects', {'name': c.text.trim()});
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        load();
                      },
                      child: const Text('Add'))
                ]));
  }

  Future<void> renameSubject(Map<String, dynamic> s) async {
    final c = TextEditingController(text: s['name'] as String);
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Rename subject'),
                content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (c.text.trim().isNotEmpty) {
                          await AppDb.db.update('subjects', {'name': c.text.trim()}, where: 'id=?', whereArgs: [s['id']]);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        load();
                      },
                      child: const Text('Save'))
                ]));
  }

  Future<void> subjectMenu(Map<String, dynamic> s) async {
    final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
              ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Delete subject', style: TextStyle(color: Colors.redAccent)),
                  onTap: () => Navigator.pop(ctx, 'delete')),
            ])));
    if (choice == 'rename') {
      await renameSubject(s);
    } else if (choice == 'delete') {
      if (!mounted) return;
      final ok = await confirmDialog(context, 'Delete "${s['name']}"?', 'All its topics and sessions will be removed.', 'Delete');
      if (ok) {
        await AppDb.deleteSubject(s['id'] as int);
        await load();
      }
    }
  }

  Future<void> addTopic(int subjectId) async {
    final changed = await topicDialog(context, subjectId: subjectId);
    if (changed) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton(onPressed: addSubject, child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 90), children: [
          pageTitle(context, 'Subjects', 'Tap to open · long-press for options'),
          if (subjects.isEmpty) const EmptyState(Icons.menu_book_outlined, 'No subjects yet. Tap + to add one.'),
          ...subjects.map((s) {
            final total = (s['total'] as num?)?.toInt() ?? 0;
            final done = (s['done'] as num?)?.toInt() ?? 0;
            return Panel(
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => TopicList(subject: s)));
                load();
              },
              onLongPress: () => subjectMenu(s),
              child: Row(children: [
                const IconBadge(Icons.menu_book_outlined, C.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s['name'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('$total topics  ·  $done studied', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 5),
                    ),
                  ]),
                ),
                IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => addTopic(s['id'] as int)),
              ]),
            );
          }),
        ]),
      );
}

class TopicList extends StatefulWidget {
  final Map<String, dynamic> subject;
  const TopicList({super.key, required this.subject});
  @override
  State<TopicList> createState() => _TopicListState();
}

class _TopicListState extends State<TopicList> {
  List<Map<String, dynamic>> topics = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    topics = await AppDb.db.query('topics', where: 'subjectId=?', whereArgs: [widget.subject['id']], orderBy: 'createdAt DESC');
    if (mounted) setState(() {});
  }

  String status(Map<String, dynamic> t) {
    final next = t['nextRevision'] as String?;
    if (next == null) return 'Not studied yet';
    final d = daysFromToday(DateTime.parse(next));
    if (d < 0) return 'Revision overdue ${-d}d';
    if (d == 0) return 'Revision due today';
    return 'Next revision: ${DateFormat('MMM d').format(DateTime.parse(next))}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.subject['name'] as String)),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            if (await topicDialog(context, subjectId: widget.subject['id'] as int)) await load();
          },
          child: const Icon(Icons.add),
        ),
        body: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
          itemCount: topics.isEmpty ? 1 : topics.length,
          itemBuilder: (_, i) {
            if (topics.isEmpty) return const EmptyState(Icons.library_add_outlined, 'No topics yet. Tap + to add one.');
            final t = topics[i];
            final next = t['nextRevision'] as String?;
            final overdue = next != null && daysFromToday(DateTime.parse(next)) <= 0;
            final notes = (t['notes'] as String?) ?? '';
            final rc = (t['revisionCount'] as int?) ?? 0;
            return Panel(
              onTap: () async {
                if (await topicDialog(context, subjectId: widget.subject['id'] as int, topic: t)) await load();
              },
              child: Row(children: [
                IconBadge(next == null ? Icons.fiber_new_outlined : (overdue ? Icons.refresh_rounded : Icons.check_circle_outline),
                    next == null ? C.accent : (overdue ? C.orange : C.green)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(status(t), style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(notes, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ]),
                ),
                if (next != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                    child: Text('R$rc', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  ),
              ]),
            );
          },
        ),
      );
}
