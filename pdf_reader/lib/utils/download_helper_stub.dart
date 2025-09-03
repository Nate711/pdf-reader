import 'dart:typed_data';

/// Stub implementation for platforms that don't support web downloads
void downloadBytesOnWeb(Uint8List bytes, String filename, String mimeType) {
  throw UnsupportedError('Web downloads not supported on this platform');
}