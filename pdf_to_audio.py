import argparse
import base64
import os
from datetime import datetime
from pathlib import Path

import fitz  # PyMuPDF
from openai import OpenAI


class _MockStreamingResponse:
    """Simple context manager that writes canned audio bytes to a file."""

    def __init__(self, data=b"mock audio"):
        self._data = data

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def stream_to_file(self, path):
        with open(path, "wb") as fh:
            fh.write(self._data)


class _MockResponses:
    def create(self, *args, **kwargs):
        class _Resp:
            output_text = "Mock transcription"

        return _Resp()


class _MockAudioSpeech:
    class WithStreamingResponse:
        def create(self, *args, **kwargs):
            return _MockStreamingResponse()

    with_streaming_response = WithStreamingResponse()


class _MockAudio:
    speech = _MockAudioSpeech()


class MockOpenAI:
    """Minimal mock of the OpenAI client used for testing."""

    def __init__(self, *args, **kwargs):
        self.responses = _MockResponses()
        self.audio = _MockAudio()


def get_client():
    """Return real or mock OpenAI client depending on environment."""
    if os.getenv("MOCK_OPENAI") == "1":
        return MockOpenAI()
    return OpenAI()


def render_pdf_to_images(pdf_path, debug_folder=None):
    doc = fitz.open(pdf_path)
    images = []

    if debug_folder:
        debug_path = Path(debug_folder)
        debug_path.mkdir(parents=True, exist_ok=True)
        print(f"Saving rendered pages to {debug_path}")

    for page_num, page in enumerate(doc, start=1):
        pix = page.get_pixmap(dpi=200)
        image_bytes = pix.tobytes("png")
        images.append(image_bytes)

        if debug_folder:
            image_path = debug_path / f"page_{page_num:03d}.png"
            with open(image_path, "wb") as f:
                f.write(image_bytes)
            print(f"  Saved page {page_num} to {image_path}")

    doc.close()
    return images


def transcribe_page(image_bytes, client, model, page_num=None):
    b64_image = base64.b64encode(image_bytes).decode("utf-8")
    response = client.responses.create(
        model=model,
        reasoning={"effort": "low"},
        input=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": "Transcribe the text from this page of a PDF in natural reading order. Return only the plain text. Summarize figure and figure captions instead of transcribing them verbatim.",
                    },
                    {
                        "type": "input_image",
                        "image_url": f"data:image/png;base64,{b64_image}",
                    },
                ],
            }
        ],
    )

    return response.output_text.strip()


def text_to_speech(text, output_path, client, model, voice="alloy"):
    output_file = Path(output_path)

    with client.audio.speech.with_streaming_response.create(
        model=model,
        voice=voice,
        input=text,
    ) as response:
        response.stream_to_file(output_file)


def main():
    parser = argparse.ArgumentParser(description="Convert a PDF into an audio file using OpenAI APIs.")
    parser.add_argument("pdf", help="Path to input PDF file")
    parser.add_argument("--output", help="Path to output audio file (e.g., output.mp3)", default="output.mp3")
    parser.add_argument(
        "--max-pages", type=int, default=None, help="Limit number of pages for processing (for testing)"
    )
    parser.add_argument(
        "--transcription-model",
        default="gpt-5",
        help="Model to use for page transcription (default: gpt-5)",
    )
    parser.add_argument(
        "--tts-model",
        default="gpt-4o-mini-tts",
        help="Model to use for text-to-speech (default: gpt-4o-mini-tts)",
    )
    parser.add_argument(
        "--skip-tts",
        action="store_true",
        help="Skip text-to-speech generation and only transcribe",
    )
    parser.add_argument(
        "--debug-folder",
        help="Optional folder to save rendered PDF pages as PNG images for debugging",
        default="debug_output",
    )
    args = parser.parse_args()

    client = get_client()

    images = render_pdf_to_images(args.pdf, debug_folder=args.debug_folder)
    texts = []
    total_pages = len(images)

    if args.debug_folder:
        debug_path = Path(args.debug_folder)
        debug_path.mkdir(parents=True, exist_ok=True)

    for idx, img in enumerate(images, start=1):
        if args.max_pages is not None and idx > args.max_pages:
            break
        print(f"Transcribing page {idx}/{total_pages}...")
        page_text = transcribe_page(
            img,
            client,
            model=args.transcription_model,
            page_num=idx,
        )
        texts.append(page_text)

        if args.debug_folder:
            text_path = debug_path / f"page_{idx:03d}.txt"
            with open(text_path, "w", encoding="utf-8") as f:
                f.write(page_text)
            print(f"  Saved transcribed text to {text_path}")

    full_text = "\n".join(texts)

    if args.debug_folder:
        full_text_path = debug_path / "full_transcript.txt"
        with open(full_text_path, "w", encoding="utf-8") as f:
            f.write(full_text)
        print(f"Saved full transcript to {full_text_path}")

    if args.skip_tts:
        print("Skipping TTS per --skip-tts flag.")
    else:
        print("Generating audio...")
        text_to_speech(
            full_text,
            args.output,
            client,
            model=args.tts_model,
        )
        print(f"Saved audio to {args.output}")


if __name__ == "__main__":
    main()
