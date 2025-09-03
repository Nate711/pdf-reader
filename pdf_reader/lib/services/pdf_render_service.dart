import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:pdf_render/pdf_render.dart';
class PdfRenderService {

  Future<ui.Image> renderPage(PdfDocument doc, int pageNumber) async {
    final page = await doc.getPage(pageNumber);

    // Render at a fixed 200 DPI.
    const dpi = 200.0;
    const scale = dpi / 72.0; // pdf_render page width/height is at 72 dpi
    final fullWidth = page.width * scale;
    final fullHeight = page.height * scale;
    final targetWidth = fullWidth.round();
    final targetHeight = fullHeight.round();

    final pageImage = await page.render(
      width: targetWidth,
      height: targetHeight,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      // backgroundFill defaults to true; keep white background
    );
    try {
      // Create a detached ui.Image and dispose the intermediate buffer
      final image = await pageImage.createImageDetached();
      return image;
    } finally {
      pageImage.dispose();
    }
  }

  Future<Uint8List> encodePngForLlm(
    ui.Image source, {
    required bool flipVertical,
  }) async {
    ui.Image? created;
    try {
      if (flipVertical) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final h = source.height.toDouble();
        // Flip vertically: translate down by height, then scale Y by -1.
        canvas.translate(0, h);
        canvas.scale(1, -1);
        canvas.drawImage(source, Offset.zero, Paint());
        final picture = recorder.endRecording();
        created = await picture.toImage(source.width, source.height);
      }

      final imgToEncode = created ?? source;
      final data = await imgToEncode.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('Failed to encode PNG');
      return data.buffer.asUint8List();
    } finally {
      // Dispose images to free GPU/CPU memory.
      if (created != null) {
        created.dispose();
        source.dispose();
      } else {
        source.dispose();
      }
    }
  }

  Future<Uint8List> pageAsPngBytes(
    PdfDocument doc,
    int pageNumber,
  ) async {
    final img = await renderPage(doc, pageNumber);
    return encodePngForLlm(img, flipVertical: kIsWeb);
  }
}