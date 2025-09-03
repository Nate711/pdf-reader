import 'package:flutter/material.dart';

class TranscribeRangeDialog extends StatefulWidget {
  final int maxPages;
  final Function(int start, int end) onTranscribe;

  const TranscribeRangeDialog({
    super.key,
    required this.maxPages,
    required this.onTranscribe,
  });

  @override
  State<TranscribeRangeDialog> createState() => _TranscribeRangeDialogState();
}

class _TranscribeRangeDialogState extends State<TranscribeRangeDialog> {
  late TextEditingController _startController;
  late TextEditingController _endController;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: '1');
    _endController = TextEditingController(text: widget.maxPages.toString());
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Transcribe page range'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _startController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Start page',
              hintText: 'e.g. 1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _endController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'End page (max ${widget.maxPages})',
              hintText: widget.maxPages.toString(),
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
            final s = int.tryParse(_startController.text.trim());
            final e = int.tryParse(_endController.text.trim());
            if (s == null || e == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Enter valid page numbers.'),
                ),
              );
              return;
            }
            Navigator.of(context).pop();
            widget.onTranscribe(s, e);
          },
          child: const Text('Transcribe'),
        ),
      ],
    );
  }
}