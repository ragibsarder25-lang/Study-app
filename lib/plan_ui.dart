import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core.dart';
import 'planner.dart';

const _capsNew = ['Very hard', 'Hard', 'OK', 'Easy', 'Very easy'];
const _capsRev = ['Forgot it', 'Barely', 'OK', 'Good', 'Perfect'];

/// 1-5 stars. New study = difficulty, revision = recall. Returns null on "Later".
Future<int?> starDialog(BuildContext context, String title, String kind, {int initial = 0}) {
  var v = initial;
  final isNew = kind == 'new';
  final caps = isNew ? _capsNew : _capsRev;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(isNew ? 'How hard was it?' : 'How well did you recall it?'),
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
          const SizedBox(height: 6),
          Text(v == 0 ? '1 = ${caps[0]}  ·  5 = ${caps[4]}' : caps[v - 1],
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton(onPressed: v == 0 ? null : () => Navigator.pop(ctx, v), child: const Text('Save')),
        ],
      ),
    ),
  );
}

/// Asks, saves and re-plans. Returns false if skipped.
Future<bool> rateSession(BuildContext context, int sid, String title, String kind, {int initial = 0}) async {
  final r = await starDialog(context, title, kind, initial: initial);
  if (r == null) return false;
  await Plan.rate(sid, r);
  return true;
}

// ───────────────────────── Forecast ─────────────────────────
class ForecastCard extends StatefulWidget {
  const ForecastCard({super.key});
  @override
  State<ForecastCard> createState() => _ForecastCardState();
}

class _ForecastCardState extends State<ForecastCard> {
  List<DayLoad> days = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      days = await Plan.forecast();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String _label(int i, DateTime d) => i == 0 ? 'Today' : (i == 1 ? 'Tmrw' : DateFormat('E d').format(d));

  void _detail(int i, DayLoad d) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(DateFormat('EEEE, d MMM').format(d.day)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('New study: ${d.newN} topics · ${fmtMin(d.newMin)}'),
            const SizedBox(height: 6),
            Text('Scheduled revision: ${d.revN} topics · ${fmtMin(d.revMin)}'),
            const SizedBox(height: 6),
            Text('Everyday practice: ${d.dailyN} topics · ${fmtMin(d.dailyMin)}'),
            const SizedBox(height: 10),
            Text('Total ${fmtMin(d.total)} of ${fmtMin(Plan.budget)} limit',
                style: TextStyle(fontWeight: FontWeight.w600, color: d.total > Plan.budget ? Colors.redAccent : null)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  Widget _legend(Color c, String t, int min) => Expanded(
        child: Row(children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Expanded(child: Text('$t ${fmtMin(min)}', style: const TextStyle(fontSize: 11, color: Colors.white70))),
        ]),
      );

  Widget _row(int i, DayLoad d, int scale) {
    final over = d.total > Plan.budget;
    return InkWell(
      onTap: () => _detail(i, d),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 50, child: Text(_label(i, d.day), style: const TextStyle(fontSize: 12, color: Colors.white70))),
          Expanded(
            child: LayoutBuilder(builder: (_, c) {
              final w = c.maxWidth;
              double f(int m) => w * m / scale;
              return ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: SizedBox(
                  height: 14,
                  child: Stack(children: [
                    Container(color: Colors.white10),
                    Row(children: [
                      Container(width: f(d.newMin), color: C.accent),
                      Container(width: f(d.revMin), color: C.orange),
                      Container(width: f(d.dailyMin), color: C.cyan),
                    ]),
                    Positioned(left: math.min(f(Plan.budget), w - 1.5), top: 0, bottom: 0, child: Container(width: 1.5, color: Colors.white60)),
                  ]),
                ),
              );
            }),
          ),
          SizedBox(
            width: 58,
            child: Text(fmtMin(d.total),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: over ? Colors.redAccent : Colors.white70)),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var scale = Plan.budget;
    var tn = 0, tr = 0, td = 0;
    for (final d in days) {
      scale = math.max(scale, d.total);
      tn += d.newMin;
      tr += d.revMin;
      td += d.dailyMin;
    }
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Workload forecast', style: TextStyle(fontWeight: FontWeight.w600))),
          Text('${Plan.horizon} days · line = ${fmtMin(Plan.budget)} limit', style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ]),
        const SizedBox(height: 10),
        Row(children: [_legend(C.accent, 'New', tn), _legend(C.orange, 'Revision', tr), _legend(C.cyan, 'Practice', td)]),
        const SizedBox(height: 8),
        if (days.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing scheduled yet.', style: TextStyle(color: Colors.white54))),
        for (var i = 0; i < days.length; i++) _row(i, days[i], scale),
      ]),
    );
  }
}

// ───────────────────────── Settings section ─────────────────────────
class PlanSettings extends StatefulWidget {
  final VoidCallback onChanged;
  const PlanSettings({super.key, required this.onChanged});
  @override
  State<PlanSettings> createState() => _PlanSettingsState();
}

class _PlanSettingsState extends State<PlanSettings> {
  Future<void> _save() async {
    await Plan.save();
    widget.onChanged();
    if (mounted) setState(() {});
  }

  String _f(num v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);

  Widget _num(String label, num v, num step, num lo, num hi, void Function(num) set, {String unit = ''}) => Row(children: [
        Expanded(child: Text(label)),
        IconButton(
            onPressed: v - step >= lo ? () { set(v - step); _save(); } : null,
            icon: const Icon(Icons.remove_circle_outline)),
        SizedBox(width: 62, child: Text('${_f(v)}$unit', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600))),
        IconButton(
            onPressed: v + step <= hi ? () { set(v + step); _save(); } : null,
            icon: const Icon(Icons.add_circle_outline)),
      ]);

  Widget _head(String t, [String? sub]) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (sub != null) Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
      );

  /// Warns when the daily limit, session lengths and new-topics pace do not fit together.
  Widget _budgetCheck() {
    final limit = Plan.budget;
    final study = Prefs.studyMin;
    final rev = Prefs.revisionMin;
    final newMin = Plan.newPerDay * study;
    final warns = <String>[];
    if (limit < study) {
      warns.add('Daily limit ($limit min) is shorter than one study session ($study min). Raise the limit or shorten the session.');
    }
    if (limit < rev) {
      warns.add('Daily limit ($limit min) is shorter than one revision session ($rev min).');
    }
    if (Plan.newPerDay > 0 && limit >= study) {
      if (newMin >= limit) {
        warns.add('${Plan.newPerDay} new topics x $study min = $newMin min fills the whole $limit min limit, '
            'so no revisions fit and revisions cannot be moved to lighter days. '
            'Lower new topics per day or the study session, or raise the limit.');
      } else if (newMin + rev > limit) {
        warns.add('New study ($newMin min) leaves less than one revision session ($rev min) under the $limit min limit.');
      }
    }
    final left = (limit - newMin).clamp(0, limit).toInt();
    final newPct = limit == 0 ? 0 : (newMin * 100 / limit).round().clamp(0, 999);
    final revN = rev == 0 ? 0 : left ~/ rev;
    final ok = warns.isEmpty;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded, color: ok ? C.green : C.orange, size: 20),
          const SizedBox(width: 8),
          Text(ok ? 'Limits fit together' : 'Check your limits', style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Text(
            'New study about $newMin min ($newPct% of the limit). '
            'Left for revision and practice: $left min (about $revN revisions).',
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        for (final w in warns) ...[
          const SizedBox(height: 6),
          Text(w, style: const TextStyle(color: C.orange, fontSize: 12)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(children: [
          SwitchListTile(
            title: const Text('Rate difficulty after study'),
            subtitle: const Text('1-5 stars pop up when a study session ends'),
            value: Plan.askNew,
            onChanged: (v) { Plan.askNew = v; _save(); },
          ),
          SwitchListTile(
            title: const Text('Rate recall after revision'),
            subtitle: const Text('Real performance adjusts future intervals'),
            value: Plan.askRev,
            onChanged: (v) { Plan.askRev = v; _save(); },
          ),
          SwitchListTile(
            title: const Text('Remind me if I leave unrated'),
            value: Plan.notify,
            onChanged: (v) { Plan.notify = v; _save(); },
          ),
          if (Plan.notify)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _num('Remind after', Plan.notifyMin, 1, 1, 120, (v) => Plan.notifyMin = v.toInt(), unit: ' min'),
            ),
        ]),
      ),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _head('Difficulty → interval', 'Below 100% = revised sooner, above = later. Fades as real results come in.'),
          for (var i = 0; i < 5; i++)
            _num('★${i + 1}  ${_capsNew[i]}', Plan.starPct[i], 5, 20, 300, (v) => Plan.starPct[i] = v.toInt(), unit: '%'),
        ]),
      ),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _head('Adaptation rules'),
          _num('Learning from recall', Plan.adapt, 5, 0, 100, (v) => Plan.adapt = v.toInt(), unit: '%'),
          _num('Star weight fades / revision', Plan.fade, 5, 0, 100, (v) => Plan.fade = v.toInt(), unit: '%'),
          _num('Lapse at recall ≤', Plan.lapseAt, 1, 0, 3, (v) => Plan.lapseAt = v.toInt(), unit: '★'),
          _num('Lapse steps back', Plan.lapseBack, 1, 0, 5, (v) => Plan.lapseBack = v.toInt()),
          _num('Shortest interval', Plan.minDays, 0.5, 0.5, 30, (v) => Plan.minDays = v.toDouble(), unit: ' d'),
          _num('Longest interval', Plan.maxDays, 10, 10, 730, (v) => Plan.maxDays = v.toDouble(), unit: ' d'),
        ]),
      ),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _head('Time limits & forecast', 'Everyday practice = topics marked "Repeat every day".'),
          _num('Daily time limit', Plan.budget, 15, 30, 1440, (v) => Plan.budget = v.toInt(), unit: ' min'),
          _num('Move heavy days by ±', Plan.balance, 1, 0, 7, (v) => Plan.balance = v.toInt(), unit: ' d'),
          _num('New topics per day', Plan.newPerDay, 1, 0, 50, (v) => Plan.newPerDay = v.toInt()),
          _num('Practice per daily topic', Plan.practiceMin, 1, 1, 120, (v) => Plan.practiceMin = v.toInt(), unit: ' min'),
          _num('Forecast length', Plan.horizon, 7, 7, 60, (v) => Plan.horizon = v.toInt(), unit: ' d'),
        ]),
      ),
      _budgetCheck(),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.auto_fix_high_outlined),
            title: const Text('Re-plan upcoming revisions'),
            subtitle: const Text('Apply the current rules to every revision not yet due'),
            onTap: () async {
              final ok = await confirmDialog(context, 'Re-plan revisions?', 'Upcoming revision dates will be recalculated.', 'Re-plan');
              if (!ok) return;
              final n = await Plan.replanAll();
              widget.onChanged();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n revisions re-planned')));
            },
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Reset adaptive rules'),
            onTap: () async {
              final ok = await confirmDialog(context, 'Reset rules?', 'Adaptive settings go back to defaults. Intervals and timers are not touched.', 'Reset');
              if (!ok) return;
              await Plan.reset();
              await _save();
            },
          ),
        ]),
      ),
    ]);
  }
}
