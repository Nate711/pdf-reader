import argparse
import base64
import json
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


def _get(obj, key, default=None):
    """Helper to get attribute or key from dict-like or object."""
    if isinstance(obj, dict):
        return obj.get(key, default)
    if hasattr(obj, key):
        return getattr(obj, key)
    return default


def _extract_text_from_response(response):
    """Extract plain text from a Responses API response across known shapes."""
    # 1) Legacy/mock path
    text = _get(response, "output_text")
    if isinstance(text, str) and text.strip():
        return text.strip()

    # 2) New Responses format with output -> [ { content: [ { type, text } ] } ]
    output = _get(response, "output")
    if isinstance(output, list):
        texts = []
        for item in output:
            content = _get(item, "content")
            if isinstance(content, list):
                for block in content:
                    btype = _get(block, "type")
                    if btype in ("output_text", "text"):
                        t = _get(block, "text")
                        if isinstance(t, str):
                            texts.append(t)
        if texts:
            return "".join(texts).strip()

    # 3) Fallback: try a generic string cast if the SDK offers .text
    maybe_text = _get(response, "text")
    if isinstance(maybe_text, str) and maybe_text.strip():
        return maybe_text.strip()

    return ""


def transcribe_page(image_bytes, client, model, page_num=None, log_data=None):
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

    # Extract transcription text according to the new Responses format
    transcription_text = _extract_text_from_response(response)

    # Log response details if log_data is provided
    if log_data is not None and page_num is not None:
        # Pull canonical fields from Responses API
        resp_id = _get(response, "id")
        status = _get(response, "status")
        created_at = _get(response, "created_at")
        resp_model = _get(response, "model")
        usage = _get(response, "usage")

        # Normalize usage to the new input/output/total token names, with fallbacks
        usage_log = None
        if usage is not None:
            input_tokens = _get(usage, "input_tokens")
            output_tokens = _get(usage, "output_tokens")
            total_tokens = _get(usage, "total_tokens")

            # Backwards-compat for older naming
            if input_tokens is None:
                input_tokens = _get(usage, "prompt_tokens")
            if output_tokens is None:
                output_tokens = _get(usage, "completion_tokens")
            if total_tokens is None and (input_tokens is not None or output_tokens is not None):
                try:
                    total_tokens = (input_tokens or 0) + (output_tokens or 0)
                except Exception:
                    total_tokens = None

            usage_log = {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "total_tokens": total_tokens,
            }

        page_log = {
            "page": page_num,
            "timestamp": datetime.now().isoformat(),
            "request_model": model,
            "response": {
                "id": resp_id,
                "status": status,
                "created_at": created_at,
                "model": resp_model,
            },
        }

        if usage_log is not None:
            page_log["usage"] = usage_log

            # Estimate cost (example placeholder rates; adjust as needed)
            itok = usage_log.get("input_tokens") or 0
            otok = usage_log.get("output_tokens") or 0
            input_cost = (itok / 1000) * 0.01
            output_cost = (otok / 1000) * 0.03
            page_log["estimated_cost"] = {
                "input": input_cost,
                "output": output_cost,
                "total": input_cost + output_cost,
                "currency": "USD",
            }

        log_data["transcription_calls"].append(page_log)

    return transcription_text


def text_to_speech(text, output_path, client, model, voice="alloy", log_data=None):
    output_file = Path(output_path)

    # Create the TTS request
    start_time = datetime.now()

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
        "--debug-folder",
        help="Optional folder to save rendered PDF pages as PNG images for debugging",
        default="debug_output",
    )
    args = parser.parse_args()

    client = get_client()

    # Initialize log data
    log_data = {
        "start_time": datetime.now().isoformat(),
        "input_pdf": args.pdf,
        "output_audio": args.output,
        "transcription_calls": [],
        "tts_call": None,
    }

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
            model=os.getenv("TRANSCRIPTION_MODEL", "gpt-5"),
            page_num=idx,
            log_data=log_data if args.debug_folder else None,
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

    print("Generating audio...")
    text_to_speech(
        full_text,
        args.output,
        client,
        model=os.getenv("TTS_MODEL", "gpt-4o-mini-tts"),
        log_data=log_data if args.debug_folder else None,
    )

    # Finalize and save log
    if args.debug_folder:
        log_data["end_time"] = datetime.now().isoformat()
        log_data["total_duration"] = (
            datetime.fromisoformat(log_data["end_time"]) - datetime.fromisoformat(log_data["start_time"])
        ).total_seconds()

        # Calculate total costs
        total_transcription_cost = sum(
            call.get("estimated_cost", {}).get("total", 0) for call in log_data["transcription_calls"]
        )
        total_tts_cost = log_data.get("tts_call", {}).get("estimated_cost", {}).get("total", 0)

        log_data["total_estimated_cost"] = {
            "transcription": total_transcription_cost,
            "tts": total_tts_cost,
            "total": total_transcription_cost + total_tts_cost,
            "currency": "USD",
        }

        log_path = debug_path / "api_log.json"
        with open(log_path, "w", encoding="utf-8") as f:
            json.dump(log_data, f, indent=2)
        print(f"Saved API log to {log_path}")

    print(f"Saved audio to {args.output}")


if __name__ == "__main__":
    main()
