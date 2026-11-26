import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'core.dart';

const jobStatuses = ['Applied', 'Admit card', 'Written', 'Viva', 'Result', 'Selected', 'Rejected'];

Color jobColor(String s) {
  switch (s) {
    case 'Selected':
      return C.green;
    case 'Rejected':
      return Colors.redAccent;
    case 'Applied':
      return C.accent;
    case 'Result':
      return C.cyan;
    default:
      return C.orange;
  }
}

class JobDb {
  static bool _ready = false;
  static Future<void> ensure() async {
    if (_ready) return;
    await AppDb.db.execute('''CREATE TABLE IF NOT EXISTS job_applications(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      org TEXT DEFAULT '',
      appliedOn TEXT NOT NULL,
      deadline TEXT,
      status TEXT NOT NULL DEFAULT 'Applied',
      notes TEXT DEFAULT '',
      cost REAL DEFAULT 0
    )''');
    // Tables created by the earlier version have no cost column.
    final cols = await AppDb.db.rawQuery('PRAGMA table_info(job_applications)');
    if (!cols.any((c) => c['name'] == 'cost')) {
      await AppDb.db.execute('ALTER TABLE job_applications ADD COLUMN cost REAL DEFAULT 0');
    }
    _ready = true;
  }
}

class JobsPage extends StatefulWidget {
  const JobsPage({super.key});
  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  List<Map<String, dynamic>> jobs = [];
  String filter = 'All';
  int sortCol = 4; // default: Applied date
  bool asc = false;

  static final _money = NumberFormat('#,##0.##');
  static final _date = DateFormat('d MMM yy');

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    await JobDb.ensure();
    jobs = await AppDb.db.query('job_applications');
    if (mounted) setState(() {});
  }

  int count(String s) => jobs.where((j) => j['status'] == s).length;
  double costOf(Map<String, dynamic> j) => (j['cost'] as num?)?.toDouble() ?? 0;

  List<Map<String, dynamic>> get shown {
    final l = (filter == 'All' ? jobs : jobs.where((j) => j['status'] == filter)).toList();
    int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
      switch (sortCol) {
        case 1:
          return '${a['title']}'.toLowerCase().compareTo('${b['title']}'.toLowerCase());
        case 2:
          return '${a['org']}'.toLowerCase().compareTo('${b['org']}'.toLowerCase());
        case 3:
          return jobStatuses.indexOf('${a['status']}').compareTo(jobStatuses.indexOf('${b['status']}'));
        case 4:
          return '${a['appliedOn']}'.compareTo('${b['appliedOn']}');
        case 5:
          // rows without a next date always go last
          final x = a['deadline'] as String?, y = b['deadline'] as String?;
          if (x == null && y == null) return 0;
          if (x == null) return asc ? 1 : -1;
          if (y == null) return asc ? -1 : 1;
          return x.compareTo(y);
        case 6:
          return costOf(a).compareTo(costOf(b));
        default:
          return 0;
      }
    }

    l.sort((a, b) => asc ? cmp(a, b) : cmp(b, a));
    return l;
  }

  Future<void> edit([Map<String, dynamic>? job]) async {
    final title = TextEditingController(text: (job?['title'] ?? '') as String);
    final org = TextEditingController(text: (job?['org'] ?? '') as String);
    final notes = TextEditingController(text: (job?['notes'] ?? '') as String);
    final c0 = (job?['cost'] as num?)?.toDouble() ?? 0;
    final cost = TextEditingController(text: c0 == 0 ? '' : _money.format(c0).replaceAll(',', ''));
    var applied = DateTime.tryParse((job?['appliedOn'] ?? '') as String) ?? DateTime.now();
    DateTime? deadline = DateTime.tryParse((job?['deadline'] ?? '') as String);
    var status = (job?['status'] ?? 'Applied') as String;
    final fmt = DateFormat('d MMM yyyy');

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(job == null ? 'Add application' : 'Edit application'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: title,
                autofocus: job == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Post / position')),
            const SizedBox(height: 8),
            TextField(
                controller: org,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Organization')),
            const SizedBox(height: 8),
            TextField(
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Application cost (Tk)', hintText: 'fee + other costs')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: jobStatuses.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => setD(() => status = v ?? status),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Applied on'),
              subtitle: Text(fmt.format(applied)),
              trailing: const Icon(Icons.calendar_today_outlined, size: 18),
              onTap: () async {
                final d = await showDatePicker(
                    context: ctx, initialDate: applied, firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (d != null) setD(() => applied = d);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Next date (exam / viva / result)'),
              subtitle: Text(deadline == null ? 'Not set' : fmt.format(deadline!)),
              trailing: deadline == null
                  ? const Icon(Icons.event_outlined, size: 18)
                  : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setD(() => deadline = null)),
              onTap: () async {
                final d = await showDatePicker(
                    context: ctx,
                    initialDate: deadline ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100));
                if (d != null) setD(() => deadline = d);
              },
            ),
            TextField(
                controller: notes,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Notes (circular no., link, roll…)')),
          ]),
          actions: [
            if (job != null)
              TextButton(
                onPressed: () async {
                  final ok = await confirmDialog(ctx, 'Delete application?', 'This cannot be undone.', 'Delete');
                  if (!ok) return;
                  await AppDb.db.delete('job_applications', where: 'id=?', whereArgs: [job['id']]);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final t = title.text.trim();
                if (t.isNotEmpty) {
                  final row = <String, Object?>{
                    'title': t,
                    'org': org.text.trim(),
                    'appliedOn': applied.toIso8601String(),
                    'deadline': deadline?.toIso8601String(),
                    'status': status,
                    'notes': notes.text.trim(),
                    'cost': double.tryParse(cost.text.trim().replaceAll(',', '')) ?? 0,
                  };
                  if (job == null) {
                    await AppDb.db.insert('job_applications', row);
                  } else {
                    await AppDb.db.update('job_applications', row, where: 'id=?', whereArgs: [job['id']]);
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    await load();
  }

  DataColumn _col(String label, {bool numeric = false, bool sortable = true, required int index}) => DataColumn(
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        numeric: numeric,
        onSort: sortable
            ? (i, a) => setState(() {
                  sortCol = i;
                  asc = a;
                })
            : null,
      );

  @override
  Widget build(BuildContext context) {
    final rows = shown;
    final totalAll = jobs.fold<double>(0, (s, j) => s + costOf(j));
    final totalShown = rows.fold<double>(0, (s, j) => s + costOf(j));

    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: () => edit(), child: const Icon(Icons.add)),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: pageTitle(context, 'Jobs',
              '${jobs.length} applied  ·  ${count('Selected')} selected  ·  ${count('Rejected')} rejected  ·  Tk ${_money.format(totalAll)} spent'),
        ),
        SizedBox(
          height: 40,
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 20), scrollDirection: Axis.horizontal, children: [
            for (final s in ['All', ...jobStatuses])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(s == 'All' ? 'All ${jobs.length}' : '$s ${count(s)}'),
                  selected: filter == s,
                  onSelected: (_) => setState(() => filter = s),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Align(alignment: Alignment.topCenter, child: EmptyState(Icons.work_outline, 'No applications here. Tap + to add one.')),
                )
              : SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                    child: DataTable(
                      showCheckboxColumn: false,
                      sortColumnIndex: sortCol == 0 ? null : (sortCol > 6 ? null : sortCol),
                      sortAscending: asc,
                      headingRowHeight: 44,
                      dataRowMinHeight: 48,
                      dataRowMaxHeight: 64,
                      columnSpacing: 22,
                      headingRowColor: WidgetStatePropertyAll(C.card),
                      border: TableBorder(
                        horizontalInside: BorderSide(color: Colors.white.withOpacity(0.06)),
                        bottom: BorderSide(color: Colors.white.withOpacity(0.06)),
                      ),
                      columns: [
                        _col('#', sortable: false, index: 0),
                        _col('Post', index: 1),
                        _col('Organization', index: 2),
                        _col('Status', index: 3),
                        _col('Applied', index: 4),
                        _col('Next date', index: 5),
                        _col('Cost (Tk)', numeric: true, index: 6),
                        _col('Notes', sortable: false, index: 7),
                      ],
                      rows: [
                        for (var i = 0; i < rows.length; i++) _row(i, rows[i]),
                        // totals row
                        DataRow(
                          color: WidgetStatePropertyAll(C.card),
                          cells: [
                            const DataCell(Text('')),
                            DataCell(Text('Total (${rows.length})', style: const TextStyle(fontWeight: FontWeight.w800))),
                            const DataCell(Text('')),
                            const DataCell(Text('')),
                            const DataCell(Text('')),
                            const DataCell(Text('')),
                            DataCell(Text(_money.format(totalShown), style: const TextStyle(fontWeight: FontWeight.w800))),
                            const DataCell(Text('')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ]),
    );
  }

  DataRow _row(int i, Map<String, dynamic> j) {
    final status = j['status'] as String;
    final color = jobColor(status);
    final applied = DateTime.tryParse(j['appliedOn'] as String);
    final dl = DateTime.tryParse((j['deadline'] as String?) ?? '');
    var dlColor = Colors.white70;
    String dlText = '—';
    if (dl != null) {
      final d = daysFromToday(dl);
      dlText = _date.format(dl);
      if (d < 0) {
        dlColor = Colors.white38;
      } else if (d <= 3) {
        dlColor = C.orange;
      }
    }
    final cost = costOf(j);
    final notes = (j['notes'] as String?) ?? '';
    return DataRow(
      onSelectChanged: (_) => edit(j),
      cells: [
        DataCell(Text('${i + 1}', style: const TextStyle(color: Colors.white38))),
        DataCell(ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(j['title'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)))),
        DataCell(ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text((j['org'] as String?) ?? '', overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)))),
        DataCell(Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(color: color.withOpacity(0.18), borderRadius: BorderRadius.circular(9)),
          child: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        )),
        DataCell(Text(applied == null ? '—' : _date.format(applied), style: const TextStyle(color: Colors.white70))),
        DataCell(Text(dlText, style: TextStyle(color: dlColor, fontWeight: dlColor == C.orange ? FontWeight.w700 : FontWeight.w400))),
        DataCell(Text(cost == 0 ? '—' : _money.format(cost))),
        DataCell(ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(notes, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)))),
      ],
    );
  }
}
