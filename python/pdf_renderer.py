"""PDF rendering utilities."""

from __future__ import annotations

from pathlib import Path
from typing import List

import fitz  # PyMuPDF


def render_pdf_to_images(pdf_path: str | Path, debug_folder: str | Path | None = None) -> List[bytes]:
    """Render ``pdf_path`` to a list of PNG image bytes.

    If ``debug_folder`` is provided the individual page images are also
    written to disk for inspection.
    """
    doc = fitz.open(pdf_path)
    images: List[bytes] = []

    debug_path: Path | None = None
    if debug_folder:
        debug_path = Path(debug_folder)
        debug_path.mkdir(parents=True, exist_ok=True)
        print(f"Saving rendered pages to {debug_path}")

    for page_num, page in enumerate(doc, start=1):
        pix = page.get_pixmap(dpi=200)
        image_bytes = pix.tobytes("png")
        images.append(image_bytes)

        if debug_path is not None:
            image_path = debug_path / f"page_{page_num:03d}.png"
            with open(image_path, "wb") as f:
                f.write(image_bytes)
            print(f"  Saved page {page_num} to {image_path}")

    doc.close()
    return images
