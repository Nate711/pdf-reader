"""Text to speech utilities supporting multiple backends."""

from __future__ import annotations

from pathlib import Path
from typing import Any


# --- OpenAI TTS ---------------------------------------------------------------------------

def text_to_speech_openai(text: str, output_path: str | Path, client: Any, model: str, voice: str = "onyx") -> None:
    """Generate speech audio using OpenAI's TTS models."""
    output_file = Path(output_path)
    with client.audio.speech.with_streaming_response.create(
        model=model,
        voice=voice,
        input=text,
        instructions="""Accent/Affect: Warm, refined, and gently instructive, reminiscent of a friendly professor.

Tone: Calm, encouraging, and articulate, clearly describing each step with patience.

Emotion: Cheerful, supportive, and pleasantly enthusiastic; convey genuine enjoyment and appreciation of art.

Pronunciation: Clearly articulate  terminology

Personality Affect: Friendly and approachable with a hint of sophistication; speak confidently and reassuringly, guiding users through each step patiently and warmly.""",
    ) as response:
        response.stream_to_file(output_file)


# --- Gemini TTS ---------------------------------------------------------------------------

import wave
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover - only for type checkers
    from google import genai


def _wave_file(filename: str | Path, pcm: bytes, channels: int = 1, rate: int = 24000, sample_width: int = 2) -> None:
    with wave.open(str(filename), "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(sample_width)
        wf.setframerate(rate)
        wf.writeframes(pcm)


def text_to_speech_gemini(
    text: str,
    output_path: str | Path,
    client: "genai.Client",
    model: str = "gemini-2.5-flash-preview-tts",
    voice: str = "Kore",
) -> None:
    """Generate speech audio using Google's Gemini TTS service."""
    from google.genai import types  # imported lazily to keep dependency optional

    response = client.models.generate_content(
        model=model,
        contents=text,
        config=types.GenerateContentConfig(
            response_modalities=["AUDIO"],
            speech_config=types.SpeechConfig(
                voice_config=types.VoiceConfig(
                    prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice)
                )
            ),
        ),
    )
    data = response.candidates[0].content.parts[0].inline_data.data
    _wave_file(output_path, data)
