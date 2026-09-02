"""Turn a timestamped capture into an asciicast that plays at real speed.

Reads lines of "<epoch-millis>|<text>" on stdin and writes an asciicast v2 file.
The timing is the timing the system actually answered with, which is the only
reason a recording of a verifier is worth anything: an invented cadence would
make a slow check look fast.

Two constraints the format does not enforce and a reader will notice:

  * nothing may wrap. A wrapped line forces a redraw of the whole frame, and a
    recording that scrolls goes from 100 KB to well over a megabyte.
  * the terminal is exactly as tall as the content. Empty rows at the bottom
    are a third of the frame spent on nothing.
"""

import json
import re
import sys

WIDTH = 104
ANSI = re.compile(r"\x1b\[[0-9;]*m")
BOLD, GREEN, RESET = "\x1b[1m", "\x1b[32m", "\x1b[0m"


def shorten(text: str) -> str:
    """Fit one line of output on one terminal row."""
    # Digests are abbreviated rather than dropped: a section with its heading
    # and no lines under it reads as a broken run.
    text = re.sub(r"(sha256:)([0-9a-f]{8})[0-9a-f]{48}([0-9a-f]{8})", r"\1\2...\3", text)
    text = re.sub(r"BuildIdentity ([a-z-]+)/([a-z0-9-]+)", r"BuildIdentity .../\2", text)

    plain = ANSI.sub("", text)
    if len(plain) <= WIDTH:
        return text

    head, sep, tail = text.partition(RESET)
    if not sep:
        return plain[: WIDTH - 1] + "…"
    keep = WIDTH - len(ANSI.sub("", head + sep)) - 1
    return head + sep + ANSI.sub("", tail)[:keep] + "…"


def main() -> None:
    command = sys.argv[1]
    out_path = sys.argv[2]

    captured = []
    for raw in sys.stdin:
        stamp, _, text = raw.rstrip("\n").partition("|")
        captured.append((int(stamp), text))
    if not captured:
        raise SystemExit("nothing captured")

    base = captured[0][0]
    events = [[0.0, "o", f"{GREEN}mampi{RESET}:{BOLD}~/provenance-gate{RESET}$ "]]

    # Typed at a human speed, so it reads as a session rather than a log dump.
    for i, char in enumerate(command):
        events.append([0.35 + i * 0.045, "o", char])
    start = 0.35 + len(command) * 0.045 + 0.3
    events.append([start, "o", "\r\n"])

    offset = start + 0.15
    for stamp, text in captured:
        events.append([offset + (stamp - base) / 1000.0, "o", shorten(text) + "\r\n"])

    # A beat on the final frame, so the verdict is readable before it loops.
    events.append([events[-1][0] + 2.5, "o", ""])

    header = {
        "version": 2,
        "width": WIDTH,
        "height": len(captured) + 2,
        "timestamp": 0,
        "env": {"SHELL": "/bin/bash", "TERM": "xterm-256color"},
    }

    with open(out_path, "w", encoding="utf-8") as out:
        out.write(json.dumps(header) + "\n")
        for when, kind, data in events:
            out.write(json.dumps([round(when, 3), kind, data]) + "\n")

    longest = max(len(ANSI.sub("", shorten(t))) for _, t in captured)
    print(
        f"{out_path}: rows={header['height']} longest={longest}/{WIDTH} "
        f"duration={events[-1][0]:.1f}s",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
