import 'package:flutter/material.dart';
import 'core.dart';
import 'pages.dart';
import 'settings_page.dart';
import 'extra.dart';
import 'jobs_page.dart';
import 'planner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw something immediately. Startup work runs inside Boot, so a failure or a
  // hang shows up on screen instead of leaving a blank white window.
  runApp(const Boot());
}

class Boot extends StatefulWidget {
  const Boot({super.key});
  @override
  State<Boot> createState() => _BootState();
}

class _BootState extends State<Boot> {
  bool ready = false;
  String step = 'Starting…';
  String? fatal;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // Essential: without the database nothing works.
    try {
      step = 'Opening database…';
      if (mounted) setState(() {});
      await AppDb.init().timeout(const Duration(seconds: 20));
    } catch (e, st) {
      if (mounted) setState(() => fatal = 'Database failed to open:\n$e\n\n$st');
      return;
    }
    // Everything else must never stop the app from opening.
    final steps = <String, Future<void> Function()>{
      'Settings': Prefs.init,
      'Planner': Plan.init,
      'Appearance': Extra.init,
      'Notifications': Notifier.init,
      'Timers': TimerStore.sweep,
      'Reminders': Notifier.rescheduleAll,
      'Daily reminders': Extra.applyDaily,
    };
    final errors = <String>[];
    for (final e in steps.entries) {
      try {
        step = '${e.key}…';
        if (mounted) setState(() {});
        await e.value().timeout(const Duration(seconds: 6));
      } catch (err) {
        errors.add('${e.key}: $err');
      }
    }
    if (errors.isNotEmpty) debugPrint('Startup warnings:\n${errors.join('\n')}');
    if (mounted) setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (ready) return const RecursiveStudyApp();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(scaffoldBackgroundColor: C.bg),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: fatal != null
                  ? SingleChildScrollView(child: SelectableText(fatal!, style: const TextStyle(fontSize: 12)))
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(step, style: const TextStyle(color: Colors.white54)),
                    ]),
            ),
          ),
        ),
      ),
    );
  }
}

class RecursiveStudyApp extends StatelessWidget {
  const RecursiveStudyApp({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: Extra.accent,
        builder: (_, __, ___) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Recursive Study',
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: C.bg,
            cardColor: C.card,
            colorScheme: ColorScheme.fromSeed(seedColor: Extra.color, brightness: Brightness.dark),
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: C.card,
              indicatorColor: Extra.color.withOpacity(0.25),
            ),
          ),
          home: const HomePage(),
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int tab = 0;
  void refresh() => setState(() {});

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      await TimerStore.sweep();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      Dashboard(onChanged: refresh),
      SubjectsPage(onChanged: refresh),
      const JobsPage(),
      const ProgressPage(),
      SettingsPage(onChanged: refresh),
    ];
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: 'Subjects'),
          NavigationDestination(icon: Icon(Icons.work_outline), selectedIcon: Icon(Icons.work), label: 'Jobs'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Progress'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}
