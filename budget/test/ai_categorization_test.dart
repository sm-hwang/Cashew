import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:budget/struct/aiCategorization.dart';

const _cats = [
  AiCategoryChoice('food', 'Food'),
  AiCategoryChoice('travel', 'Travel'),
];

void main() {
  test('returns the chosen category id on a valid response', () async {
    final mock = MockClient((req) async {
      // Gemini wraps the JSON output as text inside candidates.
      final body = jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '{"categoryId": "food"}'}
              ]
            }
          }
        ]
      });
      return http.Response(body, 200);
    });

    final result = await aiCategorizeMerchant(
      merchant: 'CHIPOTLE #1234',
      categories: _cats,
      apiKey: 'test-key',
      client: mock,
    );
    expect(result, 'food');
  });

  test('returns null when the model picks an id not in the list', () async {
    final mock = MockClient((req) async => http.Response(
        jsonEncode({
          'candidates': [
            {'content': {'parts': [{'text': '{"categoryId": "made-up"}'}]}}
          ]
        }),
        200));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on HTTP error (e.g. rate limit 429)', () async {
    final mock = MockClient((req) async => http.Response('rate limited', 429));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on a thrown network error (never rethrows)', () async {
    final mock = MockClient((req) async => throw Exception('no network'));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on unparseable response body', () async {
    final mock = MockClient((req) async => http.Response('not json', 200));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null and makes no call when apiKey is empty', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: '', client: mock);
    expect(result, isNull);
    expect(called, isFalse);
  });

  test('returns null and makes no call when categories is empty', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: const [], apiKey: 'k', client: mock);
    expect(result, isNull);
    expect(called, isFalse);
  });
}
