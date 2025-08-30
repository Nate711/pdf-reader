"""PDF page transcription utilities."""

from __future__ import annotations

import base64
from typing import Any


def transcribe_page(image_bytes: bytes, client: Any, model: str, page_num: int | None = None) -> str:
    """Use the OpenAI client to transcribe a single PDF page image."""
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
                        "text": (
                            "Transcribe the text from this page of a PDF in natural reading order. "
                            "Return only the plain text. Summarize figure and figure captions instead "
                            "of transcribing them verbatim. Transcribe equations so that they can be "
                            "read aloud naturally by a text-to-speech model. Abbreviate author list with et al. "
                            "Skip non-text like arXiv:2502.04307v1 [cs.RO] 6 Feb 2025. "
                            "Transcribe verbatim except for previously described exceptions."
                        ),
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
