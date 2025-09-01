"""PDF page transcription utilities (Google AI / Gemini)."""

from __future__ import annotations

import base64
from typing import Any

# Google AI (Gemini) SDK
from google.genai import types as genai_types


def _extract_text(resp: Any) -> str:
    """Best-effort extractor for text from a Gemini response."""
    # Some SDKs expose an aggregated .text convenience.
    txt = getattr(resp, "text", None)
    if isinstance(txt, str) and txt.strip():
        return txt.strip()
    # Fallback to first candidate parts.
    try:
        parts = resp.candidates[0].content.parts  # type: ignore[attr-defined]
    except Exception:
        return ""
    chunks: list[str] = []
    for p in parts:
        t = getattr(p, "text", None)
        if isinstance(t, str) and t:
            chunks.append(t)
    return "\n".join(chunks).strip()


def transcribe_page(image_bytes: bytes, client: Any, model: str, page_num: int | None = None) -> str:
    """Use the Google AI (Gemini) client to transcribe a single PDF page image.

    The prompt matches the original behavior; only the provider changes.
    """
    # Keep the original prompt verbatim
    prompt = (
        "Transcribe the text from this page of a PDF in natural reading order. "
        "Return only the plain text. Summarize figure and figure captions instead "
        "of transcribing them verbatim. Transcribe equations so that they can be "
        "read aloud naturally by a text-to-speech model. Abbreviate author list with et al. "
        "Skip non-text like arXiv:2502.04307v1 [cs.RO] 6 Feb 2025. "
        "Transcribe verbatim except for previously described exceptions."
    )

    contents = [
        genai_types.Content(
            role="user",
            parts=[
                genai_types.Part(text=prompt),
                genai_types.Part(
                    inline_data=genai_types.Blob(
                        mime_type="image/png", data=image_bytes
                    )
                ),
            ],
        )
    ]

    response = client.models.generate_content(
        model=model,
        contents=contents,
    )

    return _extract_text(response)
