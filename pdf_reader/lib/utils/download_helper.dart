import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';

// Import the appropriate implementation based on the platform
import 'download_helper_web.dart' if (dart.library.io) 'download_helper_stub.dart';

class DownloadHelper {
  static final Logger _logger = Logger();

  // Saves the PNG passed to the LLM as a downloaded file
  static Future<void> savePngForVerification(Uint8List pngBytes, int pageNumber) async {
    final filename = 'pdf_page_${pageNumber.toString().padLeft(3, '0')}.png';
    await downloadBytesAsFile(pngBytes, filename, 'image/png');
  }

  // Saves arbitrary bytes as a file
  static Future<void> downloadBytesAsFile(Uint8List bytes, String filename, String mimeType) async {
    if (kIsWeb) {
      try {
        _logger.d('Downloading file on web platform: $filename (${bytes.length} bytes, $mimeType)');
        downloadBytesOnWeb(bytes, filename, mimeType);
        _logger.i('Web download initiated: $filename');
      } catch (e) {
        _logger.e('Failed to download file on web', error: e);
      }
    } else {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final filePath = '${directory.path}/$filename';
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        _logger.i('Saved file to: $filePath');
      } catch (e) {
        _logger.e('Failed to save file', error: e);
      }
    }
  }

  // Saves a text string as a .txt file
  static Future<void> downloadTextAsFile(String text, String filename) async {
    try {
      final bytes = Uint8List.fromList(utf8.encode(text));
      await downloadBytesAsFile(bytes, filename, 'text/plain');
    } catch (e) {
      _logger.e('Failed to save text file', error: e);
    }
  }
}