import argparse
import base64
import os
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


def render_pdf_to_images(pdf_path):
    doc = fitz.open(pdf_path)
    images = []
    for page in doc:
        pix = page.get_pixmap(dpi=200)
        images.append(pix.tobytes("png"))
    doc.close()
    return images


def transcribe_page(image_bytes, client, model):
    b64_image = base64.b64encode(image_bytes).decode("utf-8")
    response = client.responses.create(
        model=model,
        input=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": "Transcribe the text from this page of a PDF in natural reading order. Return only the plain text.",
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
    parser.add_argument("output", help="Path to output audio file (e.g., output.mp3)")
    parser.add_argument("--max-pages", type=int, default=None, help="Limit number of pages for processing (for testing)")
    args = parser.parse_args()

    client = get_client()

    images = render_pdf_to_images(args.pdf)
    texts = []
    total_pages = len(images)
    for idx, img in enumerate(images, start=1):
        if args.max_pages is not None and idx > args.max_pages:
            break
        print(f"Transcribing page {idx}/{total_pages}...")
        page_text = transcribe_page(img, client, model=os.getenv("TRANSCRIPTION_MODEL", "gpt-5"))
        texts.append(page_text)

    full_text = "\n".join(texts)
    print("Generating audio...")
    text_to_speech(full_text, args.output, client, model=os.getenv("TTS_MODEL", "gpt-4o-mini-tts"))
    print(f"Saved audio to {args.output}")


if __name__ == "__main__":
    main()
