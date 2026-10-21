/// An event from the Notion events database: a Title and Subtitle to show, the
/// day it happens, and how often it repeats.
class AppEvent {
  const AppEvent({
    required this.id,
    required this.name,
    required this.title,
    required this.subtitle,
    required this.date,
    this.type = '',
    this.repeats = '',
  });

  final String id; // Notion page id
  final String name; // the row's own name (the title column)
  final String title; // popup title
  final String subtitle; // popup subtitle
  final DateTime date; // first day of the event (local)
  final String type; // e.g. "Anniversary"
  final String repeats; // e.g. "Yearly"; empty = once

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'title': title,
        'subtitle': subtitle,
        'date': date.toIso8601String(),
        'type': type,
        'repeats': repeats,
      };

  factory AppEvent.fromJson(Map<String, dynamic> j) => AppEvent(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        subtitle: (j['subtitle'] as String?) ?? '',
        date: DateTime.parse(j['date'] as String),
        type: (j['type'] as String?) ?? '',
        repeats: (j['repeats'] as String?) ?? '',
      );

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
  static bool _leap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  static int _daysIn(int y, int m) => DateTime(y, m + 1, 0).day;

  /// Whether the event falls on [day], taking [repeats] into account. Events
  /// never occur before their first date.
  bool occursOn(DateTime day) {
    final d = _day(day);
    final b = _day(date);
    if (d.isBefore(b)) return false;
    if (d == b) return true;

    switch (repeats.trim().toLowerCase()) {
      case 'yearly' || 'annually' || 'annual' || 'every year':
        if (d.month == b.month && d.day == b.day) return true;
        // A 29 Feb event happens on 28 Feb in years without one.
        return b.month == 2 && b.day == 29 && d.month == 2 && d.day == 28 && !_leap(d.year);
      case 'monthly' || 'every month':
        final target = b.day < _daysIn(d.year, d.month) ? b.day : _daysIn(d.year, d.month);
        return d.day == target;
      case 'weekly' || 'every week':
        final diff = DateTime.utc(d.year, d.month, d.day)
            .difference(DateTime.utc(b.year, b.month, b.day))
            .inDays;
        return diff % 7 == 0;
      case 'daily' || 'every day':
        return true;
      default:
        return false;
    }
  }
}
