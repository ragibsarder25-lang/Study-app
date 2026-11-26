import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core.dart';
import 'extra.dart';
import 'plan_ui.dart';

class ProgressPage extends StatefulWidget {
  const ProgressPage({super.key});
  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> {
  Stats stats = Stats();
  List<Map<String, dynamic>> subjects = [];
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final s = await Stats.load();
      final rows = await AppDb.db.rawQuery(
          "SELECT s.name name, COUNT(t.id) topics, SUM(CASE WHEN t.completedAt IS NOT NULL THEN 1 ELSE 0 END) done "
          "FROM subjects s LEFT JOIN topics t ON t.subjectId=s.id GROUP BY s.id ORDER BY s.name");
      if (!mounted) return;
      setState(() {
        stats = s;
        subjects = rows;
        loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => loaded = true);
    }
  }

  Widget stat(IconData icon, Color c, String label, String value) => Expanded(
        child: Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconBadge(icon, c),
            const SizedBox(height: 10),
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(color: Colors.white54)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final maxM = stats.week.fold<int>(0, (a, b) => a > b ? a : b);
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.all(20), children: [
        pageTitle(context, 'Progress', 'Your study history'),
        Row(children: [
          stat(Icons.local_fire_department, C.orange, 'Day streak', '${stats.streak}'),
          const SizedBox(width: 10),
          stat(Icons.timer, C.cyan, 'Today', fmtMin(stats.todayMin)),
        ]),
        Row(children: [
          stat(Icons.schedule, C.blue, 'Total time', fmtMin(stats.totalMin)),
          const SizedBox(width: 10),
          stat(Icons.replay, C.green, 'Revisions', '${stats.revisionSessions}'),
        ]),
        const ForecastCard(),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Last 7 days', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            SizedBox(
              height: 130,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < stats.week.length; i++)
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text(stats.week[i] > 0 ? fmtMin(stats.week[i]) : '',
                            style: const TextStyle(fontSize: 10, color: Colors.white54)),
                        const SizedBox(height: 4),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          height: maxM == 0 ? 4 : 4 + 80 * stats.week[i] / maxM,
                          decoration: BoxDecoration(
                            color: stats.week[i] > 0 ? Extra.color : Colors.white12,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(i < stats.weekDays.length ? DateFormat('E').format(stats.weekDays[i]).substring(0, 1) : '',
                            style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      ]),
                    ),
                ],
              ),
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 10),
          child: Text('Subjects', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        ),
        if (loaded && subjects.isEmpty) const EmptyState(Icons.menu_book_outlined, 'No subjects yet.'),
        for (final s in subjects)
          Panel(
            child: Builder(builder: (_) {
              final total = (s['topics'] as num?)?.toInt() ?? 0;
              final done = (s['done'] as num?)?.toInt() ?? 0;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text('$done / $total', style: const TextStyle(color: Colors.white54)),
                ]),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : done / total,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    color: Extra.color,
                  ),
                ),
              ]);
            }),
          ),
      ]),
    );
  }
}
