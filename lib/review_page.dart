import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core.dart';
import 'plan_ui.dart';
import 'planner.dart';

/// To rate (sessions without stars), Needs review (latest rating 3 or less) and Finished.
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});
  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  List<Map<String, dynamic>> unrated = [], low = [], finished = [];
  String view = 'low';

  @override
  void initState() {
    super.initState();
    load();
  }

  static String _short(String kind) => kind == 'new' ? 'Study' : (kind == 'friday' ? 'Fri' : 'Rev');

  Future<void> load() async {
    final db = AppDb.db;
    unrated = await db.rawQuery(
        "SELECT x.id, x.kind, x.startedAt, t.title, s.name subject FROM sessions x "
        "JOIN topics t ON t.id=x.topicId JOIN subjects s ON s.id=t.subjectId "
        "WHERE x.completed=1 AND x.rating IS NULL AND x.kind IN ${Plan.kindsSql} ORDER BY x.startedAt DESC LIMIT 50");
    final rated = await db.rawQuery(
        "SELECT x.id sid, x.topicId, x.kind, x.rating, t.title, t.finished, s.name subject FROM sessions x "
        "JOIN topics t ON t.id=x.topicId JOIN subjects s ON s.id=t.subjectId "
        "WHERE x.completed=1 AND x.rating IS NOT NULL ORDER BY x.startedAt");
    final byTopic = <int, List<Map<String, dynamic>>>{};
    for (final r in rated) {
      byTopic.putIfAbsent(r['topicId'] as int, () => []).add(r);
    }
    final lows = <Map<String, dynamic>>[];
    for (final e in byTopic.entries) {
      final last = e.value.last;
      final rating = (last['rating'] as num).toInt();
      if (flagOf(last, 'finished') || rating > 3) continue;
      final hist = e.value.map((r) => '${_short(r['kind'] as String)} ${r['rating']}★').toList();
      lows.add({
        'topicId': e.key,
        'sid': last['sid'],
        'title': last['title'],
        'subject': last['subject'],
        'rating': rating,
        'history': (hist.length > 6 ? hist.sublist(hist.length - 6) : hist).join(' → '),
      });
    }
    lows.sort((a, b) {
      final c = (a['rating'] as int).compareTo(b['rating'] as int);
      return c != 0 ? c : '${a['title']}'.compareTo('${b['title']}');
    });
    low = lows;
    finished = await db.rawQuery(
        "SELECT t.*, s.name subject FROM topics t JOIN subjects s ON s.id=t.subjectId "
        "WHERE COALESCE(t.finished,0)=1 ORDER BY s.name, t.title");
    if (mounted) setState(() {});
  }

  Future<void> _rate(int sessionId, String title, {int initial = 0}) async {
    final k = await AppDb.db.query('sessions', columns: ['kind'], where: 'id=?', whereArgs: [sessionId]);
    if (k.isEmpty || !mounted) return;
    final ok = await rateSession(context, sessionId, title, '${k.first['kind']}', initial: initial);
    if (ok) await load();
  }

  Future<void> _lowActions(Map<String, dynamic> t) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.star_outline_rounded),
            title: const Text('Change latest rating'),
            onTap: () => Navigator.pop(ctx, 'rate'),
          ),
          ListTile(
            leading: const Icon(Icons.verified_outlined),
            title: const Text('Mark fully finished'),
            onTap: () => Navigator.pop(ctx, 'finish'),
          ),
        ]),
      ),
    );
    if (choice == 'rate') {
      await _rate(t['sid'] as int, '${t['title']}', initial: t['rating'] as int);
    } else if (choice == 'finish') {
      await AppDb.markFinished(t['topicId'] as int);
      await load();
    }
  }

  Future<void> _reopen(Map<String, dynamic> t) async {
    final ok = await confirmDialog(context, 'Reopen topic?', 'It will come back for revision from tomorrow.', 'Reopen');
    if (!ok) return;
    await AppDb.reopen(t['id'] as int);
    await load();
  }

  Widget _unratedTile(Map<String, dynamic> r) {
    final at = DateTime.tryParse('${r['startedAt']}');
    return Panel(
      onTap: () => _rate(r['id'] as int, '${r['title']}'),
      child: Row(children: [
        const IconBadge(Icons.star_outline_rounded, C.orange),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('${r['subject']}  ·  ${kindLabel('${r['kind']}')}${at == null ? '' : '  ·  ${DateFormat('d MMM, h:mm a').format(at)}'}',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ]),
        ),
        const Text('Rate', style: TextStyle(color: C.orange, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _lowTile(Map<String, dynamic> t) => Panel(
        onTap: () => _lowActions(t),
        child: Row(children: [
          const IconBadge(Icons.flag_outlined, C.orange),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text('${t['subject']}  ·  ${'★' * (t['rating'] as int)}${'☆' * (5 - (t['rating'] as int))}',
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 4),
              Text('${t['history']}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
          const Icon(Icons.more_vert, color: Colors.white38),
        ]),
      );

  Widget _finishedTile(Map<String, dynamic> t) => Panel(
        onTap: () => _reopen(t),
        child: Row(children: [
          const IconBadge(Icons.verified_outlined, C.green),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text('${t['subject']}  ·  Tap to reopen', style: const TextStyle(color: Colors.grey, fontSize: 13)),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final List<Widget> tiles;
    String empty;
    switch (view) {
      case 'rate':
        tiles = [for (final r in unrated) _unratedTile(r)];
        empty = 'All sessions are rated.';
        break;
      case 'finished':
        tiles = [for (final t in finished) _finishedTile(t)];
        empty = 'No finished topics yet.';
        break;
      default:
        tiles = [for (final t in low) _lowTile(t)];
        empty = 'No weak topics. Topics rated 3 stars or less appear here.';
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20), children: [
        pageTitle(context, 'Review', 'Your ratings after each session'),
        Wrap(spacing: 8, children: [
          ChoiceChip(label: Text('Needs review ${low.length}'), selected: view == 'low', onSelected: (_) => setState(() => view = 'low')),
          ChoiceChip(label: Text('To rate ${unrated.length}'), selected: view == 'rate', onSelected: (_) => setState(() => view = 'rate')),
          ChoiceChip(label: Text('Finished ${finished.length}'), selected: view == 'finished', onSelected: (_) => setState(() => view = 'finished')),
        ]),
        const SizedBox(height: 14),
        if (tiles.isEmpty) EmptyState(Icons.star_outline_rounded, empty),
        ...tiles,
      ]),
    );
  }
}
