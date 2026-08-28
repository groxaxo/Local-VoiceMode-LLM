from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import unquote

import pytest


ROOT = Path(__file__).resolve().parents[1]
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
SKIP_SCHEMES = (
    "http://",
    "https://",
    "mailto:",
    "data:",
)


def markdown_files() -> list[Path]:
    return sorted(path for path in ROOT.rglob("*.md") if ".git" not in path.parts)


@pytest.mark.parametrize("document", markdown_files(), ids=lambda path: str(path.relative_to(ROOT)))
def test_repository_relative_markdown_links_exist(document: Path) -> None:
    failures: list[str] = []

    for match in MARKDOWN_LINK.finditer(document.read_text(encoding="utf-8")):
        raw_target = match.group(1).strip()
        if not raw_target or raw_target.startswith("#") or raw_target.startswith(SKIP_SCHEMES):
            continue

        # Markdown permits an optional quoted title after the URL. Repository
        # documentation uses unquoted relative paths, but handle titles safely.
        target = raw_target
        if target.startswith("<") and ">" in target:
            target = target[1 : target.index(">")]
        elif " \"" in target:
            target = target.split(" \"", 1)[0]
        elif " '" in target:
            target = target.split(" '", 1)[0]

        target = unquote(target.split("#", 1)[0])
        if not target or target.startswith(SKIP_SCHEMES):
            continue

        candidate = (document.parent / target).resolve()
        try:
            candidate.relative_to(ROOT)
        except ValueError:
            failures.append(f"{target!r} escapes the repository")
            continue

        if not candidate.exists():
            failures.append(f"{target!r} does not exist")

    assert not failures, f"Broken links in {document.relative_to(ROOT)}:\n" + "\n".join(failures)
