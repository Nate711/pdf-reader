import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:namer_app/services/streaming_tts_service.dart';

void main() {
  group('WAV Conversion Tests', () {
    late StreamingTtsService service;

    setUp(() {
      service = StreamingTtsService();
    });

    tearDown(() {
      service.dispose();
    });

    test('pcmToWav creates valid WAV header', () {
      // Create sample PCM data (16-bit signed integers)
      final samplePcm = Uint8List.fromList([
        0x00, 0x00, // Sample 1: 0
        0xFF, 0x7F, // Sample 2: 32767 (max positive)
        0x00, 0x80, // Sample 3: -32768 (max negative)
        0x00, 0x00, // Sample 4: 0
      ]);

      final wav = service.pcmToWav(
        samplePcm,
        sampleRate: 24000,
        channels: 1,
        bitsPerSample: 16,
      );

      // Verify WAV file structure
      expect(wav.length, equals(44 + samplePcm.length));

      // Check RIFF header
      expect(String.fromCharCodes(wav.sublist(0, 4)), equals('RIFF'));
      
      // Check WAVE identifier
      expect(String.fromCharCodes(wav.sublist(8, 12)), equals('WAVE'));
      
      // Check fmt chunk
      expect(String.fromCharCodes(wav.sublist(12, 16)), equals('fmt '));
      
      // Check fmt chunk size (should be 16 for PCM)
      final fmtSize = ByteData.sublistView(wav, 16, 20).getUint32(0, Endian.little);
      expect(fmtSize, equals(16));
      
      // Check audio format (should be 1 for PCM)
      final audioFormat = ByteData.sublistView(wav, 20, 22).getUint16(0, Endian.little);
      expect(audioFormat, equals(1));
      
      // Check number of channels
      final channels = ByteData.sublistView(wav, 22, 24).getUint16(0, Endian.little);
      expect(channels, equals(1));
      
      // Check sample rate
      final sampleRate = ByteData.sublistView(wav, 24, 28).getUint32(0, Endian.little);
      expect(sampleRate, equals(24000));
      
      // Check bits per sample
      final bitsPerSample = ByteData.sublistView(wav, 34, 36).getUint16(0, Endian.little);
      expect(bitsPerSample, equals(16));
      
      // Check data chunk identifier
      expect(String.fromCharCodes(wav.sublist(36, 40)), equals('data'));
      
      // Check data size
      final dataSize = ByteData.sublistView(wav, 40, 44).getUint32(0, Endian.little);
      expect(dataSize, equals(samplePcm.length));
      
      // Check that PCM data is preserved
      expect(wav.sublist(44), equals(samplePcm));

      print('✅ WAV conversion test passed:');
      print('   - Valid RIFF/WAVE header');
      print('   - Correct sample rate: 24000 Hz');
      print('   - Correct bit depth: 16-bit');
      print('   - Correct channels: mono (1)');
      print('   - PCM data preserved');
    });

    test('pcmToWav handles stereo audio', () {
      // Create stereo PCM data (2 channels)
      final stereoPcm = Uint8List.fromList([
        0x00, 0x40, // Left channel sample 1
        0x00, 0xC0, // Right channel sample 1
        0x00, 0x20, // Left channel sample 2
        0x00, 0xE0, // Right channel sample 2
      ]);

      final wav = service.pcmToWav(
        stereoPcm,
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
      );

      // Check channels
      final channels = ByteData.sublistView(wav, 22, 24).getUint16(0, Endian.little);
      expect(channels, equals(2));
      
      // Check sample rate
      final sampleRate = ByteData.sublistView(wav, 24, 28).getUint32(0, Endian.little);
      expect(sampleRate, equals(44100));
      
      // Check byte rate (sample_rate * channels * bits_per_sample / 8)
      final byteRate = ByteData.sublistView(wav, 28, 32).getUint32(0, Endian.little);
      expect(byteRate, equals(44100 * 2 * 16 ~/ 8));
      
      // Check block align (channels * bits_per_sample / 8)
      final blockAlign = ByteData.sublistView(wav, 32, 34).getUint16(0, Endian.little);
      expect(blockAlign, equals(2 * 16 ~/ 8));

      print('✅ Stereo WAV conversion test passed');
    });

    test('pcmToWav handles empty PCM data', () {
      final emptyPcm = Uint8List(0);

      final wav = service.pcmToWav(
        emptyPcm,
        sampleRate: 22050,
        channels: 1,
        bitsPerSample: 16,
      );

      // Should still have valid WAV header
      expect(wav.length, equals(44)); // Just the header
      expect(String.fromCharCodes(wav.sublist(0, 4)), equals('RIFF'));
      expect(String.fromCharCodes(wav.sublist(8, 12)), equals('WAVE'));
      
      // Data size should be 0
      final dataSize = ByteData.sublistView(wav, 40, 44).getUint32(0, Endian.little);
      expect(dataSize, equals(0));

      print('✅ Empty PCM conversion test passed');
    });

    test('pcmToWav calculates file sizes correctly', () {
      final testPcm = Uint8List(1000); // 1000 bytes of PCM data

      final wav = service.pcmToWav(
        testPcm,
        sampleRate: 48000,
        channels: 1,
        bitsPerSample: 16,
      );

      // Total file size should be header (44) + data (1000)
      expect(wav.length, equals(1044));
      
      // RIFF chunk size should be total file size - 8 (RIFF header)
      final riffChunkSize = ByteData.sublistView(wav, 4, 8).getUint32(0, Endian.little);
      expect(riffChunkSize, equals(1044 - 8));
      
      // Data chunk size should equal PCM data size
      final dataChunkSize = ByteData.sublistView(wav, 40, 44).getUint32(0, Endian.little);
      expect(dataChunkSize, equals(1000));

      print('✅ WAV file size calculation test passed');
    });
  });
}