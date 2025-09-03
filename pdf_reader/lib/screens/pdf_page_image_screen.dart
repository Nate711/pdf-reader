import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf_render/pdf_render.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:audioplayers/audioplayers.dart';

import 'package:namer_app/services/gemini_service.dart';
import 'package:namer_app/services/audio_service.dart';
import 'package:namer_app/services/pdf_render_service.dart';
import 'package:namer_app/services/streaming_tts_service.dart';
import 'package:namer_app/widgets/audio_player_controls.dart';
import 'package:namer_app/widgets/transcribe_range_dialog.dart';
import 'package:namer_app/widgets/transcript_display.dart';
import 'package:namer_app/utils/download_helper.dart';

class PdfPageImageScreen extends StatefulWidget {
  const PdfPageImageScreen({super.key});

  @override
  State<PdfPageImageScreen> createState() => _PdfPageImageScreenState();
}

class _PdfPageImageScreenState extends State<PdfPageImageScreen> {
  
  // Services
  final GeminiService _geminiService = const GeminiService();
  final AudioService _audioService = AudioService();
  final PdfRenderService _pdfRenderService = PdfRenderService();
  final StreamingTtsService _streamingTtsService = StreamingTtsService();
  
  // PDF state
  PdfDocument? _doc;
  int _pageNumber = 1;
  String _docName = 'example.pdf';
  
  // UI state
  String _visionModel = 'gemini-2.5-flash';
  bool _downloadVerificationPngs = false;
  bool _isTranscribing = false;
  bool _isStreamingSpeaking = false;
  bool _isBulkTranscribing = false;
  int _bulkProgress = 0;
  int _bulkTotal = 0;
  
  // Transcript data
  List<String?>? _pageTexts;
  List<String?>? _pageCostSummaries;
  String? _bulkTotalCostSummary;
  
  // Scroll controller
  late final ScrollController _transcriptScrollController;

  @override
  void initState() {
    super.initState();
    _openDocument();
    _transcriptScrollController = ScrollController();
    
    // Listen to audio service streams
    _audioService.positionStream.listen((p) {
      if (!mounted) return;
      setState(() {});
    });
    _audioService.durationStream.listen((d) {
      if (!mounted) return;
      setState(() {});
    });
    _audioService.stateStream.listen((s) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _doc?.dispose();
    _transcriptScrollController.dispose();
    _audioService.dispose();
    _streamingTtsService.dispose();
    super.dispose();
  }

  Future<void> _openDocument() async {
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
        withData: kIsWeb,
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
      await _audioService.stop();
    } catch (e) {
      _showPersistentError('Failed to open PDF: $e');
    }
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
    return _pdfRenderService.renderPage(_doc!, _pageNumber);
  }

  void _goToPage(int newPage) {
    if (_doc == null) return;
    final pageCount = _doc!.pageCount;
    if (newPage < 1 || newPage > pageCount) return;
    setState(() => _pageNumber = newPage);
  }

  Future<String> _loadPrompt() async {
    try {
      final s = await rootBundle.loadString('assets/prompt.md');
      final trimmed = s.trim();
      if (trimmed.isEmpty) {
        throw StateError('Prompt asset assets/prompt.md is empty.');
      }
      return trimmed;
    } catch (e) {
      throw StateError('Failed to load prompt from assets/prompt.md: $e');
    }
  }

  Future<void> _transcribeCurrentPage() async {
    setState(() {
      _isTranscribing = true;
    });
    try {
      final prompt = await _loadPrompt();
      if (!mounted) return;

      final png = await _pdfRenderService.pageAsPngBytes(_doc!, _pageNumber);
      if (_downloadVerificationPngs) {
        await DownloadHelper.savePngForVerification(png, _pageNumber);
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

  Future<void> _transcribeAllPages() async {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      _isBulkTranscribing = true;
      _bulkProgress = 0;
      _bulkTotal = doc.pageCount;
      _pageTexts = List<String?>.filled(doc.pageCount, null);
      _pageCostSummaries = List<String?>.filled(doc.pageCount, null);
      _bulkTotalCostSummary = null;
    });
    try {
      final prompt = await _loadPrompt();
      if (!mounted) return;

      final futures = <Future<Map<String, dynamic>>>[];
      for (var p = 1; p <= doc.pageCount; p++) {
        Future<Map<String, dynamic>> task() async {
          final png = await _pdfRenderService.pageAsPngBytes(doc, p);
          if (_downloadVerificationPngs) {
            await DownloadHelper.savePngForVerification(png, p);
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

      final combined = results.map((r) => (r['text'] as String)).join("\n\n");
      final baseName = _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename = '${baseName}_pages_1-${doc.pageCount}.txt';
      await DownloadHelper.downloadTextAsFile(combined, filename);
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
          final png = await _pdfRenderService.pageAsPngBytes(doc, p);
          if (_downloadVerificationPngs) {
            await DownloadHelper.savePngForVerification(png, p);
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

      final combined = results.map((r) => (r['text'] as String)).join("\n\n");
      final baseName = _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename = '${baseName}_pages_$start-$end.txt';
      await DownloadHelper.downloadTextAsFile(combined, filename);
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
    
    await showDialog(
      context: context,
      builder: (context) => TranscribeRangeDialog(
        maxPages: doc.pageCount,
        onTranscribe: _transcribePageRange,
      ),
    );
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
      final audio = await _streamingTtsService.streamTts(text);
      final bytes = audio['bytes'] as Uint8List;
      final mimeType = (audio['mimeType'] as String?) ?? 'audio/wav';
      
      // Play audio using the audio service
      await _audioService.stop();
      await _audioService.play(BytesSource(bytes));
      
      // Save audio file
      final baseName = _docName.replaceFirst(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final filename =
          '${baseName}_page_${_pageNumber.toString().padLeft(3, '0')}_stream.wav';
      await DownloadHelper.downloadBytesAsFile(bytes, filename, mimeType);
    } catch (e) {
      _showPersistentError('Streaming TTS failed: $e');
    } finally {
      if (mounted) setState(() => _isStreamingSpeaking = false);
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
                // Page image
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

                // Transcript display
                Builder(
                  builder: (context) {
                    final idx = (_pageNumber - 1).clamp(0, (doc.pageCount - 1));
                    final text =
                        (_pageTexts != null && idx < _pageTexts!.length)
                        ? _pageTexts![idx]
                        : null;
                    final cost =
                        (_pageCostSummaries != null &&
                            idx < _pageCostSummaries!.length)
                        ? _pageCostSummaries![idx]
                        : null;
                    return TranscriptDisplay(
                      text: text,
                      costSummary: cost,
                      bulkTotalCostSummary: _bulkTotalCostSummary,
                      scrollController: _transcriptScrollController,
                    );
                  },
                ),

                // Page controls
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
                      AudioPlayerControls(
                        position: _audioService.position,
                        duration: _audioService.duration,
                        state: _audioService.state,
                        onTogglePlayPause: _audioService.togglePlayPause,
                        onSeek: (seconds) => _audioService.seek(
                          Duration(milliseconds: (seconds * 1000).round()),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}