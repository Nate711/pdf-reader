import argparse
import base64
import os
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

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
                        "text": "Transcribe the text from this page of a PDF in natural reading order. Return only the plain text. Summarize figure and figure captions instead of transcribing them verbatim. Transcribe equations so that they can be read aloud naturally by a text-to-speech model. Abbreviate author list with et al",
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


def text_to_speech(text, output_path, client, model, voice="onyx"):
    output_file = Path(output_path)

    with client.audio.speech.with_streaming_response.create(
        model=model,
        voice=voice,
        input=text,
        instructions="""Accent/Affect: Warm, refined, and gently instructive, reminiscent of a friendly professor.

Tone: Calm, encouraging, and articulate, clearly describing each step with patience.

Pacing: Fast and deliberate, pausing often to allow the listener to follow instructions comfortably.

Emotion: Cheerful, supportive, and pleasantly enthusiastic; convey genuine enjoyment and appreciation of art.

Pronunciation: Clearly articulate  terminology

Personality Affect: Friendly and approachable with a hint of sophistication; speak confidently and reassuringly, guiding users through each step patiently and warmly.""",
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
    # Select pages to process (respect --max-pages)
    pages = []
    for idx, img in enumerate(images, start=1):
        if args.max_pages is not None and idx > args.max_pages:
            break
        pages.append((idx, img))
    total_pages = len(pages)

    if args.debug_folder:
        debug_path = Path(args.debug_folder)
        debug_path.mkdir(parents=True, exist_ok=True)

    # Transcribe pages in parallel (I/O bound -> threads)
    texts = [None] * total_pages
    if total_pages:
        print(f"Transcribing {total_pages} page(s) in parallel...")
    with ThreadPoolExecutor(max_workers=min(8, max(1, total_pages))) as ex:
        future_to_idx = {
            ex.submit(transcribe_page, img, client, args.transcription_model, idx): idx for idx, img in pages
        }
        for fut in as_completed(future_to_idx):
            idx = future_to_idx[fut]
            page_text = fut.result()
            texts[idx - 1] = page_text
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
        # Generate per-page MP3s in parallel and a combined MP3
        print("Generating per-page audio files in parallel...")
        out_path = Path(args.output)
        out_dir = out_path.parent
        stem = out_path.stem

        # Submit TTS jobs for non-empty pages
        tasks = {}
        nonempty_pages = [(idx, t) for idx, t in enumerate(texts, start=1) if t and t.strip()]
        max_workers = min(8, max(1, len(nonempty_pages)))
        page_files_map = {}
        if nonempty_pages:
            with ThreadPoolExecutor(max_workers=max_workers) as ex:
                for idx, text in nonempty_pages:
                    page_mp3 = out_dir / f"{stem}_page_{idx:03d}.mp3"
                    fut = ex.submit(text_to_speech, text, page_mp3, client, args.tts_model)
                    tasks[fut] = (idx, page_mp3)

                for fut in as_completed(tasks):
                    idx, page_mp3 = tasks[fut]
                    # Any exceptions will raise here
                    fut.result()
                    page_files_map[idx] = page_mp3
                    print(f"  Saved page {idx} audio to {page_mp3}")

        # Combine all per-page MP3s into the final output by naive concatenation (in order)
        if page_files_map:
            ordered_pages = sorted(page_files_map.keys())
            with open(out_path, "wb") as combined:
                for idx in ordered_pages:
                    p = page_files_map[idx]
                    with open(p, "rb") as f:
                        combined.write(f.read())
            print(f"Saved combined audio to {args.output}")
        else:
            print("No page audio generated (all pages empty). Skipping combined file.")


if __name__ == "__main__":
    main()
