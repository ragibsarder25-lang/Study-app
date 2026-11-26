import 'package:flutter/material.dart';
import 'core.dart';
import 'pages.dart';
import 'settings_page.dart';
import 'extra.dart';
import 'jobs_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.init();
  await Prefs.init();
  await Extra.init();
  await Notifier.init();
  await TimerStore.sweep();
  await Notifier.rescheduleAll();
  await Extra.applyDaily();
  runApp(const RecursiveStudyApp());
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
