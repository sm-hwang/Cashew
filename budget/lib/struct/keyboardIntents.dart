import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/transactionsSearchPage.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Map<Type, Action<Intent>> keyboardIntents = {
  EscapeIntent: CallbackAction<EscapeIntent>(
    onInvoke: (EscapeIntent intent) => {
      if (navigatorKey.currentState!.canPop())
        navigatorKey.currentState!.pop()
      else
        pageNavigationFrameworkKey.currentState!
            .changePage(0, switchNavbar: true)
    },
  ),
  Digit1Intent: CallbackAction<Digit1Intent>(
    onInvoke: (Digit1Intent intent) => {
      // we are on the root of navigation pages
      if (!navigatorKey.currentState!.canPop())
        pageNavigationFrameworkKey.currentState!
            .changePage(0, switchNavbar: true)
    },
  ),
  Digit2Intent: CallbackAction<Digit2Intent>(
    onInvoke: (Digit2Intent intent) => {
      // we are on the root of navigation pages
      if (!navigatorKey.currentState!.canPop())
        pageNavigationFrameworkKey.currentState!
            .changePage(1, switchNavbar: true)
    },
  ),
  Digit3Intent: CallbackAction<Digit3Intent>(
    onInvoke: (Digit3Intent intent) => {
      // we are on the root of navigation pages
      if (!navigatorKey.currentState!.canPop())
        pageNavigationFrameworkKey.currentState!
            .changePage(2, switchNavbar: true)
    },
  ),
  Digit4Intent: CallbackAction<Digit4Intent>(
    onInvoke: (Digit4Intent intent) => {
      // we are on the root of navigation pages
      if (!navigatorKey.currentState!.canPop())
        pageNavigationFrameworkKey.currentState!
            .changePage(3, switchNavbar: true)
    },
  ),
  NewTransactionIntent: CallbackAction<NewTransactionIntent>(
    onInvoke: (NewTransactionIntent intent) {
      // Guard against stacking a second add/edit-transaction page.
      if (openAddTransactionPages == 0) {
        pushRoute(
            navigatorKey.currentContext,
            AddTransactionPage(
                routesToPopAfterDelete: RoutesToPopAfterDelete.None));
      }
      return null;
    },
  ),
  SearchTransactionsIntent: CallbackAction<SearchTransactionsIntent>(
    onInvoke: (SearchTransactionsIntent intent) {
      pushRoute(navigatorKey.currentContext, TransactionsSearchPage());
      return null;
    },
  ),
  OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
    onInvoke: (OpenSettingsIntent intent) {
      pageNavigationFrameworkKey.currentState?.changePage(3, switchNavbar: true);
      return null;
    },
  ),
  RefreshSyncIntent: CallbackAction<RefreshSyncIntent>(
    onInvoke: (RefreshSyncIntent intent) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) runAllCloudFunctions(ctx);
      return null;
    },
  ),
};

Map<ShortcutActivator, Intent> buildShortcuts({required bool isMacOS}) {
  SingleActivator mod(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: isMacOS, control: !isMacOS);
  return {
    const SingleActivator(LogicalKeyboardKey.escape): const EscapeIntent(),
    mod(LogicalKeyboardKey.digit1): const Digit1Intent(),
    mod(LogicalKeyboardKey.digit2): const Digit2Intent(),
    mod(LogicalKeyboardKey.digit3): const Digit3Intent(),
    mod(LogicalKeyboardKey.digit4): const Digit4Intent(),
    mod(LogicalKeyboardKey.keyN): const NewTransactionIntent(),
    mod(LogicalKeyboardKey.keyF): const SearchTransactionsIntent(),
    mod(LogicalKeyboardKey.comma): const OpenSettingsIntent(),
    mod(LogicalKeyboardKey.keyR): const RefreshSyncIntent(),
  };
}

Map<ShortcutActivator, Intent> shortcuts =
    buildShortcuts(isMacOS: getPlatform() == PlatformOS.isMacOS);

class EscapeIntent extends Intent {
  const EscapeIntent();
}

class Digit1Intent extends Intent {
  const Digit1Intent();
}

class Digit2Intent extends Intent {
  const Digit2Intent();
}

class Digit3Intent extends Intent {
  const Digit3Intent();
}

class Digit4Intent extends Intent {
  const Digit4Intent();
}

class NewTransactionIntent extends Intent {
  const NewTransactionIntent();
}

class SearchTransactionsIntent extends Intent {
  const SearchTransactionsIntent();
}

class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

class RefreshSyncIntent extends Intent {
  const RefreshSyncIntent();
}
