// Standalone live smoke test for the Gemini categorization service.
//
// This is NOT a unit test (those mock HTTP). This hits the real Gemini API to
// confirm the model id and response shape against the live free tier.
//
// Run from the `budget/` directory, providing your key via env var so it never
// lands in the repo or shell history files:
//
//   GEMINI_API_KEY=your_key dart run tool/gemini_smoke_test.dart
//
// Optional: pass a merchant string and/or model id as arguments:
//
//   GEMINI_API_KEY=your_key dart run tool/gemini_smoke_test.dart "CHIPOTLE #1234"
//   GEMINI_API_KEY=your_key dart run tool/gemini_smoke_test.dart "DELTA AIR LINES" gemini-2.5-flash
//
// Exit code 0 = the call returned a valid category id; 1 = no result (see the
// printed diagnostics for why).

import 'dart:io';
import 'package:budget/struct/aiCategorization.dart';

Future<void> main(List<String> args) async {
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';
  if (apiKey.trim().isEmpty) {
    stderr.writeln('ERROR: set GEMINI_API_KEY in the environment first.');
    stderr.writeln(
        'Example: GEMINI_API_KEY=xxx dart run tool/gemini_smoke_test.dart');
    exit(2);
  }

  final merchant = args.isNotEmpty ? args[0] : 'CHIPOTLE #1234 NEW YORK NY';
  final model = args.length > 1 ? args[1] : 'gemini-2.0-flash';

  // A representative sample of category id/name pairs (ids are arbitrary here,
  // mirroring how Cashew passes its real category primary keys + names).
  const categories = [
    AiCategoryChoice('cat-dining', 'Dining'),
    AiCategoryChoice('cat-groceries', 'Groceries'),
    AiCategoryChoice('cat-transport', 'Transport'),
    AiCategoryChoice('cat-travel', 'Travel'),
    AiCategoryChoice('cat-shopping', 'Shopping'),
    AiCategoryChoice('cat-entertainment', 'Entertainment'),
  ];

  stdout.writeln('Calling Gemini ($model) for merchant: "$merchant"');
  stdout.writeln('Allowed categories: '
      '${categories.map((c) => "${c.id}=${c.name}").join(", ")}');
  stdout.writeln('---');

  final result = await aiCategorizeMerchant(
    merchant: merchant,
    categories: categories,
    apiKey: apiKey,
    model: model,
  );

  if (result == null) {
    stdout.writeln('RESULT: null (no category returned).');
    stdout.writeln('Check the diagnostic line above (HTTP status / error). '
        'A 404 usually means the model id "$model" is not available on your '
        'key/tier — try gemini-2.5-flash or gemini-1.5-flash.');
    exit(1);
  }

  final chosen = categories.firstWhere((c) => c.id == result);
  stdout.writeln('RESULT: $result  ->  ${chosen.name}');
  stdout.writeln('OK: live call succeeded and returned a valid category id.');
  exit(0);
}
