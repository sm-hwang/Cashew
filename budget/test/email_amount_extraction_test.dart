import 'package:flutter_test/flutter_test.dart';
import 'package:budget/pages/autoTransactionsPageEmail.dart';

void main() {
  group('getTransactionAmountFromEmail', () {
    test('clean merchant (no digits) parses the amount', () {
      final amount = getTransactionAmountFromEmail(
          'notifications online.UBER EATS\$36.19*Sun, Jun 28',
          'notifications online.',
          '*');
      expect(amount, 36.19);
    });

    test('merchant ending in digits does not corrupt the amount', () {
      final amount = getTransactionAmountFromEmail(
          'notifications online.SQ COFFEE 0093\$36.19*Sun, Jun 28',
          'notifications online.',
          '*');
      expect(amount, 36.19); // not 9336.19 / 009336.19
    });

    test('merchant with digits and a thousands-separated amount', () {
      final amount = getTransactionAmountFromEmail(
          'notifications online.STORE12\$1,234.56*Sun', 'notifications online.', '*');
      expect(amount, 1234.56);
    });

    test('ignores an earlier \$1.00 threshold when anchored after it', () {
      final amount = getTransactionAmountFromEmail(
          'was more than \$1.00.You can change ... notifications online.UBER EATS\$36.19*Sun',
          'notifications online.',
          '*');
      expect(amount, 36.19);
    });

    test('backward compatible: tight-bracketed amount with cents', () {
      final amount = getTransactionAmountFromEmail('\$36.19*', '\$', '*');
      expect(amount, 36.19);
    });

    test('backward compatible: tight-bracketed amount without cents', () {
      final amount = getTransactionAmountFromEmail('\$36*', '\$', '*');
      expect(amount, 36);
    });
  });
}
