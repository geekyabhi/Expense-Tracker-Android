import 'package:expense_tracker/models/expense.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _row({String? mode, String? note}) => {
      'id': 'x',
      'title': 'Chai',
      'amount': 10.0,
      'category': 'Other',
      'date': '2026-10-21T12:00:00.000',
      'note': note,
      'source': '',
      'mode': mode,
      'synced': 0,
      'remote_id': null,
    };

void main() {
  test('a stored mode is kept as is', () {
    expect(Expense.fromDb(_row(mode: 'GPay', note: '')).mode, 'GPay');
  });

  test('no mode and no popup note means Direct', () {
    expect(Expense.fromDb(_row(mode: '', note: 'lunch with team')).mode, 'Direct');
    expect(Expense.fromDb(_row(mode: null, note: null)).mode, 'Direct');
  });

  test('old popup expenses recover the app name from the note', () {
    expect(
        Expense.fromDb(_row(mode: '', note: 'After using CRED')).mode, 'CRED');
    // A mode that was set explicitly wins over the note.
    expect(Expense.fromDb(_row(mode: 'UPI', note: 'After using CRED')).mode,
        'UPI');
  });
}
