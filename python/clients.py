"""Utilities for obtaining an OpenAI client with optional mocking.

This module exposes :func:`get_client` which returns either the real
``openai.OpenAI`` client or a lightweight mock.  The mock is used during
unit tests to avoid making network calls.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from openai import OpenAI


class _MockStreamingResponse:
    """Simple context manager that writes canned audio bytes to a file."""

    def __init__(self, data: bytes = b"mock audio") -> None:
        self._data = data

    def __enter__(self) -> "_MockStreamingResponse":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:  # pragma: no cover - no special handling
        return False

    def stream_to_file(self, path: os.PathLike[str] | str) -> None:
        with open(path, "wb") as fh:
            fh.write(self._data)


class _MockResponses:
    def create(self, *args: Any, **kwargs: Any) -> Any:
        class _Resp:
            output_text = "Mock transcription"

        return _Resp()


class _MockAudioSpeech:
    class WithStreamingResponse:
        def create(self, *args: Any, **kwargs: Any) -> _MockStreamingResponse:
            return _MockStreamingResponse()

    with_streaming_response = WithStreamingResponse()


class _MockAudio:
    speech = _MockAudioSpeech()


class MockOpenAI:
    """Minimal mock of the OpenAI client used for testing."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.responses = _MockResponses()
        self.audio = _MockAudio()


def get_client() -> OpenAI | MockOpenAI:
    """Return real or mock OpenAI client depending on environment."""
    if os.getenv("MOCK_OPENAI") == "1":
        return MockOpenAI()
    return OpenAI()
