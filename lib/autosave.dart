import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'backup.dart';
import 'core.dart';
import 'plan_ui.dart';

/// Keeps a full copy of all data in Documents/StudyApp, outside the app's private
/// storage, so it survives uninstall. Rewritten whenever the data changes.
class Autosave {
  static const dirPath = '/storage/emulated/0/Documents/StudyApp';
  static const keepDays = 7;
  static String _last = '';
  static String lastSaved = '';
  static Timer? _t;
  static bool _busy = false;

  static File get file => File('$dirPath/study_data.json');

  static Future<bool> hasAccess() async {
    try {
      return await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestAccess() async {
    try {
      if (await hasAccess()) return true;
      if ((await Permission.manageExternalStorage.request()).isGranted) return true;
      return (await Permission.storage.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<void> start() async {
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 60), (_) => save());
    save();
  }

  static Future<bool> exists() async {
    try {
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  /// Writes the snapshot only if something changed. Never writes an empty database
  /// (so a fresh install cannot overwrite the saved copy before recovery).
  static Future<bool> save() async {
    if (_busy) return false;
    _busy = true;
    try {
      if (!await hasAccess()) return false;
      final m = jsonDecode(await Backup.toJson()) as Map<String, dynamic>;
      final empty = Backup.tables.every((t) => ((m[t] as List?) ?? const []).isEmpty);
      if (empty) return false;
      m.remove('exportedAt');
      final cmp = jsonEncode(m);
      if (cmp == _last) return true;
      final dir = Directory(dirPath);
      await dir.create(recursive: true);
      await _rotate(dir);
      m['exportedAt'] = DateTime.now().toIso8601String();
      final tmp = File('$dirPath/study_data.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(m), flush: true);
      await tmp.rename(file.path);
      _last = cmp;
      lastSaved = m['exportedAt'] as String;
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  // First write of a new day: keep the previous file as a dated copy, drop copies older than keepDays.
  static Future<void> _rotate(Directory dir) async {
    try {
      if (!await file.exists()) return;
      final mod = await file.lastModified();
      final now = DateTime.now();
      if (mod.year == now.year && mod.month == now.month && mod.day == now.day) return;
      final h = Directory('${dir.path}/history');
      await h.create(recursive: true);
      await file.copy('${h.path}/study_data_${DateFormat('yyyyMMdd').format(mod)}.json');
      final files = h.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
      while (files.length > keepDays) {
        await files.removeAt(0).delete();
      }
    } catch (_) {}
  }

  static Future<void> restoreLatest() async {
    if (!await requestAccess()) throw 'File access not allowed';
    if (!await file.exists()) throw 'No auto-backup file found';
    await Backup.restore(await file.readAsString());
    _last = '';
  }

  /// One-time prompt on first launch after install/update.
  static Future<void> offerSetup(BuildContext context, VoidCallback onChanged) async {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool('autosaveAsked') ?? false) return;
    final n = Sqflite.firstIntValue(await AppDb.db.rawQuery('SELECT COUNT(*) FROM subjects')) ?? 0;
    if (!context.mounted) return;
    await sp.setBool('autosaveAsked', true);
    if (n == 0) {
      final ok = await confirmDialog(context, 'Recover data?',
          'If you had an auto-backup in Documents/StudyApp, restore it now. Needs file access.', 'Allow & recover');
      if (!ok || !context.mounted) return;
      try {
        await restoreLatest();
        onChanged();
        _snack(context, 'Data recovered');
      } catch (e) {
        _snack(context, '$e');
      }
    } else if (!await hasAccess()) {
      final ok = await confirmDialog(context, 'Auto-backup',
          'Keep a copy of your data in Documents/StudyApp so it survives uninstall. Needs file access.', 'Allow');
      if (!ok) return;
      if (await requestAccess()) await save();
    }
  }

  static void _snack(BuildContext c, String m) {
    if (!c.mounted) return;
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
  }
}
