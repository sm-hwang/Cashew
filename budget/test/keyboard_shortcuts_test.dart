import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/keyboardIntents.dart';

// SingleActivator does not implement value equality, so we can't look entries
// up by key. Find the activator bound to a given intent type and inspect its
// fields instead (this is also how Flutter's Shortcuts widget reasons about it).
SingleActivator activatorFor<T extends Intent>(
    Map<ShortcutActivator, Intent> shortcuts) {
  return shortcuts.entries.firstWhere((e) => e.value is T).key as SingleActivator;
}

void main() {
  test('macOS uses Cmd (meta) modifiers, not Ctrl', () {
    final s = buildShortcuts(isMacOS: true);
    for (final t in <Type>[
      NewTransactionIntent,
      SearchTransactionsIntent,
      OpenSettingsIntent,
      RefreshSyncIntent,
      Digit1Intent,
    ]) {
      final a = s.entries.firstWhere((e) => e.value.runtimeType == t).key
          as SingleActivator;
      expect(a.meta, isTrue, reason: '$t should use meta on macOS');
      expect(a.control, isFalse, reason: '$t should not use control on macOS');
    }
    final n = activatorFor<NewTransactionIntent>(s);
    expect(n.trigger, LogicalKeyboardKey.keyN);
  });

  test('non-macOS uses Ctrl (control) modifiers, not Cmd', () {
    final s = buildShortcuts(isMacOS: false);
    final n = activatorFor<NewTransactionIntent>(s);
    expect(n.trigger, LogicalKeyboardKey.keyN);
    expect(n.control, isTrue);
    expect(n.meta, isFalse);
    final settings = activatorFor<OpenSettingsIntent>(s);
    expect(settings.trigger, LogicalKeyboardKey.comma);
    expect(settings.control, isTrue);
    expect(settings.meta, isFalse);
  });

  test('Escape is present with no modifier on both platforms', () {
    for (final isMac in [true, false]) {
      final esc = activatorFor<EscapeIntent>(buildShortcuts(isMacOS: isMac));
      expect(esc.trigger, LogicalKeyboardKey.escape);
      expect(esc.meta, isFalse);
      expect(esc.control, isFalse);
    }
  });

  test('full expected key set present', () {
    final s = buildShortcuts(isMacOS: true);
    // escape + 4 digits + N + F + comma + R
    expect(s.length, 9);
    expect(s.values.whereType<Digit4Intent>().length, 1);
    expect(s.values.whereType<RefreshSyncIntent>().length, 1);
  });
}
