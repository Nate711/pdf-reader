import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf_render/pdf_render.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';

// Firebase AI (Gemini) setup
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ai/firebase_ai.dart' as fai;
import 'firebase_options.dart';

Future<void> _initFirebase() async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    // If firebase_options.dart is not configured, initialization may fail at runtime.
    // We handle this gracefully in the UI.
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initFirebase();
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
  String? _transcribedText;

  @override
  void initState() {
    super.initState();
    _openDocument();
  }

  Future<void> _openDocument() async {
    // Loads the example asset declared in pubspec.yaml
    final doc = await PdfDocument.openAsset('assets/example.pdf');
    setState(() {
      _doc = doc;
      _pageNumber = 1;
    });
  }

  @override
  void dispose() {
    _doc?.dispose();
    super.dispose();
  }

  Future<ui.Image> _renderPage(BuildContext context) async {
    final doc = _doc!;
    final page = await doc.getPage(_pageNumber);

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
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw Exception('Failed to encode PNG');
    return data.buffer.asUint8List();
  }

  Future<void> _transcribeCurrentPage() async {
    setState(() {
      _isTranscribing = true;
      _transcribedText = null;
    });
    try {
      // Guard: Firebase must be initialized for FirebaseAI to work on Web.
      if (Firebase.apps.isEmpty) {
        throw StateError(
          'Firebase not initialized. Run `flutterfire config` to generate lib/firebase_options.dart, '
          'then rebuild and try again.',
        );
      }
      // Ensure Firebase was initialized; FirebaseAI relies on it.
      // If not, this will likely throw. We surface a friendly error.
      final model = fai.FirebaseAI.googleAI()
          .generativeModel(model: 'gemini-2.0-flash');

      final prompt =
          'Transcribe the text from this page of a PDF in natural reading order. '
          'Return only the plain text. Summarize figure and figure captions instead '
          'of transcribing them verbatim. Transcribe equations so that they can be '
          'read aloud naturally by a text-to-speech model. Abbreviate author list with et al. '
          'Skip non-text like arXiv:2502.04307v1 [cs.RO] 6 Feb 2025. '
          'Transcribe verbatim except for previously described exceptions.';

      final png = await _currentPageAsPngBytes(context);

      final resp = await model.generateContent([
        fai.Content.text(prompt),
        fai.Content.inlineData('image/png', png),
      ]);

      final text = resp.text ?? '';
      if (!mounted) return;
      setState(() {
        _transcribedText = text.trim();
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final msg = 'Firebase error: \'${e.code}\' ${e.message ?? ''}'.trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcription failed: $msg')),
      );
    } on UnsupportedError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Firebase options missing. Run `flutterfire config` to generate firebase_options.dart.'),
        ),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Firebase not initialized.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcription failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isTranscribing = false);
      }
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
            onPressed: _doc == null || _isTranscribing ? null : () => _transcribeCurrentPage(),
            icon: const Icon(Icons.text_snippet_outlined),
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
                      if (snapshot.hasError) {
                        return Center(
                          child: Text('Render error: ${snapshot.error}'),
                        );
                      }
                      final image = snapshot.data!;
                      Widget img = RawImage(image: image);
                      // On Web, the rendered bitmap appears vertically mirrored.
                      // Apply a vertical flip (scaleY: -1) to correct it.
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
                if ((_transcribedText ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _transcribedText!,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                // Pager controls
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Page $_pageNumber of ${doc.pageCount}'),
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Previous',
                            onPressed: _pageNumber > 1 ? () => _goToPage(_pageNumber - 1) : null,
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
