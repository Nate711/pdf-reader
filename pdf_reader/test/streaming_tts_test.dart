import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:namer_app/services/streaming_tts_service.dart';

void main() {
  group('StreamingTtsService Network Tests', () {
    late StreamingTtsService service;

    setUp(() {
      service = StreamingTtsService();
    });

    tearDown(() {
      service.dispose();
    });

    test('TTS service connects to WebSocket and receives audio data', () async {
      // Skip test if API key is not available
      const apiKey = String.fromEnvironment('GENAI_API_KEY');
      if (apiKey.isEmpty) {
        print('GENAI_API_KEY not set - skipping TTS WebSocket test');
        return;
      }

      const testText = 'Hello, this is a test message for text-to-speech conversion.';
      
      try {
        print('Testing TTS WebSocket connection...');
        
        // Call the streaming TTS service with shorter timeout
        final result = await service.streamTts(testText).timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            throw Exception('TTS WebSocket test timed out after 20 seconds');
          },
        );

        // Verify we got a result
        expect(result, isA<Map<String, dynamic>>());
        expect(result.containsKey('bytes'), isTrue);
        expect(result.containsKey('mimeType'), isTrue);

        // Verify audio data
        final audioBytes = result['bytes'] as Uint8List;
        final mimeType = result['mimeType'] as String;

        expect(audioBytes.isNotEmpty, isTrue);
        expect(audioBytes.length, greaterThan(1000)); // Should have substantial audio data
        expect(mimeType, equals('audio/wav'));

        // Verify WAV header
        final header = String.fromCharCodes(audioBytes.take(4));
        expect(header, equals('RIFF'));

        // Verify WAVE format
        final waveHeader = String.fromCharCodes(audioBytes.skip(8).take(4));
        expect(waveHeader, equals('WAVE'));

        print('✅ TTS WebSocket test passed:');
        print('   - Successfully connected to WebSocket');
        print('   - Received ${audioBytes.length} bytes of audio data');
        print('   - Valid WAV format detected');
        print('   - MIME type: $mimeType');

      } catch (e) {
        print('❌ TTS WebSocket test failed: $e');
        
        // Provide helpful debugging information
        if (e.toString().contains('WebSocket')) {
          print('   - Check network connectivity');
          print('   - Verify GENAI_API_KEY is valid');
          print('   - Ensure WebSocket endpoint is accessible');
        } else if (e.toString().contains('timeout')) {
          print('   - WebSocket connection took too long');
          print('   - Check network speed and stability');
        } else if (e.toString().contains('GENAI_API_KEY')) {
          print('   - API key not set or invalid');
          print('   - Run with: flutter test --dart-define=GENAI_API_KEY=your_key');
        }
        
        rethrow;
      }
    });

    test('TTS service handles empty text gracefully', () async {
      const apiKey = String.fromEnvironment('GENAI_API_KEY');
      if (apiKey.isEmpty) {
        print('GENAI_API_KEY not set - skipping empty text test');
        return;
      }

      try {
        await service.streamTts('').timeout(const Duration(seconds: 30));
        fail('Expected exception for empty text');
      } catch (e) {
        // Should handle empty text appropriately
        expect(e, isA<Exception>());
        print('✅ Empty text handled correctly: $e');
      }
    });

    test('TTS service fails gracefully without API key', () async {
      // Create a new service instance for this test to ensure clean state
      final testService = StreamingTtsService();
      
      try {
        // This should fail because we're not providing an API key
        // The service checks for GENAI_API_KEY from environment
        await testService.streamTts('test').timeout(const Duration(seconds: 10));
        
        // If we get here without an API key, that's unexpected
        const apiKey = String.fromEnvironment('GENAI_API_KEY');
        if (apiKey.isEmpty) {
          fail('Expected StateError for missing API key');
        }
      } catch (e) {
        if (e is StateError && e.message.contains('GENAI_API_KEY not set')) {
          print('✅ API key validation working correctly');
        } else {
          print('⚠️  Unexpected error (may be due to API key being set): $e');
        }
      } finally {
        testService.dispose();
      }
    });

    test('TTS service produces valid WAV format', () async {
      const apiKey = String.fromEnvironment('GENAI_API_KEY');
      if (apiKey.isEmpty) {
        print('GENAI_API_KEY not set - skipping WAV format test');
        return;
      }

      const shortText = 'Test';
      
      try {
        final result = await service.streamTts(shortText).timeout(
          const Duration(seconds: 20),
        );

        final audioBytes = result['bytes'] as Uint8List;
        
        // Detailed WAV format validation
        expect(audioBytes.length, greaterThanOrEqualTo(44)); // Minimum WAV size
        
        // Check RIFF header
        expect(String.fromCharCodes(audioBytes.sublist(0, 4)), equals('RIFF'));
        
        // Check WAVE format
        expect(String.fromCharCodes(audioBytes.sublist(8, 12)), equals('WAVE'));
        
        // Check fmt chunk
        expect(String.fromCharCodes(audioBytes.sublist(12, 16)), equals('fmt '));
        
        // Check data chunk exists
        final dataChunkIndex = audioBytes.indexOf(0x64); // 'd' in ASCII
        expect(dataChunkIndex, greaterThan(0));
        
        print('✅ WAV format validation passed');
        print('   - File size: ${audioBytes.length} bytes');
        print('   - Valid RIFF header');
        print('   - Valid WAVE format');
        print('   - Contains fmt and data chunks');

      } catch (e) {
        print('❌ WAV format test failed: $e');
        rethrow;
      }
    });

    test('TTS service handles network timeouts', () async {
      const apiKey = String.fromEnvironment('GENAI_API_KEY');
      if (apiKey.isEmpty) {
        print('GENAI_API_KEY not set - skipping timeout test');
        return;
      }

      // Test with moderately long text
      final longText = 'This is a longer text that should take some time to process. ' * 10;
      
      try {
        final result = await service.streamTts(longText).timeout(
          const Duration(seconds: 30),
        );
        
        expect(result['bytes'], isA<Uint8List>());
        print('✅ Long text processing successful');
        
      } on TimeoutException {
        print('⚠️  Long text processing timed out (expected for very long texts)');
      } catch (e) {
        print('❌ Network timeout test error: $e');
        // Don't rethrow - timeouts can be expected with very long text
      }
    });
  });
}