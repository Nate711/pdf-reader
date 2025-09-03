// Example of how to run a quick TTS integration test
// This is meant for manual testing when you have an API key

import 'dart:io';
import 'package:namer_app/services/streaming_tts_service.dart';

Future<void> main() async {
  print('🧪 Manual TTS Integration Test');
  print('==============================');
  
  const apiKey = String.fromEnvironment('GENAI_API_KEY');
  if (apiKey.isEmpty) {
    print('❌ No GENAI_API_KEY provided');
    print('   Run with: dart --define=GENAI_API_KEY=your_key test/integration_example.dart');
    exit(1);
  }

  final service = StreamingTtsService();
  
  try {
    print('📡 Connecting to Gemini Live API...');
    
    const testText = 'Hello! This is a test of the text-to-speech functionality.';
    print('📝 Converting text: "$testText"');
    
    final stopwatch = Stopwatch()..start();
    final result = await service.streamTts(testText);
    stopwatch.stop();
    
    final audioBytes = result['bytes'];
    final mimeType = result['mimeType'];
    
    print('✅ TTS conversion successful!');
    print('   ⏱️  Time taken: ${stopwatch.elapsedMilliseconds}ms');
    print('   📊 Audio data: ${audioBytes.length} bytes');
    print('   🎵 Format: $mimeType');
    
    // Verify WAV format
    final header = String.fromCharCodes(audioBytes.take(4));
    if (header == 'RIFF') {
      print('   ✅ Valid WAV format detected');
    } else {
      print('   ❌ Invalid audio format');
    }
    
    // Save to file for manual verification
    final file = File('test_output.wav');
    await file.writeAsBytes(audioBytes);
    print('   💾 Saved audio to: ${file.absolute.path}');
    print('   🎧 You can play this file to verify audio quality');
    
  } catch (e, stackTrace) {
    print('❌ TTS test failed: $e');
    print('Stack trace:');
    print(stackTrace);
    exit(1);
  } finally {
    service.dispose();
  }
  
  print('');
  print('🎉 Integration test completed successfully!');
}