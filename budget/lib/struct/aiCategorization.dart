import 'dart:convert';
import 'package:http/http.dart' as http;

// A category the model is allowed to choose from. Only id + name are ever sent
// to Gemini — never amounts, accounts, or raw email content.
class AiCategoryChoice {
  final String id;
  final String name;
  const AiCategoryChoice(this.id, this.name);
}

// Classifies a merchant into one of [categories] using Gemini Flash.
// Returns the chosen category id (always one of [categories]) or null on ANY
// failure. This function never throws.
// Parses a Retry-After header (integer seconds) into a Duration, or null.
Duration? _parseRetryAfter(String? headerValue) {
  if (headerValue == null) return null;
  final seconds = int.tryParse(headerValue.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds);
}

Future<String?> aiCategorizeMerchant({
  required String merchant,
  required List<AiCategoryChoice> categories,
  required String apiKey,
  String model = 'gemini-flash-latest',
  http.Client? client,
  // Retry handling for rate limits: the free tier returns 429 on bursts.
  // On the first scan many new merchants are queried at once; retry with
  // backoff so those results aren't lost (each merchant is cached after,
  // so later scans make far fewer calls).
  int maxRetries = 4,
  Duration initialRetryDelay = const Duration(seconds: 2),
}) async {
  if (apiKey.trim().isEmpty) return null;
  if (categories.isEmpty) return null;
  if (merchant.trim().isEmpty) return null;

  final ownClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final allowedIds = categories.map((c) => c.id).toList();
    final categoryList =
        categories.map((c) => '- ${c.id}: ${c.name}').join('\n');

    final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text': 'You categorize credit-card merchants. Choose the single '
                  'best matching category for this merchant and respond with its '
                  'id.\n\nMerchant: "$merchant"\n\n'
                  'Categories:\n$categoryList'
            }
          ]
        }
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {
            'categoryId': {'type': 'STRING', 'enum': allowedIds}
          },
          'required': ['categoryId']
        }
      }
    });

    http.Response? response;
    Duration delay = initialRetryDelay;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      response = await httpClient.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          // Authenticate via header (works with newer "AQ." keys; the ?key=
          // query param does not reliably accept them).
          'x-goog-api-key': apiKey,
        },
        body: requestBody,
      );

      // Only 429 (rate limited) and 503 (overloaded) are worth retrying.
      if (response.statusCode != 429 && response.statusCode != 503) break;
      if (attempt == maxRetries) break;
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      print(
          'aiCategorizeMerchant: HTTP ${response.statusCode}, retrying in ${(retryAfter ?? delay).inSeconds}s (attempt ${attempt + 1}/$maxRetries)');
      await Future.delayed(retryAfter ?? delay);
      delay *= 2;
    }

    if (response == null || response.statusCode != 200) {
      print(
          'aiCategorizeMerchant: HTTP ${response?.statusCode}: ${response?.body}');
      return null;
    }

    final decoded = jsonDecode(response.body);
    final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'];
    if (text is! String) return null;

    final parsed = jsonDecode(text);
    if (parsed is! Map) return null;
    final chosen = parsed['categoryId'];
    if (chosen is! String) return null;

    // Enforce the contract even if the model ignores the schema.
    if (!allowedIds.contains(chosen)) return null;
    return chosen;
  } catch (e) {
    print('aiCategorizeMerchant: error: $e');
    return null;
  } finally {
    if (ownClient) httpClient.close();
  }
}
