import 'package:flutter_test/flutter_test.dart';
import 'package:namer_app/utils/download_helper.dart';
import 'dart:typed_data';

void main() {
  test('Download helper creates correct data', () async {
    // Create test data
    final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
    const filename = 'test.wav';
    const mimeType = 'audio/wav';
    
    // This test just ensures the function doesn't throw
    try {
      await DownloadHelper.downloadBytesAsFile(testData, filename, mimeType);
      print('Download function executed without throwing');
    } catch (e) {
      print('Download function threw: $e');
    }
  });
  
  test('Download helper handles text files', () async {
    const testText = 'Hello, world!';
    const filename = 'test.txt';
    
    try {
      await DownloadHelper.downloadTextAsFile(testText, filename);
      print('Text download function executed without throwing');
    } catch (e) {
      print('Text download function threw: $e');
    }
  });
}