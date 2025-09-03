import 'package:flutter/material.dart';

class TranscriptDisplay extends StatelessWidget {
  final String? text;
  final String? costSummary;
  final String? bulkTotalCostSummary;
  final ScrollController scrollController;

  const TranscriptDisplay({
    super.key,
    this.text,
    this.costSummary,
    this.bulkTotalCostSummary,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: SizedBox(
            height: 200,
            child: Scrollbar(
              controller: scrollController,
              child: SingleChildScrollView(
                controller: scrollController,
                child: SelectableText(
                  text!,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ),
        if (costSummary != null && costSummary!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              costSummary!,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
        if (bulkTotalCostSummary != null && bulkTotalCostSummary!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              bulkTotalCostSummary!,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
      ],
    );
  }
}