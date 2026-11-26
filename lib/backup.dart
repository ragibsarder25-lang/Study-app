import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'core.dart';
import 'extra.dart';
import 'jobs_page.dart';

class Backup {
  // Insert order matters (parents first).
  static const tables = ['subjects', 'topics', 'sessions', 'job_applications'];

  static String _stamp() => DateFormat('yyyyMMdd_HHmm').format(DateTime.now());

  static Future<String> toJson() async {
    await JobDb.ensure();
    final data = <String, dynamic>{
      'app': 'recursive_study',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    for (final t in tables) {
      data[t] = await AppDb.db.query(t);
    }
    return const JsonEncoder.withIndent(' ').convert(data);
  }

  static Future<File> _write(String name, String content) async {
    final f = File('${Directory.systemTemp.path}/$name');
    await f.writeAsString(content, flush: true);
    return f;
  }

  static Future<void> shareBackup() async {
    final f = await _write('study_backup_${_stamp()}.json', await toJson());
    await Share.shareXFiles([XFile(f.path, mimeType: 'application/json')], subject: 'Study backup');
  }

  static String _csv(List<List<Object?>> rows) {
    String esc(Object? v) {
      final s = '${v ?? ''}';
      final needs = s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');
      return needs ? '"${s.replaceAll('"', '""')}"' : s;
    }

    // BOM so Excel opens Bangla text correctly.
    return '\uFEFF${rows.map((r) => r.map(esc).join(',')).join('\r\n')}\r\n';
  }

  static Future<void> shareJobsCsv() async {
    await JobDb.ensure();
    final rows = await AppDb.db.query('job_applications', orderBy: 'appliedOn');
    String d(Object? v) {
      final x = DateTime.tryParse('${v ?? ''}');
      return x == null ? '' : DateFormat('yyyy-MM-dd').format(x);
    }

    final csv = _csv([
      ['Post', 'Organization', 'Status', 'Applied on', 'Next date', 'Cost (Tk)', 'Notes'],
      for (final r in rows) [r['title'], r['org'], r['status'], d(r['appliedOn']), d(r['deadline']), r['cost'], r['notes']],
    ]);
    final f = await _write('job_applications_${_stamp()}.csv', csv);
    await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: 'Job applications');
  }

  /// Returns false if the user cancelled the file picker.
  static Future<bool> restoreFromPicker() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    if (res == null || res.files.isEmpty) return false;
    final f = res.files.first;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) throw 'Could not read the file';
    await restore(utf8.decode(bytes));
    return true;
  }

  static Future<void> restore(String text) async {
    final m = jsonDecode(text);
    if (m is! Map || m['app'] != 'recursive_study') throw 'Not a Recursive Study backup';
    List<Map<String, dynamic>> rows(String t) =>
        ((m[t] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final parsed = {for (final t in tables) t: rows(t)}; // validate everything before touching data

    await JobDb.ensure();
    await TimerStore.cancel('long');
    await TimerStore.cancel('short');
    await AppDb.db.transaction((txn) async {
      for (final t in tables.reversed) {
        await txn.delete(t);
      }
      for (final t in tables) {
        for (final r in parsed[t]!) {
          await txn.insert(t, r);
        }
      }
    });
    await Notifier.rescheduleAll();
    await Extra.applyDaily();
  }
}
