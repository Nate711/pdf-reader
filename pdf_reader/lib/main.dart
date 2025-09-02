import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/foundation.dart' as foundation;
import 'package:pdf_render/pdf_render.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
// For web download of verification images
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

// Firebase AI (Gemini) setup
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Page Image',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const PdfPageImageScreen(),
    );
  }
}

class PdfPageImageScreen extends StatefulWidget {
  const PdfPageImageScreen({super.key});

  @override
  State<PdfPageImageScreen> createState() => _PdfPageImageScreenState();
}

class _PdfPageImageScreenState extends State<PdfPageImageScreen> {
  PdfDocument? _doc;
  int _pageNumber = 1;
  String _docName = 'example.pdf';
  // Selectable vision model for transcription
  String _visionModel = 'gemini-2.5-flash';
  bool _isTranscribing = false;
  bool _isSpeaking = false;
  bool _isBulkTranscribing = false;
  int _bulkProgress = 0;
  int _bulkTotal = 0;
  List<String?>? _pageTexts;
  List<String?>? _pageCostSummaries;
  String? _bulkTotalCostSummary;
  // Audio player (cross-platform)
  late final AudioPlayer _audioPlayer;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;
  PlayerState _audioState = PlayerState.stopped;
  // Scroll controller for the transcript Scrollbar/SingleChildScrollView
  late final ScrollController _transcriptScrollController;

  @override
  void initState() {
    super.initState();
    _openDocument();
    _transcriptScrollController = ScrollController();
    _audioPlayer = AudioPlayer();
    _audioPlayer.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _audioDuration = d);
    });
    _audioPlayer.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() => _audioPosition = p);
    });
    _audioPlayer.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _audioState = s);
    });
  }

  // Encodes a ui.Image to PNG bytes, optionally flipping vertically
  // to correct the Web mirroring from pdf_render.
  Future<Uint8List> _encodePngForLlm(
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

  Future<void> _openDocument() async {
    // Loads the example asset declared in pubspec.yaml
    final doc = await PdfDocument.openAsset('assets/example.pdf');
    setState(() {
      _doc = doc;
      _pageNumber = 1;
      _docName = 'example.pdf';
      _pageTexts = List<String?>.filled(doc.pageCount, null);
      _pageCostSummaries = List<String?>.filled(doc.pageCount, null);
      _bulkTotalCostSummary = null;
    });
  }

  Future<void> _pickAndOpenDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        withData: kIsWeb, // get bytes on Web
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;

      PdfDocument doc;
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null) {
          throw Exception('No file bytes returned.');
        }
        doc = await PdfDocument.openData(bytes);
      } else {
        final path = picked.path;
        if (path == null) {
          throw Exception('No file path returned.');
        }
        doc = await PdfDocument.openFile(path);
      }

      final old = _doc;
      setState(() {
        _doc = doc;
        _pageNumber = 1;
        _docName = picked.name.isNotEmpty ? picked.name : 'Document.pdf';
        _pageTexts = List<String?>.filled(doc.pageCount, null);
        _pageCostSummaries = List<String?>.filled(doc.pageCount, null);
        _bulkTotalCostSummary = null;
      });
      old?.dispose();
      // Stop any in-progress audio when switching docs
      await _audioPlayer.stop();
    } catch (e) {
      _showPersistentError('Failed to open PDF: $e');
    }
  }

  @override
  void dispose() {
    _doc?.dispose();
    _transcriptScrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _showPersistentError(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(days: 1),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: 'Dismiss', onPressed: () {}),
      ),
    );
  }

  Future<ui.Image> _renderPage(BuildContext context) async {
    return _renderPageNumber(context, _pageNumber);
  }

  Future<ui.Image> _renderPageNumber(
    BuildContext context,
    int pageNumber,
  ) async {
    final doc = _doc!;
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

  void _goToPage(int newPage) {
    if (_doc == null) return;
    final pageCount = _doc!.pageCount;
    if (newPage < 1 || newPage > pageCount) return;
    setState(() => _pageNumber = newPage);
  }

  Future<Uint8List> _currentPageAsPngBytes(BuildContext context) async {
    final img = await _renderPage(context);
    return _encodePngForLlm(img, flipVertical: kIsWeb);
  }

  Future<Uint8List> _pageAsPngBytes(
    BuildContext context,
    int pageNumber,
  ) async {
    final img = await _renderPageNumber(context, pageNumber);
    return _encodePngForLlm(img, flipVertical: kIsWeb);
  }

  Future<void> _transcribeCurrentPage() async {
    setState(() {
      _isTranscribing = true;
    });
    try {
      final prompt = await _loadPrompt();
      if (!mounted) return;

      final png = await _currentPageAsPngBytes(context);
      // Download the exact PNG sent to the LLM for orientation verification (Web only)
      _savePngForVerification(png, _pageNumber);
      final result = await _geminiVisionGenerate(png, prompt);
      if (!mounted) return;
      setState(() {
        final text = (result['text'] as String).trim();
        final cost = result['costSummary'] as String?;
        final idx = _pageNumber - 1;
        if (_pageTexts != null && idx >= 0 && idx < _pageTexts!.length) {
          _pageTexts![idx] = text;
          _pageCostSummaries![idx] = cost;
        }
      });
    } on StateError catch (e) {
      _showPersistentError(e.message);
    } catch (e) {
      _showPersistentError('Transcription failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isTranscribing = false);
      }
    }
  }

  Future<void> _speakCurrentPage() async {
    final doc = _doc;
    if (doc == null) return;
    final idx = (_pageNumber - 1).clamp(0, (doc.pageCount - 1));
    final text = (_pageTexts != null && idx < _pageTexts!.length)
        ? (_pageTexts![idx] ?? '')
        : '';
    if (text.isEmpty) {
      _showPersistentError(
        'No transcription available for this page. Transcribe first.',
      );
      return;
    }
    setState(() => _isSpeaking = true);
    try {
      final audio = await _geminiTts(text);
      final bytes = audio['bytes'] as Uint8List;
      final mimeType = (audio['mimeType'] as String?) ?? 'audio/wav';
      await _audioPlayer.stop();
      await _audioPlayer.play(BytesSource(bytes));
      // Also offer the audio as a download to the user (Web best-effort)
      final baseName =
          _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename = '${baseName}_page_${_pageNumber.toString().padLeft(3, '0')}.wav';
      _downloadBytesAsFile(bytes, filename, mimeType);
    } catch (e) {
      _showPersistentError('TTS failed: $e');
    } finally {
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  // Audio controls for the in-app player (audioplayers)
  Future<void> _audioTogglePlayPause() async {
    if (_audioState == PlayerState.playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.resume();
    }
  }

  Future<void> _audioSeek(double seconds) async {
    await _audioPlayer.seek(Duration(milliseconds: (seconds * 1000).round()));
  }

  Future<void> _transcribeAllPages() async {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      _isBulkTranscribing = true;
      _bulkProgress = 0;
      _bulkTotal = doc.pageCount;
      // Initialize per-page outputs
      _pageTexts = List<String?>.filled(doc.pageCount, null);
      _pageCostSummaries = List<String?>.filled(doc.pageCount, null);
      _bulkTotalCostSummary = null;
    });
    try {
      final prompt = await _loadPrompt();
      if (!mounted) return;

      // Kick off all page transcriptions in parallel. Each future renders
      // its page PNG and sends the HTTP request; we don't await until all
      // requests are started.
      final futures = <Future<Map<String, dynamic>>>[];
      for (var p = 1; p <= doc.pageCount; p++) {
        Future<Map<String, dynamic>> task() async {
          final png = await _pageAsPngBytes(context, p);
          // Download the exact PNG sent to the LLM for orientation verification (Web only)
          _savePngForVerification(png, p);
          final result = await _geminiVisionGenerate(png, prompt);
          return {
            'page': p,
            'text': (result['text'] as String).trim(),
            'totalCost': (result['totalCost'] as double?) ?? 0.0,
            'costSummary': result['costSummary'] as String?,
          };
        }

        final future = task().whenComplete(() {
          if (!mounted) return;
          setState(() {
            _bulkProgress += 1;
          });
        });
        futures.add(future);
      }

      // Wait for all to complete; results are in the same order as futures.
      final results = await Future.wait(futures);

      // Assemble final transcript in page order and compute total cost.
      results.sort((a, b) => (a['page'] as int).compareTo(b['page'] as int));
      double totalCost = 0.0;
      for (final r in results) {
        final p = r['page'] as int;
        final text = r['text'] as String;
        final pageCost = r['totalCost'] as double;
        final costSummary = r['costSummary'] as String?;
        if (_pageTexts != null) {
          _pageTexts![p - 1] = text;
        }
        if (_pageCostSummaries != null) {
          _pageCostSummaries![p - 1] = costSummary;
        }
        totalCost += pageCost;
      }

      if (!mounted) return;
      setState(() {
        _bulkTotalCostSummary = _formatTotalCost(totalCost, doc.pageCount);
      });

      // Download combined transcript as a single text file (Web best-effort)
      final combined = results
          .map((r) => (r['text'] as String))
          .join("\n\n");
      final baseName = _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename = '${baseName}_pages_1-${doc.pageCount}.txt';
      _downloadTextAsFile(combined, filename);
    } on StateError catch (e) {
      _showPersistentError(e.message);
    } catch (e) {
      _showPersistentError('Bulk transcription failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isBulkTranscribing = false;
        });
      }
    }
  }

  Future<void> _transcribePageRange(int startPage, int endPage) async {
    final doc = _doc;
    if (doc == null) return;

    // Normalize and validate range
    int start = startPage;
    int end = endPage;
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }
    start = start.clamp(1, doc.pageCount);
    end = end.clamp(1, doc.pageCount);
    final count = (end - start + 1);
    if (count <= 0) {
      _showPersistentError('Invalid page range.');
      return;
    }

    setState(() {
      _isBulkTranscribing = true;
      _bulkProgress = 0;
      _bulkTotal = count;
      _bulkTotalCostSummary = null;
      // Ensure per-page arrays are present and sized for this doc
      _pageTexts ??= List<String?>.filled(doc.pageCount, null);
      _pageCostSummaries ??= List<String?>.filled(doc.pageCount, null);
      if (_pageTexts!.length != doc.pageCount) {
        _pageTexts = List<String?>.filled(doc.pageCount, null);
      }
      if (_pageCostSummaries!.length != doc.pageCount) {
        _pageCostSummaries = List<String?>.filled(doc.pageCount, null);
      }
    });

    try {
      final prompt = await _loadPrompt();
      if (!mounted) return;

      final futures = <Future<Map<String, dynamic>>>[];
      for (var p = start; p <= end; p++) {
        Future<Map<String, dynamic>> task() async {
          final png = await _pageAsPngBytes(context, p);
          _savePngForVerification(png, p);
          final result = await _geminiVisionGenerate(png, prompt);
          return {
            'page': p,
            'text': (result['text'] as String).trim(),
            'totalCost': (result['totalCost'] as double?) ?? 0.0,
            'costSummary': result['costSummary'] as String?,
          };
        }

        final future = task().whenComplete(() {
          if (!mounted) return;
          setState(() {
            _bulkProgress += 1;
          });
        });
        futures.add(future);
      }

      final results = await Future.wait(futures);
      results.sort((a, b) => (a['page'] as int).compareTo(b['page'] as int));

      double totalCost = 0.0;
      for (final r in results) {
        final p = r['page'] as int;
        final text = r['text'] as String;
        final pageCost = r['totalCost'] as double;
        final costSummary = r['costSummary'] as String?;
        _pageTexts![p - 1] = text;
        _pageCostSummaries![p - 1] = costSummary;
        totalCost += pageCost;
      }

      if (!mounted) return;
      setState(() {
        _bulkTotalCostSummary = _formatTotalCost(totalCost, count);
      });

      // Download combined transcript as a single text file (Web best-effort)
      final combined = results
          .map((r) => (r['text'] as String))
          .join("\n\n");
      final baseName = _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename = '${baseName}_pages_${start}-${end}.txt';
      _downloadTextAsFile(combined, filename);
    } on StateError catch (e) {
      _showPersistentError(e.message);
    } catch (e) {
      _showPersistentError('Range transcription failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isBulkTranscribing = false);
      }
    }
  }

  Future<void> _showTranscribeRangeDialog() async {
    final doc = _doc;
    if (doc == null) return;
    final startController = TextEditingController(text: '1');
    final endController = TextEditingController(text: doc.pageCount.toString());

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Transcribe page range'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: startController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Start page',
                  hintText: 'e.g. 1',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: endController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'End page (max ${doc.pageCount})',
                  hintText: doc.pageCount.toString(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final s = int.tryParse(startController.text.trim());
                final e = int.tryParse(endController.text.trim());
                if (s == null || e == null) {
                  _showPersistentError('Enter valid page numbers.');
                  return;
                }
                Navigator.of(context).pop();
                _transcribePageRange(s, e);
              },
              child: const Text('Transcribe'),
            ),
          ],
        );
      },
    );
  }

  // Calls the Gemini REST API over HTTP with an image and prompt.
  Future<Map<String, dynamic>> _geminiVisionGenerate(
    Uint8List pngBytes,
    String prompt,
  ) async {
    const apiKey = String.fromEnvironment('GENAI_API_KEY');
    if (apiKey.isEmpty) {
      throw StateError(
        'GENAI_API_KEY not set. Run with --dart-define=GENAI_API_KEY=YOUR_KEY',
      );
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_visionModel:generateContent?key=$apiKey',
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
    };
    // Include dynamic thinking for both Pro and Flash
    payload['generationConfig'] = {
      'thinkingConfig': {'thinkingBudget': -1},
    };

    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (foundation.kDebugMode) {
      foundation.debugPrint('Gemini HTTP response status: ${resp.statusCode}');
      foundation.debugPrint('Gemini HTTP response headers: ${resp.headers}');
      foundation.debugPrint('Gemini HTTP response body: ${resp.body}');
    }

    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    final firstCandidate = candidates != null && candidates.isNotEmpty
        ? candidates.first as Map<String, dynamic>
        : null;

    // If the model finished early due to recitation, surface a clear error.
    final finishReason = firstCandidate?['finishReason'] as String?;
    if (finishReason == 'RECITATION') {
      throw StateError(
        'Generation finished early due to recitation. Please try again or adjust the prompt.',
      );
    }

    final content = firstCandidate == null
        ? null
        : firstCandidate['content'] as Map<String, dynamic>?;
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

  // Gemini TTS over HTTP. Returns { bytes: Uint8List, mimeType: String }
  Future<Map<String, dynamic>> _geminiTts(String text) async {
    const apiKey = String.fromEnvironment('GENAI_API_KEY');
    if (apiKey.isEmpty) {
      throw StateError(
        'GENAI_API_KEY not set. Run with --dart-define=GENAI_API_KEY=YOUR_KEY',
      );
    }
    // Use preview TTS-capable model.
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=$apiKey',
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
    if (foundation.kDebugMode) {
      foundation.debugPrint('Gemini TTS request: ${jsonEncode(payload)}');
    }
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (foundation.kDebugMode) {
      foundation.debugPrint('Gemini TTS status: ${resp.statusCode}');
      foundation.debugPrint('Gemini TTS body: ${resp.body}');
    }
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
      // REST may return camelCase inlineData
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

  // Wrap raw PCM (s16le) into a WAV container for easy playback in browsers.
  Uint8List _pcmToWav(
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

  // Download helper (currently unused)

  // Saves the PNG passed to the LLM as a downloaded file (Web only).
  void _savePngForVerification(Uint8List pngBytes, int pageNumber) {
    if (!kIsWeb) return;
    try {
      final blob = html.Blob([pngBytes], 'image/png');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..download = 'pdf_page_${pageNumber.toString().padLeft(3, '0')}.png'
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(url);
    } catch (_) {
      // Best-effort: ignore failures (e.g., not running on the web).
    }
  }

  // Saves arbitrary bytes as a downloaded file for the user (Web only).
  void _downloadBytesAsFile(
    Uint8List bytes,
    String filename,
    String mimeType,
  ) {
    if (!kIsWeb) return; // Non-web: no-op for now.
    try {
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..download = filename
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(url);
    } catch (_) {
      // Best-effort only.
    }
  }

  // Saves a text string as a .txt download (Web only).
  void _downloadTextAsFile(String text, String filename) {
    if (!kIsWeb) return;
    try {
      final bytes = Uint8List.fromList(utf8.encode(text));
      _downloadBytesAsFile(bytes, filename, 'text/plain');
    } catch (_) {
      // Best-effort only.
    }
  }

  Map<String, dynamic> _computeCosts(
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
      // Tiered pricing based on token counts (<=200k vs >200k)
      inputRatePerM = (promptTok <= 200000) ? 1.25 : 2.50;
      outputRatePerM = (outTok <= 200000) ? 10.00 : 15.00;
    } else {
      // 2.5 Flash (text/image/video). Audio not used here.
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

  String _formatCostSummaryFromCosts(
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

  String _formatTotalCost(double totalCost, int pages) {
    String fmt(double v) =>
        v < 0.01 ? v.toStringAsFixed(4) : v.toStringAsFixed(2);
    return 'Estimated total cost across $pages page(s): \$${fmt(totalCost)}';
  }

  String _fmtTime(Duration d) {
    final totalSecs = d.inSeconds;
    final m = (totalSecs ~/ 60).toString().padLeft(1, '0');
    final s = (totalSecs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // Loads the LLM prompt from assets/prompt.md; throws if missing or empty.
  Future<String> _loadPrompt() async {
    try {
      final s = await rootBundle.loadString('assets/prompt.md');
      final trimmed = s.trim();
      if (trimmed.isEmpty) {
        throw StateError('Prompt asset assets/prompt.md is empty.');
      }
      return trimmed;
    } catch (e) {
      // Surface a clear error so the caller shows a snackbar.
      throw StateError('Failed to load prompt from assets/prompt.md: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: Text('PDF → Page Image — $_docName'),
        actions: [
          // Model selector
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _visionModel,
              alignment: Alignment.center,
              onChanged: (v) {
                if (v == null) return;
                setState(() => _visionModel = v);
              },
              items: const [
                DropdownMenuItem(value: 'gemini-2.5-pro', child: Text('Pro')),
                DropdownMenuItem(
                  value: 'gemini-2.5-flash',
                  child: Text('Flash'),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open PDF',
            icon: const Icon(Icons.folder_open),
            onPressed: _pickAndOpenDocument,
          ),
          IconButton(
            tooltip: 'Transcribe current page (Gemini)',
            onPressed: _doc == null || _isTranscribing || _isBulkTranscribing
                ? null
                : () => _transcribeCurrentPage(),
            icon: const Icon(Icons.text_snippet_outlined),
          ),
          IconButton(
            tooltip: 'Speak current page',
            onPressed: _doc == null || _isSpeaking
                ? null
                : () => _speakCurrentPage(),
            icon: const Icon(Icons.volume_up_outlined),
          ),
          IconButton(
            tooltip: 'Transcribe all pages',
            onPressed: _doc == null || _isBulkTranscribing || _isTranscribing
                ? null
                : () => _transcribeAllPages(),
            icon: const Icon(Icons.library_books_outlined),
          ),
          IconButton(
            tooltip: 'Transcribe page range',
            onPressed: _doc == null || _isBulkTranscribing || _isTranscribing
                ? null
                : () => _showTranscribeRangeDialog(),
            icon: const Icon(Icons.filter_alt_outlined),
          ),
        ],
      ),
      body: doc == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Page image (carousel-like: one page at a time)
                Expanded(
                  child: FutureBuilder<ui.Image>(
                    future: _renderPage(context),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError || !snapshot.hasData) {
                        return Center(
                          child: Text(
                            'Render error: ${snapshot.error ?? 'unknown'}',
                          ),
                        );
                      }
                      final image = snapshot.data!;
                      Widget img = RawImage(image: image);
                      if (kIsWeb) {
                        img = Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.diagonal3Values(1, -1, 1),
                          child: img,
                        );
                      }
                      return InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 5,
                        child: img,
                      );
                    },
                  ),
                ),

                if (_isTranscribing)
                  const LinearProgressIndicator(minHeight: 2),
                if (_isBulkTranscribing)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(
                          minHeight: 2,
                          value: _bulkTotal > 0
                              ? _bulkProgress / _bulkTotal
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Transcribing all pages: $_bulkProgress/$_bulkTotal',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Scrollable transcription box for current page
                Builder(
                  builder: (context) {
                    final idx = (_pageNumber - 1).clamp(0, (doc.pageCount - 1));
                    final text =
                        (_pageTexts != null && idx < _pageTexts!.length)
                        ? (_pageTexts![idx] ?? '')
                        : '';
                    final cost =
                        (_pageCostSummaries != null &&
                            idx < _pageCostSummaries!.length)
                        ? (_pageCostSummaries![idx] ?? '')
                        : '';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (text.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                            child: SizedBox(
                              height: 200,
                              child: Scrollbar(
                                controller: _transcriptScrollController,
                                child: SingleChildScrollView(
                                  controller: _transcriptScrollController,
                                  child: SelectableText(
                                    text,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (cost.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                            child: Text(
                              cost,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        if ((_bulkTotalCostSummary ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                            child: Text(
                              _bulkTotalCostSummary!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),

                // Pager controls
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Page $_pageNumber of ${doc.pageCount}'),
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Previous',
                                onPressed: _pageNumber > 1
                                    ? () => _goToPage(_pageNumber - 1)
                                    : null,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              IconButton(
                                tooltip: 'Next',
                                onPressed: _pageNumber < doc.pageCount
                                    ? () => _goToPage(_pageNumber + 1)
                                    : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Audio player controls
                      Row(
                        children: [
                          IconButton(
                            tooltip: _audioState == PlayerState.playing
                                ? 'Pause'
                                : 'Play',
                            onPressed: (_audioDuration > Duration.zero)
                                ? _audioTogglePlayPause
                                : null,
                            icon: Icon(
                              _audioState == PlayerState.playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _audioPosition.inMilliseconds
                                  .clamp(0, _audioDuration.inMilliseconds)
                                  .toDouble(),
                              min: 0,
                              max:
                                  (_audioDuration.inMilliseconds == 0
                                          ? 1
                                          : _audioDuration.inMilliseconds)
                                      .toDouble(),
                              onChanged: (_audioDuration > Duration.zero)
                                  ? (v) => _audioSeek(v / 1000.0)
                                  : null,
                            ),
                          ),
                          SizedBox(
                            width: 110,
                            child: Text(
                              '${_fmtTime(_audioPosition)} / ${_fmtTime(_audioDuration)}',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
