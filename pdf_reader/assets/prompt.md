# PDF Page Transcription – Vision Prompt

## Objective
Extract the readable text from a single PDF page image in natural reading order and return only the plain text (no Markdown, no code fences, no explanations).

## What You Receive
- One image: a rendered PNG of a single PDF page.

## Output Requirements
1. Return only the transcribed text content as a single plain‑text block.
2. Follow natural reading order (columns left→right, top→bottom; respect headings before body; footnotes after their references).
3. Normalize whitespace (single spaces between words; preserve paragraph breaks with a single blank line).
4. Preserve punctuation and capitalization from the source.
5. Join hyphenated line breaks at line ends: “multi-
   line” → “multiline”. Keep genuine hyphens.
6. Convert ligatures (e.g., “ﬁ”, “ﬂ”) to normal letters.
7. Remove repeating headers/footers, page numbers, running titles, and watermarks.
8. Bibliography/citations: Ignore.
9. Figures, tables, and complex math:
   - Summarize content succinctly rather than attempting verbatim OCR of dense layouts.
   - Summarize visible captions in your own words when possible.
10. Equations: express in readable natural language suitable for TTS (e.g., “x squared plus y squared equals z squared”), not LaTeX.
11. Abbreviate author lists with “[first author] et al.” 
12. Exclude obvious boilerplate like submission timestamps or repository IDs unless central to the text’s meaning.

## Special Handling
- Bulleted/numbered lists: keep list structure as plain text (use “- ” or numbers) when clear.
- Tables: convert to concise sentences that preserve the key values and relationships.
- URLs: include as plain text if clearly visible; do not invent links.

## Quality Checks (before finalizing)
- Ensure no Markdown, JSON, or backticks are present in the output.
- Ensure paragraphs are separated by a single blank line and there are no double spaces.
- Confirm reading order is coherent across multi‑column layouts.

## Final Output
Only the transcribed plain text described above. Do not include any preamble, headings, or notes.

