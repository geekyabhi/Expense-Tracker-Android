import 'package:flutter/material.dart';

import '../config/app_config.dart';

import '../services/account_controller.dart';
import '../services/session.dart';

/// Sign in or create an account. Email + password, phone + password and Google
/// all open the same account on the server.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.account});
  final AccountController account;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  bool _signUp = false;
  bool _showPassword = false;
  bool _busy = false;
  String? _error;

  Session get _session => widget.account.session;

  @override
  void initState() {
    super.initState();
    // After an expired session, start from the account that was signed in.
    final last = _session.user;
    if (last != null) _identifier.text = last.identifier;
  }

  @override
  void dispose() {
    _name.dispose();
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await _run(() => _signUp
        ? widget.account.signUp(kDefaultServerUrl,
            identifier: _identifier.text,
            password: _password.text,
            name: _name.text)
        : widget.account.signInWithPassword(
            kDefaultServerUrl, _identifier.text, _password.text));
  }

  Future<void> _google() => _run(() => widget.account.signInWithGoogle(kDefaultServerUrl));

  Future<void> _run(Future<AuthOutcome> Function() attempt) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await attempt();
    if (!mounted) return;
    // On success the app switches away from this screen by itself.
    setState(() {
      _busy = false;
      _error = outcome.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notice = _session.notice;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: CircleAvatar(
                        radius: 36,
                        backgroundColor: scheme.primary,
                        child: Icon(Icons.currency_rupee,
                            size: 38, color: scheme.onPrimary),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Expensive',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      _signUp ? 'Create your account' : 'Sign in to sync your expenses',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (notice != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(notice),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('Sign in')),
                        ButtonSegment(value: true, label: Text('Create account')),
                      ],
                      selected: {_signUp},
                      onSelectionChanged: _busy
                          ? null
                          : (v) => setState(() {
                                _signUp = v.first;
                                _error = null;
                              }),
                    ),
                    const SizedBox(height: 16),
                    if (_signUp) ...[
                      TextFormField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                            labelText: 'Name (optional)',
                            prefixIcon: Icon(Icons.person_outline)),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _identifier,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                          labelText: 'Email or phone',
                          hintText: 'you@example.com or +91 98765 43210',
                          prefixIcon: Icon(Icons.alternate_email)),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter your email or phone' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: !_showPassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _busy ? null : _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        helperText: _signUp ? 'At least 8 characters' : null,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Enter your password';
                        if (_signUp && v.length < 8) {
                          return 'Use at least 8 characters';
                        }
                        return null;
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: scheme.error)),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Text(_signUp ? 'Create account' : 'Sign in'),
                    ),
                    const SizedBox(height: 16),
                    Row(children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('or',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                      const Expanded(child: Divider()),
                    ]),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _google,
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      icon: const Icon(Icons.account_circle_outlined),
                      label: const Text('Continue with Google'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Email, phone and Google all open the same account. If '
                      'you signed up with Google on the website, either use '
                      'Continue with Google, or set a password on the '
                      'website\'s Profile page and sign in with your email.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
