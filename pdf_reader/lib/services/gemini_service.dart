import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' as foundation;
import 'package:http/http.dart' as http;

class GeminiService {
  const GeminiService();

  Future<Map<String, dynamic>> generateVision(Uint8List pngBytes, String prompt,
      {String model = 'gemini-2.5-flash'}) async {
    const apiKey = String.fromEnvironment('GENAI_API_KEY');
    if (apiKey.isEmpty) {
      throw StateError(
        'GENAI_API_KEY not set. Run with --dart-define=GENAI_API_KEY=YOUR_KEY',
      );
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
    );

    final payload = <String, dynamic>{
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/png',
                'data': base64Encode(pngBytes),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'thinkingConfig': {'thinkingBudget': -1},
      },
    };

    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (foundation.kDebugMode) {
      foundation.debugPrint('Gemini HTTP response status: ${resp.statusCode}');
      foundation.debugPrint('Gemini HTTP response headers: ${resp.headers}');
      foundation.debugPrint('Gemini HTTP response body: ${resp.body}');
    }

    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    final firstCandidate = candidates != null && candidates.isNotEmpty
        ? candidates.first as Map<String, dynamic>
        : null;

    final finishReason = firstCandidate?['finishReason'] as String?;
    if (finishReason == 'RECITATION') {
      throw StateError(
        'Generation finished early due to recitation. Please try again or adjust the prompt.',
      );
    }

    final content = firstCandidate?['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    final buffer = StringBuffer();
    if (parts != null) {
      for (final p in parts) {
        final t = (p as Map)['text'];
        if (t is String && t.isNotEmpty) buffer.write(t);
      }
    }

    final usage = data['usageMetadata'] as Map<String, dynamic>?;
    final modelVersion =
        (data['modelVersion'] as String?) ?? model;
    String? costSummary;
    double? totalCost;
    if (usage != null) {
      final costs = _computeCosts(usage, modelVersion);
      totalCost = costs['total'] as double;
      costSummary = _formatCostSummaryFromCosts(costs, modelVersion);
    }

    return {
      'text': buffer.toString(),
      'usage': usage,
      'modelVersion': modelVersion,
      'costSummary': costSummary,
      'totalCost': totalCost,
    };
  }

  String formatTotalCost(double totalCost, int pages) {
    String fmt(double v) =>
        v < 0.01 ? v.toStringAsFixed(4) : v.toStringAsFixed(2);
    return 'Estimated total cost across $pages page(s): \$${fmt(totalCost)}';
  }

  Map<String, dynamic> _computeCosts(
      Map<String, dynamic> usage, String modelVersion) {
    int intOf(dynamic v) => v is int
        ? v
        : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0);

    final promptTok = intOf(usage['promptTokenCount']);
    final candTok = intOf(usage['candidatesTokenCount']);
    final thoughtsTok = intOf(usage['thoughtsTokenCount']);
    final outTok = candTok + thoughtsTok;

    double inputRatePerM;
    double outputRatePerM;

    if (modelVersion.contains('2.5-pro')) {
      inputRatePerM = (promptTok <= 200000) ? 1.25 : 2.50;
      outputRatePerM = (outTok <= 200000) ? 10.00 : 15.00;
    } else {
      inputRatePerM = 0.30;
      outputRatePerM = 2.50;
    }

    final inputCost = promptTok * inputRatePerM / 1e6;
    final outputCost = outTok * outputRatePerM / 1e6;
    final total = inputCost + outputCost;

    return {
      'promptTok': promptTok,
      'outTok': outTok,
      'inputCost': inputCost,
      'outputCost': outputCost,
      'total': total,
    };
  }

  String _formatCostSummaryFromCosts(
      Map<String, dynamic> costs, String modelVersion) {
    String fmt(double v) =>
        v < 0.01 ? v.toStringAsFixed(4) : v.toStringAsFixed(2);
    final promptTok = costs['promptTok'] as int;
    final outTok = costs['outTok'] as int;
    final inputCost = (costs['inputCost'] as double);
    final outputCost = (costs['outputCost'] as double);
    final total = (costs['total'] as double);
    return 'Estimated cost: \$${fmt(total)} (input \$${fmt(inputCost)} for $promptTok tok, '
        'output \$${fmt(outputCost)} for $outTok tok; $modelVersion)';
  }
}
