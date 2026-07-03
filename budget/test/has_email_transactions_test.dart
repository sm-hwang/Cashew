import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:budget/database/tables.dart';

void main() {
  late FinanceDatabase db;
  setUp(() => db = FinanceDatabase(NativeDatabase.memory()));
  tearDown(() async => await db.close());

  Future<void> addTxn(String pk, MethodAdded? method) async {
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          transactionPk: Value(pk),
          name: 'n',
          amount: -1.0,
          note: '',
          categoryFk: 'c',
          walletFk: const Value('0'),
          dateCreated: Value(DateTime.now()),
          income: const Value(false),
          paid: const Value(true),
          methodAdded: Value(method),
        ));
  }

  test('false when there are no email transactions', () async {
    expect(await db.hasEmailTransactions(), isFalse);
    await addTxn('a', MethodAdded.csv);
    expect(await db.hasEmailTransactions(), isFalse);
  });

  test('true when at least one email transaction exists', () async {
    await addTxn('b', MethodAdded.email);
    expect(await db.hasEmailTransactions(), isTrue);
  });
}
