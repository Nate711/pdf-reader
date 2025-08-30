# pdf-reader

This repository contains a simple Python script that converts a PDF into an audio narration.

The script performs two steps for every page of a PDF:

1. **Transcription** – Each page is rendered as an image and sent to an OpenAI chat model (`gpt-5` by default). The model is asked to transcribe the text in natural reading order.
2. **Text‑to‑Speech** – The concatenated transcription is passed to the `gpt-4o-mini-tts` model to generate an audio file.

## Requirements
- Python 3.10+
- `openai` and `pymupdf` packages
- `OPENAI_API_KEY` environment variable set

Install the dependencies with:

```bash
pip install -r requirements.txt
```

## Usage

```bash
python pdf_to_audio.py input.pdf output.mp3
```

By default all pages are processed. For testing you can limit the number of pages:

```bash
python pdf_to_audio.py input.pdf output.mp3 --max-pages 1
```

Models can be overridden using environment variables:

```bash
export TRANSCRIPTION_MODEL=gpt-5
export TTS_MODEL=gpt-4o-mini-tts
```

## Testing with a Mocked API

The project includes a minimal mock of the OpenAI client so the script can be
tested without network access. Enable the mock by setting `MOCK_OPENAI=1`:

```bash
MOCK_OPENAI=1 python pdf_to_audio.py example.pdf output.mp3 --max-pages 1
```

Run automated tests with:

```bash
pytest
```
