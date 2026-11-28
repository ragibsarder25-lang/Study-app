import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup.dart';

/// Cloudflare Worker + D1 sync. Whole-snapshot push / pull using the existing backup format.
class Cloud {
  static String url = '', token = '', last = '';
  static SharedPreferences? _p;

  static bool get ready => url.trim().isNotEmpty && token.trim().isNotEmpty;

  static Future<void> init() async {
    try {
      _p = await SharedPreferences.getInstance();
      url = _p!.getString('cloudUrl') ?? '';
      token = _p!.getString('cloudToken') ?? '';
      last = _p!.getString('cloudLast') ?? '';
    } catch (_) {}
  }

  static Future<void> save() async {
    final p = _p;
    if (p == null) return;
    await p.setString('cloudUrl', url.trim());
    await p.setString('cloudToken', token.trim());
    await p.setString('cloudLast', last);
  }

  static Future<String> _call(String method, [String? body]) async {
    if (!ready) throw 'Set URL and token first';
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final u = Uri.parse('${url.trim().replaceAll(RegExp(r'/+$'), '')}/sync');
      final r = method == 'PUT' ? await c.putUrl(u) : await c.getUrl(u);
      r.headers.set('Authorization', 'Bearer ${token.trim()}');
      if (body != null) {
        r.headers.contentType = ContentType.json;
        r.add(utf8.encode(body));
      }
      final res = await r.close().timeout(const Duration(seconds: 40));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) throw 'Wrong token';
      if (res.statusCode == 404) throw 'Nothing in cloud yet';
      if (res.statusCode != 200) throw 'Server error ${res.statusCode}';
      return text;
    } finally {
      c.close(force: true);
    }
  }

  static Future<void> push() async {
    await _call('PUT', await Backup.toJson());
    last = DateTime.now().toIso8601String();
    await save();
  }

  static Future<void> pull() async {
    await Backup.restore(await _call('GET'));
    last = DateTime.now().toIso8601String();
    await save();
  }
}
