import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/api_service.dart';
import 'services/events_api.dart';
import 'services/events_service.dart';
import 'services/events_settings.dart';
import 'services/expense_repository.dart';
import 'services/notion_settings.dart';
import 'services/options_store.dart';
import 'services/watcher_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await NotionSettings.load();
  final options = await OptionsStore.load();
  final repo = ExpenseRepository(
      api: ApiService(settings: settings), options: options);
  await repo.init();
  if (WatcherChannel.supported) {
    try {
      await WatcherChannel.setNotion(
          settings.token, settings.databaseId, settings.autoSync);
    } catch (_) {}
  }
  final events =
      EventsService(api: EventsApi(settings: await EventsSettings.load()));
  runApp(ExpenseApp(repo: repo, events: events));
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
      seedColor: Colors.teal, brightness: brightness);
  final radius = BorderRadius.circular(14);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
          color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder:
          OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
  );
}

class ExpenseApp extends StatelessWidget {
  const ExpenseApp({super.key, required this.repo, required this.events});
  final ExpenseRepository repo;
  final EventsService events;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expensive',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: HomeScreen(repo: repo, events: events),
    );
  }
}
