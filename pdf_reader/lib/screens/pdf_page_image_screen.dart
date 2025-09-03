import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/foundation.dart' as foundation;
import 'package:pdf_render/pdf_render.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
// For web download of verification images
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
// WebAudio API (for Flutter Web streaming playback)
// ignore: avoid_web_libraries_in_flutter
import 'dart:web_audio' as webaudio;

// Firebase AI (Gemini) setup
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/io.dart' as io_ws;
import 'package:namer_app/services/gemini_service.dart';

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
  // Debug toggle: download page render PNGs sent to LLM
  bool _downloadVerificationPngs = false;
  bool _isTranscribing = false;
  bool _isStreamingSpeaking = false;
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
  // WebAudio playback state for progressive streaming (web only)
  webaudio.AudioContext? _webAudioCtx;
  double _webAudioNextStart = 0.0;
  final GeminiService _geminiService = const GeminiService();

  // Lightweight logging helper that prints to Flutter console and browser console.
  void _log(String message) {
    try {
      // ignore: avoid_print
      print(message);
    } catch (_) {}
    try {
      foundation.debugPrint(message);
    } catch (_) {}
    if (kIsWeb) {
      try {
        // ignore: deprecated_member_use
        html.window.console.log(message);
      } catch (_) {}
    }
  }

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

  // Schedules a PCM s16le chunk to play via WebAudio immediately after
  // the last scheduled buffer finishes (Web only). Safe no-op off web.
  void _webaudioSchedulePcmChunk(
    Uint8List pcmBytes, {
    required int sampleRate,
    required int channels,
  }) {
    if (!kIsWeb) return;
    try {
      _webAudioCtx ??= webaudio.AudioContext();
      final ctx = _webAudioCtx!;
      // Convert s16le PCM to Float32 [-1, 1]
      final sampleCount = pcmBytes.length ~/ 2;
      final floats = Float32List(sampleCount);
      final bd = ByteData.view(
        pcmBytes.buffer,
        pcmBytes.offsetInBytes,
        pcmBytes.length,
      );
      for (var i = 0; i < sampleCount; i++) {
        final s = bd.getInt16(i * 2, Endian.little);
        floats[i] = (s >= 0 ? s / 32767.0 : s / 32768.0);
      }

      // For mono only (channels == 1). If multi-channel support is needed later,
      // we can deinterleave here.
      final frameCount = sampleCount ~/ channels;
      final buffer = ctx.createBuffer(channels, frameCount, sampleRate);
      if (channels == 1) {
        buffer.getChannelData(0).setRange(0, frameCount, floats);
      } else {
        // Naive split for 2 channels if ever needed
        for (var ch = 0; ch < channels; ch++) {
          final chData = buffer.getChannelData(ch);
          var w = 0;
          for (var r = ch; r < sampleCount; r += channels) {
            chData[w++] = floats[r];
          }
        }
      }

      final src = ctx.createBufferSource();
      src.buffer = buffer;
      final dest = ctx.destination;
      if (dest != null) {
        src.connectNode(dest);
      }

      final now = (ctx.currentTime ?? 0).toDouble();
      // Start in a tiny future to avoid pops, and after any prior chunk.
      final startAt =
          (_webAudioNextStart > now ? _webAudioNextStart : now) + 0.03;
      src.start(startAt);
      _webAudioNextStart = startAt + (frameCount / sampleRate);
    } catch (_) {
      // best-effort only
    }
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
    try {
      _webAudioCtx?.close();
    } catch (_) {}
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
      if (_downloadVerificationPngs) {
        _savePngForVerification(png, _pageNumber);
      }
      final result = await _geminiService.generateVision(png, prompt);
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

  // Removed non-WebSocket TTS path

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
          if (_downloadVerificationPngs) {
            _savePngForVerification(png, p);
          }
          final result = await _geminiService.generateVision(png, prompt);
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
        _bulkTotalCostSummary =
            _geminiService.formatTotalCost(totalCost, doc.pageCount);
      });

      // Download combined transcript as a single text file (Web best-effort)
      final combined = results.map((r) => (r['text'] as String)).join("\n\n");
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
          if (_downloadVerificationPngs) {
            _savePngForVerification(png, p);
          }
          final result = await _geminiService.generateVision(png, prompt);
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
        _bulkTotalCostSummary =
            _geminiService.formatTotalCost(totalCost, count);
      });

      // Download combined transcript as a single text file (Web best-effort)
      final combined = results.map((r) => (r['text'] as String)).join("\n\n");
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

  // Streaming TTS over WebSockets using Gemini live preview.
  // Accumulates audio chunks and returns a WAV payload when complete.
  Future<Map<String, dynamic>> _geminiTtsStream(String text) async {
    const apiKey = String.fromEnvironment('GENAI_API_KEY');
    if (apiKey.isEmpty) {
      throw StateError(
        'GENAI_API_KEY not set. Run with --dart-define=GENAI_API_KEY=YOUR_KEY',
      );
    }

    // Live preview model for streaming audio output.
    const model = 'gemini-2.5-flash-live-preview';

    // Build WebSocket endpoint per Live API reference using API key.
    // Build URL per pattern:
    // url = `${websocketBaseUrl}/ws/google.ai.generativelanguage.${apiVersion}.GenerativeService.${method}?${keyName}=${apiKey}`
    const websocketBaseUrl = 'wss://generativelanguage.googleapis.com';
    const apiVersion = 'v1beta';
    const method = 'BidiGenerateContent';
    const keyName = 'key';
    final wsUrlWithKey = Uri.parse(
      '$websocketBaseUrl/ws/google.ai.generativelanguage.$apiVersion.GenerativeService.$method?$keyName=$apiKey',
    );
    final wsUrlNoKey = Uri.parse(
      '$websocketBaseUrl/ws/google.ai.generativelanguage.$apiVersion.GenerativeService.$method',
    );

    _log(
      'Live WS: connecting to ' +
          (kIsWeb ? wsUrlWithKey.toString() : wsUrlNoKey.toString()),
    );

    const protocols = ['json'];
    // Shared collectors and setup payload
    final collected = BytesBuilder();
    final done = Completer<void>();
    int _msgCount = 0;
    int _audioChunks = 0;
    int _audioBytes = 0;

    final setupMsg = jsonEncode({
      'setup': {
        'model': 'models/$model',
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': 'Achernar'},
            },
          },
        },
      },
    });

    if (kIsWeb) {
      // Web-specific implementation using dart:html for richer diagnostics.
      final ws = html.WebSocket(wsUrlWithKey.toString(), protocols);
      ws.binaryType = 'arraybuffer';
      final open = Completer<void>();
      ws.onOpen.first.then((_) {
        _log('Live WS: onOpen');
        open.complete();
      });
      ws.onError.first.then((e) {
        if (!open.isCompleted) open.completeError(Exception('WS open error'));
      });

      await open.future.timeout(const Duration(seconds: 10));

      // Send setup
      _log('Live WS: sending setup -> ' + setupMsg);
      ws.sendString(setupMsg);

      // State and handlers
      bool setupComplete = false;

      void sendClientTurn() {
        final msg = jsonEncode({
          'clientContent': {
            'turns': [
              {
                'role': 'user',
                'parts': [
                  {'text': text},
                ],
              },
            ],
            'turnComplete': true,
          },
        });
        _log('Live WS: sending clientContent (turnComplete=true)');
        ws.sendString(msg);
      }

      ws.onMessage.listen((event) {
        try {
          if (event.data is ByteBuffer) {
            final bb = event.data as ByteBuffer;
            final bytes = Uint8List.view(bb);
            collected.add(bytes);
            _audioChunks++;
            _audioBytes += bytes.length;
            if (_audioChunks % 5 == 1) {
              _log('Live WS: binary audio frame bytes=${bytes.length} total=$_audioBytes');
            }
            return;
          }
          final str = event.data?.toString() ?? '';
          _log('Live WS: text frame len=${str.length}');
          final Map<String, dynamic> msg = jsonDecode(str);
          _log('Live WS: keys=${msg.keys.join(', ')}');

          if (!setupComplete && msg.containsKey('setupComplete')) {
            setupComplete = true;
            _log('Live WS: setupComplete received. Sending client turn...');
            sendClientTurn();
            return;
          }

          final topLevelData = msg['data'];
          if (topLevelData is String && topLevelData.isNotEmpty) {
            final bytes = base64Decode(topLevelData);
            collected.add(bytes);
            _audioChunks++;
            _audioBytes += bytes.length;
            _log('Live WS: audio chunk (top-level data) bytes=${bytes.length} total=$_audioBytes');
            _webaudioSchedulePcmChunk(bytes, sampleRate: 24000, channels: 1);
          }

          final realtimeOutput = msg['realtimeOutput'] as Map<String, dynamic>?;
          if (realtimeOutput != null) {
            final audio = realtimeOutput['audio'] as Map<String, dynamic>?;
            final b64 = audio != null ? audio['data'] as String? : null;
            if (b64 != null) {
              final bytes = base64Decode(b64);
              collected.add(bytes);
              _audioChunks++;
              _audioBytes += bytes.length;
              _log('Live WS: audio chunk (realtimeOutput) bytes=${bytes.length} total=$_audioBytes');
              _webaudioSchedulePcmChunk(bytes, sampleRate: 24000, channels: 1);
            }
          }

          final serverContent = msg['serverContent'] as Map<String, dynamic>?;
          if (serverContent != null) {
            final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
            final parts = modelTurn != null ? modelTurn['parts'] as List? : null;
            if (parts != null) {
              for (final p in parts) {
                final mp = (p as Map).cast<String, dynamic>();
                Map<String, dynamic>? inline =
                    (mp['inlineData'] as Map<String, dynamic>?) ??
                    (mp['inline_data'] as Map<String, dynamic>?);
                String? b64;
                if (inline != null) {
                  b64 = inline['data'] as String?;
                } else if (mp['audio'] is Map<String, dynamic>) {
                  final a = mp['audio'] as Map<String, dynamic>;
                  b64 = a['data'] as String?;
                }
                if (b64 != null) {
                  final bytes = base64Decode(b64);
                  collected.add(bytes);
                  _audioChunks++;
                  _audioBytes += bytes.length;
                  _log('Live WS: audio chunk (parts) bytes=${bytes.length} total=$_audioBytes');
                  _webaudioSchedulePcmChunk(bytes, sampleRate: 24000, channels: 1);
                }
              }
            }

            final genComplete = serverContent['generationComplete'] == true;
            final turnComplete = serverContent['turnComplete'] == true;
            if (genComplete || turnComplete) {
              _log('Live WS: genComplete=$genComplete turnComplete=$turnComplete. Ending turn.');
              if (!done.isCompleted) done.complete();
              return;
            }
          }
        } catch (err, st) {
          _log('Live WS: error while handling message: $err');
          _log(st.toString());
        }
      });

      ws.onError.listen((e) {
        _log('Live WS: onError');
        if (!done.isCompleted) done.completeError(Exception('WebSocket error'));
      });
      ws.onClose.listen((event) {
        try {
          final ce = event as html.CloseEvent;
          _log('Live WS: onClose code=${ce.code} reason=${ce.reason} wasClean=${ce.wasClean}');
        } catch (_) {
          _log('Live WS: onClose (no details)');
        }
        if (!done.isCompleted) done.complete();
      });

      try {
        await done.future.timeout(const Duration(minutes: 2));
      } catch (e) {
        _log('Live WS: timeout waiting for audio/end-of-turn: $e');
        rethrow;
      } finally {
        try {
          _log('Live WS: closing channel');
          ws.close();
        } catch (e) {
          _log('Live WS: error during close: $e');
        }
      }
    } else {
      // Non-web: use web_socket_channel with header auth
      final channel = io_ws.IOWebSocketChannel.connect(
        wsUrlNoKey,
        protocols: protocols,
        headers: {'x-goog-api-key': apiKey},
      );
      // Send initial setup specifying model and audio response.
      _log('Live WS (native): sending setup -> ' + setupMsg);
      channel.sink.add(setupMsg);

      // Buffer client messages until setupComplete.
      bool setupComplete = false;
      void sendClientTurn() {
        final msg = jsonEncode({
          'clientContent': {
            'turns': [
              {
                'role': 'user',
                'parts': [
                  {'text': text},
                ],
              },
            ],
            'turnComplete': true,
          },
        });
        _log('Live WS (native): sending clientContent (turnComplete=true)');
        channel.sink.add(msg);
      }

      channel.stream.listen(
        (event) {
          try {
            if (event is List<int>) {
              collected.add(event);
              return;
            }
            final str = event.toString();
            final Map<String, dynamic> msg = jsonDecode(str);
            if (!setupComplete && msg.containsKey('setupComplete')) {
              setupComplete = true;
              sendClientTurn();
              return;
            }
            final serverContent = msg['serverContent'] as Map<String, dynamic>?;
            final parts = (serverContent?['modelTurn'] as Map<String, dynamic>?)?['parts'] as List?;
            if (parts != null) {
              for (final p in parts) {
                final mp = (p as Map).cast<String, dynamic>();
                final inline = (mp['inlineData'] as Map<String, dynamic>?) ?? (mp['inline_data'] as Map<String, dynamic>?);
                final b64 = inline != null
                    ? inline['data'] as String?
                    : (mp['audio'] is Map<String, dynamic>)
                        ? (mp['audio'] as Map<String, dynamic>)['data'] as String?
                        : null;
                if (b64 != null) collected.add(base64Decode(b64));
              }
            }
            final genComplete = serverContent?['generationComplete'] == true;
            final turnComplete = serverContent?['turnComplete'] == true;
            if (genComplete || turnComplete) {
              if (!done.isCompleted) done.complete();
              return;
            }
          } catch (_) {}
        },
        onError: (e) {
          if (!done.isCompleted) done.completeError(Exception('WebSocket error: $e'));
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future.timeout(const Duration(minutes: 2));
      try {
        channel.sink.close(ws_status.normalClosure);
      } catch (_) {}
    }
    // Finalize audio buffer and return
    final pcm = collected.takeBytes();
    if (pcm.isEmpty) {
      _log('Live WS: completed with 0 audio bytes. messages=$_msgCount chunks=$_audioChunks');
      throw Exception('No audio received from streaming TTS');
    }

    final wav = _pcmToWav(
      Uint8List.fromList(pcm),
      sampleRate: 24000,
      channels: 1,
      bitsPerSample: 16,
    );
    return {'bytes': wav, 'mimeType': 'audio/wav'};
  }

  Future<void> _speakCurrentPageStreaming() async {
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
    setState(() => _isStreamingSpeaking = true);
    try {
      if (kIsWeb) {
        _webAudioCtx ??= webaudio.AudioContext();
        _webAudioNextStart = (_webAudioCtx!.currentTime ?? 0).toDouble();
      }
      final audio = await _geminiTtsStream(text);
      final bytes = audio['bytes'] as Uint8List;
      final mimeType = (audio['mimeType'] as String?) ?? 'audio/wav';
      // On web, audio has already been playing progressively.
      // On non-web, play the combined result at the end.
      if (!kIsWeb) {
        await _audioPlayer.stop();
        await _audioPlayer.play(BytesSource(bytes));
      }
      // Offer download
      final baseName = _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename =
          '${baseName}_page_${_pageNumber.toString().padLeft(3, '0')}_stream.wav';
      _downloadBytesAsFile(bytes, filename, mimeType);
    } catch (e) {
      _showPersistentError('Streaming TTS failed: $e');
    } finally {
      if (mounted) setState(() => _isStreamingSpeaking = false);
    }
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

  // Download helpers

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
  void _downloadBytesAsFile(Uint8List bytes, String filename, String mimeType) {
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
          // Removed non-WebSocket TTS button
          IconButton(
            tooltip: 'Speak (streaming TTS)',
            onPressed: _doc == null || _isStreamingSpeaking
                ? null
                : () => _speakCurrentPageStreaming(),
            icon: const Icon(Icons.multitrack_audio_outlined),
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
          // Toggle download of verification PNGs (Web)
          IconButton(
            tooltip: _downloadVerificationPngs
                ? 'Download page PNGs: ON'
                : 'Download page PNGs: OFF',
            onPressed: () {
              setState(
                () => _downloadVerificationPngs = !_downloadVerificationPngs,
              );
            },
            icon: Icon(
              _downloadVerificationPngs
                  ? Icons.image
                  : Icons.image_not_supported_outlined,
            ),
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
