import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'core.dart';
import 'plan_ui.dart';
import 'planner.dart';

class RingPainter extends CustomPainter {
  final double remaining;
  RingPainter(this.remaining);
  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 14.0;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withOpacity(0.08);
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);
    final sweep = 2 * math.pi * remaining.clamp(0.0, 1.0);
    if (sweep <= 0.001) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [C.cyan, C.accent, C.cyan],
        transform: GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, arc);
  }

  @override
  bool shouldRepaint(RingPainter old) => old.remaining != remaining;
}

class TimerPage extends StatefulWidget {
  final String title, kind, subject;
  final int minutes, topicId;
  const TimerPage({
    super.key,
    required this.title,
    required this.minutes,
    required this.topicId,
    required this.kind,
    this.subject = '',
  });
  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  ActiveTimer? t;
  Timer? ticker;
  bool done = false;
  String notes = '';

  String get slot => TimerStore.slotOf(widget.kind);
  int get totalMs => (t?.minutes ?? widget.minutes) * 60000;
  int get leftMs => t?.leftMs() ?? widget.minutes * 60000;
  bool get running => t?.running ?? false;
  bool get started => t != null;
  String get heading => kindLabel(widget.kind);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cur = await TimerStore.get(slot);
    if (cur != null && cur.topicId == widget.topicId && cur.kind == widget.kind) t = cur;
    try {
      final r = await AppDb.db.query('topics', columns: ['notes'], where: 'id=?', whereArgs: [widget.topicId]);
      if (r.isNotEmpty) notes = ((r.first['notes'] as String?) ?? '').trim();
    } catch (_) {}
    if (running) _startTicker();
    if (mounted) setState(() {});
  }

  void _startTicker() {
    ticker?.cancel();
    ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (running && leftMs <= 0) {
        _complete();
      } else {
        setState(() {});
      }
    });
  }

  Future<void> start() async {
    if (done) return;
    HapticFeedback.mediumImpact();
    if (t == null) {
      t = await TimerStore.start(
          kind: widget.kind,
          topicId: widget.topicId,
          title: widget.title,
          subject: widget.subject,
          minutes: widget.minutes);
    } else {
      t = await TimerStore.resume(slot) ?? t;
    }
    _startTicker();
    if (mounted) setState(() {});
  }

  Future<void> pause() async {
    if (!running) return;
    t = await TimerStore.pause(slot) ?? t;
    ticker?.cancel();
    if (mounted) setState(() {});
  }

  Future<void> _complete() async {
    if (done) return;
    final cur = t;
    if (cur == null) return;
    done = true;
    ticker?.cancel();
    final sid = await TimerStore.finalize(cur);
    HapticFeedback.heavyImpact();
    await _rate(sid);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> tryFinish() async {
    if (done) return;
    if (leftMs > 0) {
      final ok = await confirmDialog(context, 'Finish early?', 'This counts the session as completed.', 'Finish');
      if (!ok) return;
    }
    done = true;
    ticker?.cancel();
    final cur = t ??
        await TimerStore.start(
            kind: widget.kind,
            topicId: widget.topicId,
            title: widget.title,
            subject: widget.subject,
            minutes: widget.minutes);
    final sid = await TimerStore.finalize(cur);
    HapticFeedback.heavyImpact();
    await _rate(sid);
    if (mounted) Navigator.pop(context, true);
  }

  // Difficulty (study) / recall (revision) stars. "Later" skips; a reminder notification is already set.
  Future<void> _rate(int? sid) async {
    if (sid == null || !mounted) return;
    if (widget.kind == 'revision') await _rateMissingStudy();
    if (!mounted || !Plan.wants(widget.kind)) return;
    await rateSession(context, sid, widget.title, widget.kind);
  }

  // If the study session of this topic was never rated, ask for its difficulty now.
  Future<void> _rateMissingStudy() async {
    final r = await AppDb.db.query('sessions',
        columns: ['id', 'rating'],
        where: "topicId=? AND kind='new' AND completed=1",
        whereArgs: [widget.topicId],
        orderBy: 'id DESC',
        limit: 1);
    if (r.isEmpty || r.first['rating'] != null || !mounted) return;
    await rateSession(context, r.first['id'] as int, widget.title, 'new');
  }

  Future<void> reset() async {
    if (!started || done) return;
    final ok = await confirmDialog(context, 'Reset timer?', "The timer and its alarm will be cancelled. Progress won't be saved.", 'Reset');
    if (!ok) return;
    done = true;
    ticker?.cancel();
    await TimerStore.cancel(slot);
    if (mounted) Navigator.pop(context, false);
  }

  @override
  void dispose() {
    ticker?.cancel(); // the timer itself keeps running; only the screen refresh stops
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = (leftMs / 1000).ceil();
    final m = (secs ~/ 60).toString().padLeft(2, '0'), s = (secs % 60).toString().padLeft(2, '0');
    final cur = t;
    final hint = (cur != null && cur.running)
        ? 'Alarm rings at ${DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(cur.endMs))}'
        : '${widget.minutes} minute session';
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          AppBar(title: Text(heading), backgroundColor: Colors.transparent),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(widget.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            Flexible(
              flex: 2,
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 96),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: C.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Row(children: [
                      Icon(Icons.notes_rounded, size: 14, color: Colors.white54),
                      SizedBox(width: 6),
                      Text('Notes', style: TextStyle(fontSize: 12, color: Colors.white54, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 4),
                    Text(notes, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                  ]),
                ),
              ),
            ),
          ],
          const SizedBox(height: 30),
          SizedBox(
            width: 280,
            height: 280,
            child: CustomPaint(
              painter: RingPainter(leftMs / totalMs),
              child: Center(
                child: Text('$m:$s',
                    style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w300, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ),
          ),
          const SizedBox(height: 36),
          Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: running ? pause : start,
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(running ? 'Pause' : (started ? 'Resume' : 'Start'))),
            OutlinedButton(onPressed: tryFinish, child: const Text('Finish')),
            if (started) OutlinedButton(onPressed: reset, child: const Text('Reset')),
          ]),
          const Spacer(),
          Text(hint, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 6),
          const Text('You can leave this screen. The timer keeps running.', style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 30),
        ]),
      ),
    );
  }
}
