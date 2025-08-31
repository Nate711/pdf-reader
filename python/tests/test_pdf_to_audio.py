import os
import sys
from pathlib import Path

sys.path.append(os.path.dirname(os.path.dirname(__file__)))
import pdf_to_audio


def test_pdf_to_audio_with_mock(tmp_path, monkeypatch):
    output = tmp_path / "out.mp3"
    monkeypatch.setenv("MOCK_OPENAI", "1")
    monkeypatch.setattr(sys, "argv", [
        "pdf_to_audio.py",
        str(Path("example.pdf")),
        str(output),
        "--max-pages",
        "1",
    ])
    pdf_to_audio.main()
    assert output.exists()
    assert output.read_bytes() == b"mock audio"
