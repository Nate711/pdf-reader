import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class StreamingTtsService {
  static final Logger _logger = Logger();

  Future<Map<String, dynamic>> streamTts(String text) async {
    const apiKey = String.fromEnvironment('GENAI_API_KEY');
    if (apiKey.isEmpty) {
      throw StateError(
        'GENAI_API_KEY not set. Run with --dart-define=GENAI_API_KEY=YOUR_KEY',
      );
    }

    if (text.trim().isEmpty) {
      throw Exception('Text cannot be empty');
    }

    _logger.i('Starting TTS conversion for text (${text.length} chars)');
    _logger.i('Text preview: "${text.substring(0, text.length.clamp(0, 100))}..."');
    if (text.length > 100) {
      _logger.i('Text ending: "...${text.substring(text.length - 50)}"');
    }

    // Create explicit TTS prompt
    final ttsPrompt = 'Please read the following text aloud verbatim, word for word, without any commentary or explanation. Just speak the text exactly as written:\n\n$text';
    
    _logger.i('TTS prompt created (${ttsPrompt.length} chars total)');

    return await _generateTtsViaWebSocket(ttsPrompt, apiKey);
  }

  Future<Map<String, dynamic>> _generateTtsViaWebSocket(String text, String apiKey) async {
    _logger.i('Generating TTS via WebSocket for text: "${text.substring(0, text.length.clamp(0, 30))}..."');
    
    final wsUrl = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey';
    
    WebSocketChannel? channel;
    StreamSubscription? subscription;
    final collected = BytesBuilder();
    final completer = Completer<void>();
    bool setupComplete = false;
    
    try {
      _logger.i('Connecting to WebSocket...');
      channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      subscription = channel.stream.listen(
        (message) {
          _logger.i('Received WebSocket message: ${message.runtimeType}');
          
          // Handle both string and binary messages
          String? messageText;
          
          if (message is String) {
            messageText = message;
          } else if (message is Uint8List) {
            try {
              messageText = utf8.decode(message);
            } catch (e) {
              _logger.w('Failed to decode binary message as UTF-8: $e');
              return;
            }
          }
          
          if (messageText != null) {
            try {
              final json = jsonDecode(messageText);
              _logger.i('JSON message keys: ${json.keys.join(', ')}');
              
              if (json.containsKey('setupComplete')) {
                setupComplete = true;
                _logger.i('Setup completed, sending text message...');
                
                // Log the exact text being sent
                _logger.i('Text being sent to Gemini (${text.length} chars):');
                _logger.i('--- START TEXT ---');
                _logger.i(text);
                _logger.i('--- END TEXT ---');
                
                // Send text message for TTS
                final textMsg = jsonEncode({
                  'clientContent': {
                    'turns': [
                      {
                        'role': 'user',
                        'parts': [
                          {'text': text}
                        ]
                      }
                    ],
                    'turnComplete': true
                  }
                });
                
                _logger.i('JSON message size: ${textMsg.length} chars');
                _logger.d('Full JSON message: $textMsg');
                
                channel!.sink.add(textMsg);
              } else if (json.containsKey('serverContent')) {
                // Handle audio response
                _logger.i('Received serverContent response');
                final serverContent = json['serverContent'];
                _logger.d('ServerContent keys: ${serverContent.keys.join(', ')}');
                
                if (serverContent.containsKey('modelTurn')) {
                  final modelTurn = serverContent['modelTurn'];
                  _logger.d('ModelTurn keys: ${modelTurn.keys.join(', ')}');
                  
                  if (modelTurn.containsKey('parts')) {
                    final parts = modelTurn['parts'] as List;
                    _logger.i('Found ${parts.length} parts in modelTurn');
                    
                    for (int i = 0; i < parts.length; i++) {
                      final part = parts[i];
                      _logger.d('Part $i keys: ${part.keys.join(', ')}');
                      
                      if (part.containsKey('text')) {
                        final responseText = part['text'];
                        _logger.w('Gemini sent text response instead of audio: "$responseText"');
                      }
                      
                      if (part.containsKey('inlineData')) {
                        final inlineData = part['inlineData'];
                        final audioData = inlineData['data'] as String;
                        final mimeType = inlineData['mimeType'] as String;
                        
                        _logger.i('Found audio data: $mimeType, ${audioData.length} chars (base64)');
                        
                        // Decode base64 audio data
                        final audioBytes = base64Decode(audioData);
                        collected.add(audioBytes);
                        
                        _logger.i('Added ${audioBytes.length} bytes of decoded audio');
                        
                        if (!completer.isCompleted) {
                          completer.complete();
                        }
                      }
                    }
                  }
                } else {
                  _logger.w('ServerContent without modelTurn: ${serverContent.toString()}');
                }
              } else if (json.containsKey('error')) {
                _logger.e('WebSocket error: ${json['error']}');
                if (!completer.isCompleted) {
                  completer.completeError(Exception('WebSocket error: ${json['error']}'));
                }
              }
            } catch (e) {
              _logger.w('Non-JSON message: ${messageText.substring(0, 100)}...');
            }
          } else {
            _logger.w('Unhandled message type: ${message.runtimeType}');
          }
        },
        onError: (error) {
          _logger.e('WebSocket error: $error');
          if (!completer.isCompleted) completer.completeError(error);
        },
        onDone: () {
          _logger.i('WebSocket connection closed');
          if (!completer.isCompleted) completer.complete();
        },
      );
      
      // Send setup message
      final setupMsg = jsonEncode({
        'setup': {
          'model': 'models/gemini-live-2.5-flash-preview',
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'speechConfig': {
              'voiceConfig': {
                'prebuiltVoiceConfig': {'voiceName': 'Kore'},
              },
            },
          },
        },
      });
      
      _logger.i('Sending setup message...');
      channel.sink.add(setupMsg);
      
      // Wait for completion with timeout
      _logger.i('Waiting for audio response...');
      await completer.future.timeout(const Duration(seconds: 20));
      
      final pcmData = collected.takeBytes();
      _logger.i('Collected ${pcmData.length} bytes of raw audio data');
      
      if (pcmData.isEmpty) {
        throw Exception('No audio data received from Gemini Live. The response may have been text-only.');
      }
      
      _logger.i('Converting ${pcmData.length} bytes of PCM data to WAV...');
      
      // Convert PCM to WAV (24kHz, mono, 16-bit as indicated by Python test)
      final wav = pcmToWav(Uint8List.fromList(pcmData), sampleRate: 24000, channels: 1, bitsPerSample: 16);
      
      _logger.i('Successfully generated WAV file: ${wav.length} bytes total');
      return {'bytes': wav, 'mimeType': 'audio/wav'};
      
    } finally {
      await subscription?.cancel();
      await channel?.sink.close();
    }
  }


  // Generate mock audio for testing purposes (backup fallback)
  /* 
  Map<String, dynamic> _generateMockAudio(String text) {
    _logger.i('Generating mock audio for text length: ${text.length} characters');
    
    // Create a simple sine wave audio for testing
    const sampleRate = 24000;
    const duration = 2; // 2 seconds
    const frequency = 440; // A4 note
    
    final sampleCount = sampleRate * duration;
    final pcmData = Uint8List(sampleCount * 2); // 16-bit samples
    
    for (int i = 0; i < sampleCount; i++) {
      // Generate sine wave
      final t = i / sampleRate;
      final amplitude = 0.3; // 30% volume
      final sample = (amplitude * 32767 * (i < sampleCount / 4 ? i / (sampleCount / 4) : 1.0) * 
                     (i > 3 * sampleCount / 4 ? (sampleCount - i) / (sampleCount / 4) : 1.0) *
                     (sin(2 * pi * frequency * t))).round();
      
      // Convert to 16-bit little-endian
      pcmData[i * 2] = sample & 0xFF;
      pcmData[i * 2 + 1] = (sample >> 8) & 0xFF;
    }
    
    final wav = pcmToWav(pcmData, sampleRate: sampleRate, channels: 1, bitsPerSample: 16);
    
    _logger.i('Generated mock WAV file: ${wav.length} bytes');
    return {'bytes': wav, 'mimeType': 'audio/wav'};
  }
  */

  double sin(double x) {
    // Simple sine approximation using Taylor series (good enough for audio generation)
    double result = x;
    double term = x;
    for (int i = 1; i <= 10; i++) {
      term *= -x * x / ((2 * i) * (2 * i + 1));
      result += term;
    }
    return result;
  }

  double get pi => 3.141592653589793;

  Uint8List pcmToWav(
    Uint8List pcm, {
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) {
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final totalDataLen = pcm.length;
    final riffChunkSize = 36 + totalDataLen;
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
    writeUint32LE(16, 16); // PCM fmt chunk size
    writeUint16LE(20, 1); // audio format PCM
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

  void dispose() {
    // Clean up if needed
  }
}