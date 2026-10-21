import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Change this to your currency symbol.
const String kCurrency = '₹';

const List<String> kCategories = [
  'Food',
  'Transport',
  'Shopping',
  'Bills',
  'Other',
];

final _money = NumberFormat.currency(symbol: kCurrency, decimalDigits: 2);
String money(double v) => _money.format(v);

/// "40" for whole amounts, "12.5" otherwise (for editing fields).
String plainAmount(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class CategoryStyle {
  const CategoryStyle(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const _extraColors = [
  Color(0xFF5C6BC0),
  Color(0xFF00ACC1),
  Color(0xFF7CB342),
  Color(0xFFF4511E),
  Color(0xFF6D4C41),
  Color(0xFF3949AB),
  Color(0xFFC0A000),
];

/// Same name -> same colour every time (not String.hashCode, which isn't
/// guaranteed stable).
Color _colorFor(String name) {
  var sum = 0;
  for (final u in name.toLowerCase().codeUnits) {
    sum = (sum * 31 + u) & 0x7fffffff;
  }
  return _extraColors[sum % _extraColors.length];
}

CategoryStyle categoryStyle(String category) => switch (category) {
      'Food' => const CategoryStyle(Icons.restaurant, Color(0xFFEF6C00)),
      'Transport' =>
        const CategoryStyle(Icons.directions_car, Color(0xFF1E88E5)),
      'Shopping' => const CategoryStyle(Icons.shopping_bag, Color(0xFFD81B60)),
      'Bills' => const CategoryStyle(Icons.receipt_long, Color(0xFF8E24AA)),
      'Other' => const CategoryStyle(Icons.category, Color(0xFF00897B)),
      _ => CategoryStyle(Icons.label, _colorFor(category)),
    };

String dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return DateFormat.yMMMEd().format(d);
}
