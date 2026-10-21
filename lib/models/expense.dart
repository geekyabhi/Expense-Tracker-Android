/// Mode of an expense added by hand. Expenses created by the close-an-app popup
/// use that app's name instead.
const String kDefaultMode = 'Direct';

class Expense {
  final String id; // client-generated UUID
  final String title;
  final double amount;
  final String category;
  final DateTime date;
  final String note;

  /// Where the money came from, e.g. "HDFC". Empty if not set.
  final String source;

  /// "Direct" for expenses added by hand, or the name of the app whose closing
  /// triggered the popup, e.g. "GPay".
  final String mode;

  /// True once the current version has reached Notion.
  final bool synced;

  /// The "Processed" checkbox of its Notion page (read-only here; refreshed by
  /// "Sync from Notion"). Drives the green/red colour of the row.
  final bool processed;

  /// Notion page id, set after the first successful push. Later pushes update
  /// that page instead of creating a duplicate.
  final String? remoteId;

  const Expense({
    required this.id,
    required this.title,
    required this.amount,
    required this.category,
    required this.date,
    this.note = '',
    this.source = '',
    this.mode = kDefaultMode,
    this.synced = false,
    this.processed = false,
    this.remoteId,
  });

  Expense copyWith({
    String? title,
    double? amount,
    String? category,
    DateTime? date,
    String? note,
    String? source,
    String? mode,
    bool? synced,
    bool? processed,
    String? remoteId,
  }) =>
      Expense(
        id: id,
        title: title ?? this.title,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        date: date ?? this.date,
        note: note ?? this.note,
        source: source ?? this.source,
        mode: mode ?? this.mode,
        synced: synced ?? this.synced,
        processed: processed ?? this.processed,
        remoteId: remoteId ?? this.remoteId,
      );

  Map<String, Object?> toDb() => {
        'id': id,
        'title': title,
        'amount': amount,
        'category': category,
        'date': date.toIso8601String(),
        'note': note,
        'source': source,
        'mode': mode,
        'synced': synced ? 1 : 0,
        'processed': processed ? 1 : 0,
        'remote_id': remoteId,
      };

  /// Popup expenses saved before Mode existed carry the app only in their note
  /// ("After using GPay"); recover it so they show the right mode.
  static String _modeFrom(String? mode, String note) {
    final m = mode?.trim() ?? '';
    if (m.isNotEmpty) return m;
    const prefix = 'After using ';
    if (note.startsWith(prefix) && note.length > prefix.length) {
      return note.substring(prefix.length).trim();
    }
    return kDefaultMode;
  }

  factory Expense.fromDb(Map<String, Object?> m) => Expense(
        id: m['id'] as String,
        title: m['title'] as String,
        amount: (m['amount'] as num).toDouble(),
        category: m['category'] as String,
        date: DateTime.parse(m['date'] as String),
        note: (m['note'] as String?) ?? '',
        source: (m['source'] as String?) ?? '',
        mode: _modeFrom(m['mode'] as String?, (m['note'] as String?) ?? ''),
        synced: (m['synced'] as int) == 1,
        processed: (m['processed'] as int?) == 1,
        remoteId: m['remote_id'] as String?,
      );
}
