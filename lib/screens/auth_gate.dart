import 'package:flutter/material.dart';

import '../services/account_controller.dart';
import '../services/events_service.dart';
import '../services/expense_repository.dart';
import 'home_screen.dart';
import 'login_screen.dart';

/// The app's front door: the expenses when signed in, the login screen when not.
/// When the session ends (signed out, or the token expired) anything open on top
/// of the home screen is closed too, so the login screen is what you see.
class AuthGate extends StatelessWidget {
  const AuthGate({
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
    return ListenableBuilder(
      listenable: account.session,
      builder: (context, _) {
        if (account.session.isSignedIn) {
          return HomeScreen(repo: repo, events: events, account: account);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        });
        return LoginScreen(account: account);
      },
    );
  }
}
