import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/foundation.dart' as foundation;
import 'package:pdf_render/pdf_render.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
// For web download of verification images
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

// Firebase AI (Gemini) setup
import 'package:http/http.dart' as http;
import 'dart:convert';

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
  bool _isTranscribing = false;
  bool _isBulkTranscribing = false;
  int _bulkProgress = 0;
  int _bulkTotal = 0;
  List<String?>? _pageTexts;
  List<String?>? _pageCostSummaries;
  String? _bulkTotalCostSummary;

  @override
  void initState() {
    super.initState();
    _openDocument();
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
      _pageTexts = List<String?>.filled(doc.pageCount, null);
      _pageCostSummaries = List<String?>.filled(doc.pageCount, null);
      _bulkTotalCostSummary = null;
    });
  }

  @override
  void dispose() {
    _doc?.dispose();
    super.dispose();
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
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Transcription failed: $e')));
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
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Bulk transcription failed: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isBulkTranscribing = false;
        });
      }
    }
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
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
    );

    final payload = {
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
    final content = candidates == null || candidates.isEmpty
        ? null
        : (candidates.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?;
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
        title: const Text('PDF → Page Image'),
        actions: [
          IconButton(
            tooltip: 'Transcribe current page (Gemini)',
            onPressed: _doc == null || _isTranscribing || _isBulkTranscribing
                ? null
                : () => _transcribeCurrentPage(),
            icon: const Icon(Icons.text_snippet_outlined),
          ),
          IconButton(
            tooltip: 'Transcribe all pages',
            onPressed: _doc == null || _isBulkTranscribing || _isTranscribing
                ? null
                : () => _transcribeAllPages(),
            icon: const Icon(Icons.library_books_outlined),
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
                                child: SingleChildScrollView(
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
                  child: Row(
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
                ),
              ],
            ),
    );
  }
}
