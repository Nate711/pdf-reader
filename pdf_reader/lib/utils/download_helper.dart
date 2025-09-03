import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';

class DownloadHelper {
  static final Logger _logger = Logger();

  // Saves the PNG passed to the LLM as a downloaded file
  static Future<void> savePngForVerification(Uint8List pngBytes, int pageNumber) async {
    if (kIsWeb) {
      _logger.i('PNG download not supported on web platform');
      return;
    }
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/pdf_page_${pageNumber.toString().padLeft(3, '0')}.png';
      final file = File(filePath);
      await file.writeAsBytes(pngBytes);
      _logger.i('Saved PNG to: $filePath');
    } catch (e) {
      _logger.e('Failed to save PNG', error: e);
    }
  }

  // Saves arbitrary bytes as a file
  static Future<void> downloadBytesAsFile(Uint8List bytes, String filename, String mimeType) async {
    if (kIsWeb) {
      _logger.i('File download not supported on web platform');
      return;
    }
    
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

  // Saves a text string as a .txt file
  static Future<void> downloadTextAsFile(String text, String filename) async {
    if (kIsWeb) {
      _logger.i('Text download not supported on web platform');
      return;
    }
    
    try {
      final bytes = Uint8List.fromList(utf8.encode(text));
      await downloadBytesAsFile(bytes, filename, 'text/plain');
    } catch (e) {
      _logger.e('Failed to save text file', error: e);
    }
  }
}