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
  test('authenticates via x-goog-api-key header, not a ?key= query param',
      () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '{"categoryId": "food"}'}
                  ]
                }
              }
            ]
          }),
          200);
    });

    final result = await aiCategorizeMerchant(
      merchant: 'X',
      categories: _cats,
      apiKey: 'AQ.testkey',
      client: mock,
    );
    expect(result, 'food');
    expect(captured.headers['x-goog-api-key'], 'AQ.testkey');
    expect(captured.url.query.contains('key='), isFalse);
  });

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

  test('gives up and returns null when 429 persists past retries', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      return http.Response('rate limited', 429);
    });
    final result = await aiCategorizeMerchant(
      merchant: 'X',
      categories: _cats,
      apiKey: 'k',
      client: mock,
      maxRetries: 3,
      initialRetryDelay: Duration.zero,
    );
    expect(result, isNull);
    expect(calls, 4); // initial attempt + 3 retries
  });

  test('retries after a 429 and succeeds', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      if (calls == 1) return http.Response('rate limited', 429);
      return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '{"categoryId": "travel"}'}
                  ]
                }
              }
            ]
          }),
          200);
    });
    final result = await aiCategorizeMerchant(
      merchant: 'DELTA',
      categories: _cats,
      apiKey: 'k',
      client: mock,
      initialRetryDelay: Duration.zero,
    );
    expect(result, 'travel');
    expect(calls, 2);
  });

  test('returns null on a non-retryable HTTP error (400)', () async {
    final mock = MockClient((req) async => http.Response('bad request', 400));
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

  test('returns null and makes no call when merchant is empty', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final result = await aiCategorizeMerchant(
        merchant: '', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
    expect(called, isFalse);
  });
}
