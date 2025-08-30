"""Command line utility to convert a PDF into spoken audio."""

from __future__ import annotations

import argparse
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from clients import get_client
from pdf_renderer import render_pdf_to_images
from transcriber import transcribe_page
from tts import text_to_speech_openai, text_to_speech_gemini


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert a PDF into an audio file using AI APIs.")
    parser.add_argument("pdf", help="Path to input PDF file")
    parser.add_argument(
        "output",
        nargs="?",
        default=None,
        help="Path to output audio file (default: output.mp3 or output.wav depending on engine)",
    )
    parser.add_argument("--max-pages", type=int, default=None, help="Limit number of pages for processing (for testing)")
    parser.add_argument(
        "--transcription-model",
        default="gpt-5",
        help="Model to use for page transcription (default: gpt-5)",
    )
    parser.add_argument("--tts-model", default=None, help="Model to use for text-to-speech")
    parser.add_argument(
        "--tts-engine",
        choices=["openai", "gemini"],
        default="openai",
        help="Which TTS backend to use",
    )
    parser.add_argument("--voice", default=None, help="Voice to use for TTS")
    parser.add_argument(
        "--skip-tts", action="store_true", help="Skip text-to-speech generation and only transcribe"
    )
    parser.add_argument(
        "--debug-folder",
        help="Optional folder to save rendered PDF pages as PNG images for debugging",
        default="debug_output",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()

    if args.output is None:
        args.output = "output.wav" if args.tts_engine == "gemini" else "output.mp3"

    client = get_client()

    images = render_pdf_to_images(args.pdf, debug_folder=args.debug_folder)

    pages: list[tuple[int, bytes]] = []
    for idx, img in enumerate(images, start=1):
        if args.max_pages is not None and idx > args.max_pages:
            break
        pages.append((idx, img))
    total_pages = len(pages)

    if args.debug_folder:
        debug_path = Path(args.debug_folder)
        debug_path.mkdir(parents=True, exist_ok=True)

    texts: list[str | None] = [None] * total_pages
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

    full_text = "\n".join(t for t in texts if t)

    if args.debug_folder:
        full_text_path = debug_path / "full_transcript.txt"
        with open(full_text_path, "w", encoding="utf-8") as f:
            f.write(full_text)
        print(f"Saved full transcript to {full_text_path}")

    if args.skip_tts:
        print("Skipping TTS per --skip-tts flag.")
        return

    # Determine TTS backend
    tts_model = args.tts_model
    voice = args.voice
    if args.tts_engine == "openai":
        tts_model = tts_model or "gpt-4o-mini-tts"
        voice = voice or "onyx"
        tts_client = client
        tts_func = text_to_speech_openai
    else:
        from google import genai

        tts_client = genai.Client()
        tts_model = tts_model or "gemini-2.5-flash-preview-tts"
        voice = voice or "Kore"
        tts_func = text_to_speech_gemini

    print("Generating per-page audio files in parallel...")
    out_path = Path(args.output)
    out_dir = out_path.parent
    stem = out_path.stem
    suffix = out_path.suffix or (".wav" if args.tts_engine == "gemini" else ".mp3")

    tasks: dict[Any, tuple[int, Path]] = {}
    nonempty_pages = [(idx, t) for idx, t in enumerate(texts, start=1) if t and t.strip()]
    max_workers = min(8, max(1, len(nonempty_pages)))
    page_files_map: dict[int, Path] = {}
    if nonempty_pages:
        with ThreadPoolExecutor(max_workers=max_workers) as ex:
            for idx, text in nonempty_pages:
                page_audio = out_dir / f"{stem}_page_{idx:03d}{suffix}"
                fut = ex.submit(tts_func, text, page_audio, tts_client, tts_model, voice)
                tasks[fut] = (idx, page_audio)

            for fut in as_completed(tasks):
                idx, page_audio = tasks[fut]
                fut.result()  # propagate exceptions
                page_files_map[idx] = page_audio
                print(f"  Saved page {idx} audio to {page_audio}")

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


if __name__ == "__main__":  # pragma: no cover
    main()

