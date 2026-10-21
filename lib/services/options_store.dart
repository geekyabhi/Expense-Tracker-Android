import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/expense.dart';
import '../utils/format.dart';

enum OptionKind { category, mode, source }

extension OptionKindLabel on OptionKind {
  String get label => switch (this) {
        OptionKind.category => 'category',
        OptionKind.mode => 'mode',
        OptionKind.source => 'source',
      };
}

/// The user's own lists of categories, modes and sources (the chips in the
/// expense form). Values already used by expenses (popup app names, rows
/// imported from Notion...) are offered too; see the form.
class OptionsStore extends ChangeNotifier {
  OptionsStore({
    List<String>? categories,
    List<String>? modes,
    List<String>? sources,
    this.persist = false,
  })  : categories = [...(categories ?? kCategories)],
        modes = _withDefault([...?modes]),
        sources = [...?sources];

  /// In-memory only (tests, or when storage is unavailable).
  OptionsStore.memory() : this();

  final bool persist;
  final List<String> categories;
  final List<String> modes;
  final List<String> sources;

  static const _keys = {
    OptionKind.category: 'opt_categories',
    OptionKind.mode: 'opt_modes',
    OptionKind.source: 'opt_sources',
  };

  static List<String> _withDefault(List<String> modes) =>
      modes.any((m) => m.toLowerCase() == kDefaultMode.toLowerCase())
          ? modes
          : [kDefaultMode, ...modes];

  static Future<OptionsStore> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return OptionsStore(
        categories: p.getStringList(_keys[OptionKind.category]!),
        modes: p.getStringList(_keys[OptionKind.mode]!),
        sources: p.getStringList(_keys[OptionKind.source]!),
        persist: true,
      );
    } catch (_) {
      return OptionsStore.memory();
    }
  }

  List<String> listOf(OptionKind kind) => switch (kind) {
        OptionKind.category => categories,
        OptionKind.mode => modes,
        OptionKind.source => sources,
      };

  bool contains(OptionKind kind, String name) => listOf(kind)
      .any((o) => o.toLowerCase() == name.trim().toLowerCase());

  /// Adds [name] (trimmed). Returns the stored spelling, which is the existing
  /// one if the same name (ignoring case) is already in the list.
  Future<String> add(OptionKind kind, String name) async {
    final clean = name.replaceAll(',', ' ').trim(); // Notion tags can't hold commas
    if (clean.isEmpty) return '';
    final list = listOf(kind);
    final existing = list.where((o) => o.toLowerCase() == clean.toLowerCase());
    if (existing.isNotEmpty) return existing.first;
    list.add(clean);
    await _save(kind);
    notifyListeners();
    return clean;
  }

  /// Removes it from the list. The default mode can't be removed.
  Future<void> remove(OptionKind kind, String name) async {
    if (kind == OptionKind.mode && name == kDefaultMode) return;
    listOf(kind).removeWhere((o) => o.toLowerCase() == name.toLowerCase());
    await _save(kind);
    notifyListeners();
  }

  Future<void> _save(OptionKind kind) async {
    if (!persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_keys[kind]!, listOf(kind));
    } catch (_) {}
  }
}
