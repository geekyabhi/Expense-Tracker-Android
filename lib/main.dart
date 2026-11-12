import 'package:flutter/material.dart';

import 'screens/auth_gate.dart';
import 'services/account_controller.dart';
import 'services/api_service.dart';
import 'services/auth_api.dart';
import 'services/events_api.dart';
import 'services/events_service.dart';
import 'services/events_settings.dart';
import 'services/expense_repository.dart';
import 'services/google_auth.dart';
import 'services/options_store.dart';
import 'services/session.dart';
import 'services/sync_settings.dart';
import 'services/watcher_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final session = Session();
  await session.load();
  final sync = await SyncSettings.load();
  final options = await OptionsStore.load();

  final repo = ExpenseRepository(
    api: ApiService(session: session),
    sync: sync,
    options: options,
  );
  await repo.init();

  final account = AccountController(
    session: session,
    auth: AuthApi(),
    repo: repo,
    google: GoogleSignInProvider(),
  );

  // The native popup and floating button upload by themselves, so they need the
  // server, the token and the Auto/Manual choice. Keep them current.
  void shareWithNative() {
    if (!WatcherChannel.supported) return;
    WatcherChannel.setBackend(
            session.serverUrl, session.token ?? '', sync.autoSync)
        .catchError((_) {});
  }

  session.addListener(shareWithNative);
  sync.addListener(shareWithNative);
  shareWithNative();

  // A returning, signed-in user gets fresh data as soon as the app opens.
  if (session.isSignedIn) repo.refreshFromServer();

  final events =
      EventsService(api: EventsApi(settings: await EventsSettings.load()));
  runApp(ExpenseApp(account: account, repo: repo, events: events));
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
  const ExpenseApp({
    super.key,
    required this.account,
    required this.repo,
    required this.events,
  });
  final AccountController account;
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
      home: AuthGate(account: account, repo: repo, events: events),
    );
  }
}
