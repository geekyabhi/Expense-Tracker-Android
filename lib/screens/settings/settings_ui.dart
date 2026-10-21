import 'package:flutter/material.dart';

import '../../services/watcher_channel.dart';

/// Small section heading used inside the settings pages.
class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );
}

/// Standard layout of a settings page: app bar plus a padded scrolling list.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: children,
        ),
      );
}

/// One permission row: a tick when granted, a Grant button when not.
class PermissionTile extends StatelessWidget {
  const PermissionTile({
    super.key,
    required this.title,
    required this.why,
    required this.granted,
    required this.onGrant,
  });
  final String title;
  final String why;
  final bool granted;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(why),
        trailing: granted
            ? const Icon(Icons.check_circle, color: Colors.green)
            : TextButton(onPressed: onGrant, child: const Text('Grant')),
      );
}

/// The Android-only features say so on other platforms.
const androidOnly = 'This is only available on Android.';

bool get onAndroid => WatcherChannel.supported;
