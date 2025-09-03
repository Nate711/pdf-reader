import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

class GeminiService {
  static const String _apiKey = String.fromEnvironment('GENAI_API_KEY');

  static void _ensureApiKey() {
    if (_apiKey.isEmpty) {
      throw StateError(
        'GENAI_API_KEY not set. Run with --dart-define=GENAI_API_KEY=YOUR_KEY',
      );
    }
  }

  static Future<Map<String, dynamic>> visionGenerate(
    Uint8List pngBytes,
    String prompt,
    String visionModel,
  ) async {
    _ensureApiKey();
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$visionModel:generateContent?key=$_apiKey',
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
        (data['modelVersion'] as String?) ?? 'gemini-2.5-flash';
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

  static Future<Map<String, dynamic>> tts(String text) async {
    _ensureApiKey();
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=$_apiKey',
    );
    final payload = {
      'contents': [
        {
          'parts': [
            {'text': text},
          ],
        },
      ],
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': 'Achernar'},
          },
        },
      },
      'model': 'gemini-2.5-flash-preview-tts',
    };
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('No audio in response');
    }
    final content =
        (candidates.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>;
    final parts = content['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('No parts in response');
    }
    for (final p in parts) {
      final mp = p as Map<String, dynamic>;
      final inline =
          (mp['inlineData'] as Map<String, dynamic>?) ??
          (mp['inline_data'] as Map<String, dynamic>?);
      if (inline != null) {
        final base64 = inline['data'] as String?;
        if (base64 != null) {
          final pcm = Uint8List.fromList(const Base64Decoder().convert(base64));
          final wav = _pcmToWav(
            pcm,
            sampleRate: 24000,
            channels: 1,
            bitsPerSample: 16,
          );
          return {'bytes': wav, 'mimeType': 'audio/wav'};
        }
      }
    }
    throw Exception('No inline audio found');
  }

  static Future<Map<String, dynamic>> ttsStream(
    String text, {
    void Function(Uint8List bytes)? onChunk,
  }) async {
    _ensureApiKey();
    const model = 'gemini-2.5-flash-live-preview';
    final url = Uri.parse(
      'wss://generativelanguage.googleapis.com/v1beta/models/$model:connect?key=$_apiKey',
    );
    final channel = WebSocketChannel.connect(url);
    final collected = BytesBuilder();
    final done = Completer<void>();
    final configMsg = jsonEncode({
      'config': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': 'Achernar'},
          },
        },
      },
      'model': model,
    });
    channel.sink.add(configMsg);
    final inputMsg = jsonEncode({'text': text});
    channel.sink.add(inputMsg);
    channel.stream.listen(
      (event) {
        try {
          if (event is List<int>) {
            collected.add(event);
            return;
          }
          final str = event.toString();
          final Map<String, dynamic> msg = jsonDecode(str);
          final data = msg['data'] as String?;
          if (data != null) {
            final bytes = base64Decode(data);
            collected.add(bytes);
            onChunk?.call(bytes);
          }
          final serverContent =
              msg['serverContent'] as Map<String, dynamic>?;
          if (serverContent != null && serverContent['turnComplete'] == true) {
            if (!done.isCompleted) done.complete();
          }
        } catch (_) {
          // ignore malformed frames
        }
      },
      onError: (e) {
        if (!done.isCompleted) {
          done.completeError(Exception('WebSocket error: $e'));
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future.timeout(const Duration(minutes: 2));
    try {
      channel.sink.close(ws_status.normalClosure);
    } catch (_) {}
    final pcm = collected.takeBytes();
    if (pcm.isEmpty) {
      throw Exception('No audio received from streaming TTS');
    }
    final wav = _pcmToWav(
      Uint8List.fromList(pcm),
      sampleRate: 24000,
      channels: 1,
      bitsPerSample: 16,
    );
    return {'bytes': wav, 'mimeType': 'audio/wav'};
  }

  static Map<String, dynamic> _computeCosts(
    Map<String, dynamic> usage,
    String modelVersion,
  ) {
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

  static String _formatCostSummaryFromCosts(
    Map<String, dynamic> costs,
    String modelVersion,
  ) {
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

  static String formatTotalCost(double totalCost, int pages) {
    String fmt(double v) =>
        v < 0.01 ? v.toStringAsFixed(4) : v.toStringAsFixed(2);
    return 'Estimated total cost across $pages page(s): \$${fmt(totalCost)}';
  }

  static Uint8List _pcmToWav(
    Uint8List pcm, {
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataLen = pcm.length;
    final riffChunkSize = 36 + dataLen;
    final totalDataLen = dataLen;
    final header = Uint8List(44);
    final b = header.buffer;
    void writeString(int offset, String s) {
      final bytes = s.codeUnits;
      header.setRange(offset, offset + bytes.length, bytes);
    }

    void writeUint32LE(int offset, int value) =>
        ByteData.view(b).setUint32(offset, value, Endian.little);
    void writeUint16LE(int offset, int value) =>
        ByteData.view(b).setUint16(offset, value, Endian.little);
    writeString(0, 'RIFF');
    writeUint32LE(4, riffChunkSize);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    writeUint32LE(16, 16);
    writeUint16LE(20, 1);
    writeUint16LE(22, channels);
    writeUint32LE(24, sampleRate);
    writeUint32LE(28, byteRate);
    writeUint16LE(32, blockAlign);
    writeUint16LE(34, bitsPerSample);
    writeString(36, 'data');
    writeUint32LE(40, totalDataLen);
    final out = Uint8List(header.length + pcm.length);
    out.setAll(0, header);
    out.setAll(header.length, pcm);
    return out;
  }
}

