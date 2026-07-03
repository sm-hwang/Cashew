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
Future<String?> aiCategorizeMerchant({
  required String merchant,
  required List<AiCategoryChoice> categories,
  required String apiKey,
  String model = 'gemini-flash-latest',
  http.Client? client,
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

    final response = await httpClient.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        // Authenticate via header (works with newer "AQ." keys; the ?key=
        // query param does not reliably accept them).
        'x-goog-api-key': apiKey,
      },
      body: requestBody,
    );

    if (response.statusCode != 200) {
      print(
          'aiCategorizeMerchant: HTTP ${response.statusCode}: ${response.body}');
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
