import 'package:expense_tracker/services/options_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('starts with the default categories and the Direct mode', () {
    final o = OptionsStore.memory();
    expect(o.categories, ['Food', 'Transport', 'Shopping', 'Bills', 'Other']);
    expect(o.modes, ['Direct']);
    expect(o.sources, isEmpty);
  });

  test('adding trims, ignores duplicates (any case) and returns the stored name',
      () async {
    final o = OptionsStore.memory();
    expect(await o.add(OptionKind.source, '  HDFC  '), 'HDFC');
    expect(await o.add(OptionKind.source, 'hdfc'), 'HDFC');
    expect(o.sources, ['HDFC']);
    expect(await o.add(OptionKind.source, '   '), '');
    expect(o.sources, ['HDFC']);
  });

  test('commas are removed because Notion tags cannot contain them', () async {
    final o = OptionsStore.memory();
    expect(await o.add(OptionKind.category, 'Eating, out'), 'Eating  out');
  });

  test('the default mode cannot be removed, others can', () async {
    final o = OptionsStore.memory();
    await o.add(OptionKind.mode, 'Cash');
    await o.remove(OptionKind.mode, 'Direct');
    expect(o.modes, ['Direct', 'Cash']);
    await o.remove(OptionKind.mode, 'cash');
    expect(o.modes, ['Direct']);
  });

  test('options are saved on the device and loaded next time', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await OptionsStore.load();
    await first.add(OptionKind.category, 'Groceries');
    await first.add(OptionKind.mode, 'GPay');
    await first.add(OptionKind.source, 'SBI');

    final second = await OptionsStore.load();
    expect(second.categories, contains('Groceries'));
    expect(second.modes, containsAll(['Direct', 'GPay']));
    expect(second.sources, ['SBI']);

    await second.remove(OptionKind.source, 'SBI');
    expect((await OptionsStore.load()).sources, isEmpty);
  });
}
