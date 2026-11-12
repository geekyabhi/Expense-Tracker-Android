import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/account_controller.dart';
import '../../services/expense_repository.dart';
import 'settings_ui.dart';

/// Folder: who is signed in, the sync mode (Auto / Manual) and signing out.
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.account, required this.repo});
  final AccountController account;
  final ExpenseRepository repo;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  AccountController get _account => widget.account;

  Future<void> _signOut({required bool everywhere}) async {
    final notUploaded = widget.repo.expenses.where((e) => !e.synced).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(everywhere ? 'Sign out of all devices?' : 'Sign out?'),
        content: Text([
          if (everywhere) 'Every device signed in to this account will have to sign in again.',
          if (notUploaded > 0)
            '$notUploaded expense${notUploaded == 1 ? ' is' : 's are'} not uploaded '
                'yet. ${notUploaded == 1 ? 'It stays' : 'They stay'} on this phone and '
                'can be uploaded when you sign back in to this account. Signing in '
                'as a different account removes ${notUploaded == 1 ? 'it' : 'them'}.'
          else
            'Your expenses stay on this phone for this account.',
        ].join('\n\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    final revoked = await _account.signOut(everywhere: everywhere);
    if (!mounted) return;
    if (!revoked && everywhere) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Signed out here, but the server could not be reached, '
              'so other devices are still signed in.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = _account.session;
    final user = session.user;
    final sync = widget.repo.sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => SettingsPage(
        title: 'Account & sync',
        children: [
          const SettingsLabel('Signed in as'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        (user?.label.isNotEmpty ?? false)
                            ? user!.label[0].toUpperCase()
                            : '?',
                        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user?.label ?? 'Not signed in',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          if ((user?.identifier ?? '').isNotEmpty &&
                              user!.identifier != user.label)
                            Text(user.identifier,
                                style: TextStyle(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (user?.googleConnected ?? false)
                      const Chip(
                          avatar: Icon(Icons.check_circle, size: 18),
                          label: Text('Google')),
                  ]),
                  const SizedBox(height: 12),
                  if (session.expiresAt != null)
                    Text(
                        'Session valid until ${DateFormat.yMMMd().add_jm().format(session.expiresAt!)}',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SettingsLabel('Sync mode'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                            value: true,
                            icon: Icon(Icons.sync),
                            label: Text('Auto')),
                        ButtonSegment(
                            value: false,
                            icon: Icon(Icons.touch_app_outlined),
                            label: Text('Manual')),
                      ],
                      selected: {sync.autoSync},
                      onSelectionChanged: (v) => sync.setAutoSync(v.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sync.autoSync
                        ? 'New expenses are uploaded right after you save them. '
                            'If you are offline or the server fails, they stay on '
                            'this phone until you push them yourself.'
                        : 'Expenses are only saved on this phone. Nothing is sent '
                            'until you select expenses and tap Push.',
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SettingsLabel('Sign out'),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                subtitle: const Text('This phone only'),
                onTap: () => _signOut(everywhere: false),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.devices_other),
                title: const Text('Sign out of all devices'),
                subtitle: const Text('Ends every session of this account'),
                onTap: () => _signOut(everywhere: true),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
