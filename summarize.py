#!/usr/bin/env python3

"""
Meeting summarization script using Ollama
Takes transcription text and generates meeting notes, summaries, and action items
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    print("Error: requests library not installed", file=sys.stderr)
    print("Install with: pip install requests", file=sys.stderr)
    sys.exit(1)


DEFAULT_OLLAMA_URL = "http://localhost:11434"
DEFAULT_NUM_CTX = 32768
DEFAULT_OLLAMA_TIMEOUT = int(os.environ.get("OLLAMA_TIMEOUT", "900"))
MAX_DIRECT_TRANSCRIPT_CHARS = 24000
CHUNK_TRANSCRIPT_CHARS = 18000

SUMMARY_PROMPT = """You are an assistant that writes concise meeting notes from transcripts.

Write the notes in the same language as the transcript. If the transcript is Dutch, write Dutch notes.
Only use facts from the transcript. Do not add generic project-management advice.

Produce the following sections using markdown headings:

## Summary
2-3 sentences covering what the meeting was about and what was concluded.

## Discussion
Bullet points of the main topics covered. Be specific, not generic.

## Decisions
Key decisions or conclusions reached. Omit this section if none were made.

## Action Items
A markdown checklist of concrete next steps that were explicitly agreed on, with owner and deadline if mentioned. Only include items that were clearly committed to — not vague intentions or possibilities. Omit this section entirely if there are no real action items.

## Participants
Names or roles of identifiable speakers, if mentioned.

Transcription:
{transcription}

Use markdown headings and bullet points. Do not wrap your response in a code block."""

CHUNK_PROMPT = """Vat dit deel van een transcript samen als feitelijke vergadernotities.

Schrijf in het Nederlands. Neem concrete technische punten, opties, risico's, beslissingen en expliciete acties op.
Gebruik alleen informatie uit dit transcriptdeel. Voeg niets toe.

Transcriptdeel {chunk_number}/{chunk_count}:
{transcription}

Markdown bullets:"""

FINAL_PROMPT = """Maak definitieve vergadernotities uit onderstaande deelsamenvattingen.

Schrijf in dezelfde taal als de deelsamenvattingen. Gebruik markdown met deze secties:

## Summary
2-3 zinnen over waar het gesprek over ging en wat de uitkomst was.

## Discussion
Concrete bullets met de belangrijkste besproken onderwerpen.

## Decisions
Alleen beslissingen of conclusies die echt zijn genomen. Laat weg als er geen zijn.

## Action Items
Markdown checklist met expliciete vervolgacties, eigenaar en deadline als genoemd. Laat weg als er geen echte acties zijn.

## Participants
Namen of rollen van herkenbare sprekers, als genoemd.

Gebruik alleen de deelsamenvattingen. Voeg geen generieke adviezen toe.

Deelsamenvattingen:
{chunk_summaries}

Definitieve notities:"""


def query_ollama(
    prompt: str,
    model: str = "llama3.1:8b",
    ollama_url: str = DEFAULT_OLLAMA_URL,
    num_ctx: int = DEFAULT_NUM_CTX,
    timeout: int = DEFAULT_OLLAMA_TIMEOUT,
) -> str:
    """
    Query Ollama API for text generation

    Args:
        prompt: The prompt to send
        model: Model name to use
        ollama_url: Ollama API URL

    Returns:
        Generated text response
    """
    try:
        prompt_text = (
            f"{prompt}\n\n/no_think" if model.lower().startswith("qwen3") else prompt
        )
        response = requests.post(
            f"{ollama_url}/api/generate",
            json={
                "model": model,
                "prompt": prompt_text,
                "stream": False,
                "think": False,
                "options": {
                    "num_ctx": num_ctx,
                    "num_predict": 2048,
                    "temperature": 0.2,
                },
            },
            timeout=timeout,
        )
        response.raise_for_status()
        return response.json()["response"]
    except requests.exceptions.RequestException as e:
        print(f"Error querying Ollama: {e}", file=sys.stderr)
        sys.exit(1)


def load_transcription(file_path: str) -> str:
    """Load transcription from file (supports .txt, .json)"""
    path = Path(file_path)

    if not path.exists():
        print(f"Error: Transcription file not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    if path.suffix == ".json":
        data = json.loads(path.read_text())
        return data.get("text", "")
    else:
        return path.read_text()


def summarize_meeting(
    transcription: str,
    model: str,
    ollama_url: str,
    timeout: int = DEFAULT_OLLAMA_TIMEOUT,
) -> dict:
    """Generate meeting notes from a transcription."""
    print(f"Generating meeting summary using {model}...", file=sys.stderr)

    if len(transcription) > MAX_DIRECT_TRANSCRIPT_CHARS:
        print("Transcript is long; summarizing in chunks first...", file=sys.stderr)
        chunk_summaries = _summarize_chunks(transcription, model, ollama_url, timeout)
        text = query_ollama(
            FINAL_PROMPT.format(chunk_summaries="\n\n".join(chunk_summaries)),
            model=model,
            ollama_url=ollama_url,
            timeout=timeout,
        )
    else:
        text = query_ollama(
            SUMMARY_PROMPT.format(transcription=transcription),
            model=model,
            ollama_url=ollama_url,
            timeout=timeout,
        )

    return {"summary": _strip_code_fence(text)}


def _summarize_chunks(
    transcription: str, model: str, ollama_url: str, timeout: int
) -> list[str]:
    """Summarize transcript chunks before the final summary pass."""
    chunks = _split_transcript(transcription, CHUNK_TRANSCRIPT_CHARS)
    summaries = []
    for index, chunk in enumerate(chunks, 1):
        print(f"Summarizing chunk {index}/{len(chunks)}...", file=sys.stderr)
        summary = query_ollama(
            CHUNK_PROMPT.format(
                chunk_number=index, chunk_count=len(chunks), transcription=chunk
            ),
            model=model,
            ollama_url=ollama_url,
            timeout=timeout,
        )
        summaries.append(f"### Deel {index}\n{_strip_code_fence(summary)}")
    return summaries


def _split_transcript(text: str, max_chars: int) -> list[str]:
    """Split a transcript into chunks on paragraph or sentence boundaries."""
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", text) if part.strip()]
    if len(paragraphs) <= 1:
        paragraphs = [
            part.strip() for part in re.split(r"(?<=[.!?])\s+", text) if part.strip()
        ]

    chunks = []
    current = ""
    for paragraph in paragraphs:
        if len(paragraph) > max_chars:
            if current:
                chunks.append(current.strip())
                current = ""
            chunks.extend(_split_long_text(paragraph, max_chars))
        elif current and len(current) + len(paragraph) + 2 > max_chars:
            chunks.append(current.strip())
            current = paragraph
        else:
            current = f"{current}\n\n{paragraph}" if current else paragraph

    if current:
        chunks.append(current.strip())
    return chunks


def _split_long_text(text: str, max_chars: int) -> list[str]:
    """Split text that has no useful boundaries."""
    return [
        text[index : index + max_chars].strip()
        for index in range(0, len(text), max_chars)
    ]


def _strip_code_fence(text: str) -> str:
    """Strip wrapping code fences that models sometimes add around markdown output."""
    # Match optional language tag: ```markdown or ```md or just ```.
    text = text.strip()
    text = re.sub(r"^```[a-z]*\n", "", text)
    text = re.sub(r"\n```$", "", text)
    return text.strip()


def save_summary(result: dict, output_file: str, format: str):
    """Save summary in specified format."""
    output_path = Path(output_file)

    if format in ("txt", "md"):
        output_path.write_text(result["summary"] + "\n")
    elif format == "json":
        output_path.write_text(json.dumps(result, indent=2))

    print(f"Summary saved to: {output_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Summarize meeting transcription using Ollama"
    )
    parser.add_argument(
        "transcription_file", help="Path to transcription file (.txt or .json)"
    )
    parser.add_argument(
        "-m",
        "--model",
        default="llama3.1:8b",
        help="Ollama model to use (default: llama3.1:8b)",
    )
    parser.add_argument(
        "-u",
        "--ollama-url",
        default=DEFAULT_OLLAMA_URL,
        help=f"Ollama API URL (default: {DEFAULT_OLLAMA_URL})",
    )
    parser.add_argument(
        "-f",
        "--format",
        default="md",
        choices=["txt", "md", "json"],
        help="Output format (default: md)",
    )
    parser.add_argument(
        "-o", "--output", help="Output file (default: transcription_file_summary.md)"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_OLLAMA_TIMEOUT,
        help=f"Ollama request timeout in seconds (default: {DEFAULT_OLLAMA_TIMEOUT})",
    )

    args = parser.parse_args()

    # Load transcription
    transcription = load_transcription(args.transcription_file)

    if not transcription.strip():
        print("Error: Transcription is empty", file=sys.stderr)
        sys.exit(1)

    # Determine output file
    if args.output:
        output_file = args.output
    else:
        trans_path = Path(args.transcription_file)
        suffix = ".md" if args.format == "md" else f".{args.format}"
        output_file = trans_path.with_name(f"{trans_path.stem}_summary{suffix}")

    # Generate summary
    try:
        result = summarize_meeting(
            transcription,
            model=args.model,
            ollama_url=args.ollama_url,
            timeout=args.timeout,
        )

        # Save results
        save_summary(result, output_file, args.format)

        print("\nSummarization complete!", file=sys.stderr)

    except Exception as e:
        print(f"Error during summarization: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
