#!/usr/bin/env python3
"""
Convert a Zoom AI meeting summary into the supervision meeting log section
format produced by setup_postgrad_drive.sh.

Usage:
    python zoom_summary_to_agenda.py summary.txt --date 2025-10-27 --time "14:00 SAST" \
        --connection "Teams" --attendees "Lead Supervisor, Student" \
        --apologies "Co-supervisor" --next-meeting "Propose 2025-11-10"

Pipe into a file:
    python zoom_summary_to_agenda.py summary.txt --date 2025-10-27 > meeting.md

See README for full flag descriptions.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Tuple


SECTION_NAMES = {
    "quick recap": "quick recap",
    "quick recap:": "quick recap",
    "recap": "quick recap",
    "recap:": "quick recap",
    "next steps": "next steps",
    "next steps:": "next steps",
    "actions": "next steps",
    "actions:": "next steps",
    "summary": "summary",
    "summary:": "summary",
}


SentenceList = List[str]
ActionList = List[Tuple[str, str]]


@dataclass
class ParsedSummary:
    quick_recap: SentenceList
    action_items: ActionList
    summary_topics: List[Tuple[str, str]]


def load_text(source: Path) -> str:
    try:
        return source.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SystemExit(f"error: input file '{source}' not found")


def normalise_line(line: str) -> str:
    return line.strip()


def split_sections(lines: Iterable[str]) -> dict:
    sections: dict[str, List[str]] = {"quick recap": [], "next steps": [], "summary": []}
    current_key: str | None = None

    for raw_line in lines:
        line = normalise_line(raw_line)
        if not line:
            continue
        key = SECTION_NAMES.get(line.lower())
        if key:
            current_key = key
            continue
        if current_key is None:
            continue
        sections[current_key].append(line)

    return sections


SENTENCE_END_RE = re.compile(r"(?<=[.!?])\s+")


def sentences_from_paragraph(paragraph: str) -> SentenceList:
    parts = [part.strip() for part in SENTENCE_END_RE.split(paragraph) if part.strip()]
    return parts or [paragraph.strip()]


def parse_quick_recap(lines: Iterable[str]) -> SentenceList:
    sentences: SentenceList = []
    for line in lines:
        sentences.extend(sentences_from_paragraph(line))
    return sentences


def parse_action_items(lines: Iterable[str]) -> ActionList:
    results: ActionList = []
    for line in lines:
        if ":" in line:
            owner, action = line.split(":", 1)
            owner = owner.strip()
            action = action.strip()
        else:
            owner = ""
            action = line.strip()
        if not action:
            continue
        results.append((owner or "TBD", action))
    return results


def parse_summary_topics(lines: Iterable[str]) -> List[Tuple[str, str]]:
    topics: List[Tuple[str, str]] = []
    current_title: str | None = None
    current_body: List[str] = []

    for line in lines:
        if not line:
            continue
        is_title = not re.search(r"[.!?]$", line)
        if is_title:
            if current_title or current_body:
                topics.append(
                    (
                        current_title or "Summary",
                        " ".join(current_body).strip(),
                    )
                )
            current_title = line.strip()
            current_body = []
            continue

        current_body.append(line.strip())

    if current_title or current_body:
        topics.append(
            (
                current_title or "Summary",
                " ".join(current_body).strip(),
            )
        )

    return topics


def parse_summary(text: str) -> ParsedSummary:
    lines = text.splitlines()
    sections = split_sections(lines)

    quick_recap = parse_quick_recap(sections["quick recap"])
    action_items = parse_action_items(sections["next steps"])
    summary_topics = parse_summary_topics(sections["summary"])

    return ParsedSummary(
        quick_recap=quick_recap,
        action_items=action_items,
        summary_topics=summary_topics,
    )


def format_agenda(topics: List[Tuple[str, str]]) -> List[str]:
    if topics:
        return [f"- {title}" for title, _ in topics]
    return ["- Updates from the supervisory team"]


def format_discussion_notes(quick_recap: SentenceList, topics: List[Tuple[str, str]]) -> List[str]:
    notes: List[str] = []
    if quick_recap:
        if len(quick_recap) == 1:
            notes.append(f"- Quick recap: {quick_recap[0]}")
        else:
            joined = "; ".join(quick_recap)
            notes.append(f"- Quick recap: {joined}")
    for title, body in topics:
        content = body if body else "Discussion captured in Zoom summary."
        notes.append(f"- {title}: {content}")
    if not notes:
        notes.append("- Discussion notes pending.")
    return notes


def format_action_table(items: ActionList) -> List[str]:
    rows: List[str] = [
        "| Action | Owner | Due | Status |",
        "|--------|-------|-----|--------|",
    ]
    if not items:
        rows.append("| No action items recorded | - | - | - |")
        return rows
    for owner, action in items:
        rows.append(f"| {action} | {owner} |  | Open |")
    return rows


def build_markdown(parsed: ParsedSummary, args: argparse.Namespace) -> str:
    date_label = args.date or "YYYY-MM-DD"
    time_label = args.time or "TBD"
    connection_label = args.connection or "TBD"
    if connection_label and connection_label != "TBD":
        time_connection = f"{time_label} — {connection_label}"
    else:
        time_connection = time_label

    attendees = args.attendees or args.student or "TBD"
    apologies = args.apologies or "None"

    agenda_lines = format_agenda(parsed.summary_topics)
    discussion_lines = format_discussion_notes(parsed.quick_recap, parsed.summary_topics)
    action_table = format_action_table(parsed.action_items)
    follow_up = args.follow_up or "- Note any reminders or checks before the next meeting."

    parts: List[str] = [
        "---",
        f"## Meeting {date_label}",
        "",
        f"- **Date:** {date_label}",
        f"- **Time / connection:** {time_connection}",
        f"- **Next meeting:** {args.next_meeting or 'TBD'}",
        f"- **Attendees:** {attendees}",
        f"- **Apologies:** {apologies}",
        "",
        "### Agenda",
        *agenda_lines,
        "",
        "### Discussion notes",
        *discussion_lines,
        "",
        "### Action items",
        *action_table,
        "",
        "### Follow-up",
        follow_up,
        "",
    ]

    return "\n".join(parts)


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a Zoom AI meeting summary into a supervision meeting log section."
    )
    parser.add_argument("input", type=Path, help="Path to the Zoom AI summary text file")
    parser.add_argument("-o", "--output", type=Path, help="Path for the generated agenda (defaults to stdout)")
    parser.add_argument("--date", default="YYYY-MM-DD", help="Meeting date")
    parser.add_argument("--time", default="TBD", help="Meeting time")
    parser.add_argument("--connection", default="TBD", help="Primary connection method (e.g. Teams link)")
    parser.add_argument("--attendees", default="", help="Comma-separated attendee list")
    parser.add_argument("--apologies", default="", help="Comma-separated apologies list")
    parser.add_argument("--student", default="", help="Deprecated: use --attendees instead")
    parser.add_argument("--next-meeting", default="TBD", help="Details for the next meeting")
    parser.add_argument("--follow-up", help="Override the default follow-up note")
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    source_text = load_text(args.input)
    parsed = parse_summary(source_text)
    markdown = build_markdown(parsed, args)

    if args.output:
        try:
            args.output.write_text(markdown, encoding="utf-8")
        except OSError as exc:
            raise SystemExit(f"error: failed to write output file: {exc}") from exc
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
