#!/usr/bin/env python3
"""Build the AExp documentation site from the repository's Markdown graph.

The source of truth remains README.md and the repository-local documents and
assets reachable from it.  The generated site is disposable and is never
written back into the source documents.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import importlib.util
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
from collections import deque
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit, urlunsplit


DOC_DIR = Path(__file__).resolve().parent
REPO_ROOT = DOC_DIR.parent
ENTRY_DOCUMENT = REPO_ROOT / "README.md"
REQUIREMENTS = DOC_DIR / "requirements-doc.txt"
THEME_DIR = DOC_DIR / "theme"
DEFAULT_OUTPUT = REPO_ROOT / "site"
VENV_DIR = DOC_DIR / ".venv"

MARKDOWN_SUFFIXES = {".md", ".markdown"}
MARKDOWN_LINK_RE = re.compile(
    r"(?P<prefix>!?\[[^\]\n]*\]\()"
    r"(?P<destination><[^>\n]+>|[^\s)]+)"
    r"(?P<suffix>(?:\s+(?:\"[^\"\n]*\"|'[^'\n]*'))?\))"
)
HTML_LINK_RE = re.compile(
    r"(?P<prefix>\b(?:href|src)\s*=\s*[\"'])"
    r"(?P<destination>[^\"']+)"
    r"(?P<suffix>[\"'])",
    re.IGNORECASE,
)

PREFERRED_NAVIGATION = (
    (
        "Using the core",
        (
            ("Mouse and joystick", "doc/mouse.md"),
            ("Keyboard mappings", "doc/keyboard.md"),
            ("Video modes", "doc/video_modes.md"),
            ("Retro CRT monitors", "doc/retrotubes.md"),
            ("Screen adjustment", "doc/screen_adjust.md"),
            ("Real-time clock", "doc/RTC.md"),
        ),
    ),
    ("Releases", (("Work-in-progress builds", "doc/inofficial.md"),)),
    ("Development", (("Building from source", "doc/developers.md"),)),
)


class DocumentationError(RuntimeError):
    """A user-facing documentation build failure."""


@dataclass(frozen=True)
class LocalLink:
    source: Path
    destination: str
    target: Path
    line: int


@dataclass
class DocumentationGraph:
    pages: list[Path]
    assets: list[Path]
    links: dict[Path, list[LocalLink]]


class SiteHTMLParser(HTMLParser):
    """Collect local resource references and anchors from generated HTML."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.references: list[str] = []
        self.identifiers: set[str] = set()

    def handle_starttag(self, _tag: str, attributes: list[tuple[str, str | None]]) -> None:
        for name, value in attributes:
            if value is None:
                continue
            if name == "id":
                self.identifiers.add(value)
            elif name in {"href", "src"}:
                self.references.append(value)


def repo_relative(path: Path) -> Path:
    return path.resolve().relative_to(REPO_ROOT)


def staged_relative(path: Path) -> Path:
    relative = repo_relative(path)
    return Path("index.md") if relative == Path("README.md") else relative


def is_external(destination: str) -> bool:
    parsed = urlsplit(destination)
    return bool(parsed.scheme or parsed.netloc or destination.startswith("//"))


def resolve_local_link(source: Path, destination: str, line: int) -> LocalLink | None:
    clean_destination = html.unescape(destination.strip())
    if clean_destination.startswith("<") and clean_destination.endswith(">"):
        clean_destination = clean_destination[1:-1]

    if not clean_destination or is_external(clean_destination):
        return None

    parsed = urlsplit(clean_destination)
    if not parsed.path:
        return None  # An anchor on the current page.
    if parsed.path.startswith("/"):
        return None  # A site-root URL, not a repository path.

    target = (source.parent / unquote(parsed.path)).resolve()
    try:
        target.relative_to(REPO_ROOT)
    except ValueError as exc:
        raise DocumentationError(
            f"{repo_relative(source)}:{line}: local link escapes the repository: "
            f"{destination}"
        ) from exc

    if not target.exists():
        raise DocumentationError(
            f"{repo_relative(source)}:{line}: linked file does not exist: {destination}"
        )
    if not target.is_file():
        raise DocumentationError(
            f"{repo_relative(source)}:{line}: linked path is not a file: {destination}"
        )

    return LocalLink(source, destination, target, line)


def links_in_document(source: Path) -> list[LocalLink]:
    text = source.read_text(encoding="utf-8")
    matches = list(MARKDOWN_LINK_RE.finditer(text)) + list(HTML_LINK_RE.finditer(text))
    matches.sort(key=lambda match: match.start())

    links: list[LocalLink] = []
    for match in matches:
        line = text.count("\n", 0, match.start()) + 1
        link = resolve_local_link(source, match.group("destination"), line)
        if link is not None:
            links.append(link)
    return links


def discover_documentation() -> DocumentationGraph:
    if not ENTRY_DOCUMENT.is_file():
        raise DocumentationError(f"Entry document is missing: {ENTRY_DOCUMENT}")

    queue: deque[Path] = deque([ENTRY_DOCUMENT.resolve()])
    seen_pages: set[Path] = set()
    pages: list[Path] = []
    assets: list[Path] = []
    seen_assets: set[Path] = set()
    links: dict[Path, list[LocalLink]] = {}

    while queue:
        page = queue.popleft()
        if page in seen_pages:
            continue
        seen_pages.add(page)
        pages.append(page)

        page_links = links_in_document(page)
        links[page] = page_links
        for link in page_links:
            if link.target.suffix.lower() in MARKDOWN_SUFFIXES:
                if link.target not in seen_pages:
                    queue.append(link.target)
            elif link.target not in seen_assets:
                seen_assets.add(link.target)
                assets.append(link.target)

    return DocumentationGraph(pages, assets, links)


def rewrite_local_links(text: str, source: Path) -> str:
    staged_source = staged_relative(source)

    def replace(match: re.Match[str]) -> str:
        destination = match.group("destination")
        try:
            link = resolve_local_link(source, destination, text.count("\n", 0, match.start()) + 1)
        except DocumentationError:
            raise
        if link is None:
            return match.group(0)

        parsed = urlsplit(html.unescape(destination.strip("<>")))
        target = staged_relative(link.target)
        start = staged_source.parent.as_posix()
        relative = posixpath.relpath(target.as_posix(), start)
        rewritten = urlunsplit(("", "", relative, parsed.query, parsed.fragment))
        if destination.startswith("<") and destination.endswith(">"):
            rewritten = f"<{rewritten}>"
        return f"{match.group('prefix')}{rewritten}{match.group('suffix')}"

    text = MARKDOWN_LINK_RE.sub(replace, text)
    return HTML_LINK_RE.sub(replace, text)


def page_title(page: Path) -> str:
    lines = page.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^#\s+(.+?)\s*#*\s*$", line)
        if match:
            return clean_title(match.group(1))
        if index + 1 < len(lines) and re.match(r"^=+\s*$", lines[index + 1]):
            return clean_title(line)
    return page.stem.replace("-", " ").replace("_", " ").title()


def clean_title(title: str) -> str:
    title = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", title)
    return re.sub(r"[*_`]", "", title).strip()


def yaml_string(value: str | Path) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def navigation_yaml(graph: DocumentationGraph) -> str:
    discovered = {repo_relative(page).as_posix(): page for page in graph.pages}
    included: set[str] = {"README.md"}
    lines = ["nav:", '  - "Home": "index.md"']

    for section, entries in PREFERRED_NAVIGATION:
        available = [(label, path) for label, path in entries if path in discovered]
        if not available:
            continue
        lines.append(f"  - {yaml_string(section)}:")
        for label, path in available:
            included.add(path)
            lines.append(
                f"      - {yaml_string(label)}: {yaml_string(staged_relative(discovered[path]).as_posix())}"
            )

    remaining = [
        page
        for page in graph.pages
        if repo_relative(page).as_posix() not in included
    ]
    if remaining:
        lines.append('  - "More":')
        for page in remaining:
            lines.append(
                f"      - {yaml_string(page_title(page))}: "
                f"{yaml_string(staged_relative(page).as_posix())}"
            )

    return "\n".join(lines)


def mkdocs_configuration(graph: DocumentationGraph, docs_dir: Path, site_dir: Path) -> str:
    return f"""\
site_name: "AExp Documentation"
site_description: "Amiga 500 for the MEGA65"
site_url: "https://sy2002.github.io/AExp/"
repo_url: "https://github.com/sy2002/AExp"
repo_name: "sy2002/AExp"
docs_dir: {yaml_string(docs_dir)}
site_dir: {yaml_string(site_dir)}
use_directory_urls: true
strict: true

theme:
  name: material
  language: en
  logo: "_theme/logo.svg"
  favicon: "_theme/favicon.svg"
  font: false
  features:
    - navigation.sections
    - navigation.top
    - navigation.footer
    - navigation.tracking
    - toc.follow
    - search.highlight
    - search.suggest
    - content.code.copy
  palette:
    scheme: default
    primary: custom
    accent: custom

plugins:
  - search:
      lang: en

markdown_extensions:
  - tables
  - fenced_code
  - attr_list
  - def_list
  - md_in_html
  - toc:
      permalink: true
      permalink_title: "Link to this section"
  - pymdownx.highlight:
      anchor_linenums: true
  - pymdownx.superfences

extra_css:
  - "_theme/extra.css"

copyright: "AExp · Amiga 500 for MEGA65"

{navigation_yaml(graph)}
"""


def copy_theme(docs_dir: Path) -> None:
    theme_target = docs_dir / "_theme"
    theme_target.mkdir(parents=True, exist_ok=True)
    for name in ("extra.css", "logo.svg", "favicon.svg"):
        source = THEME_DIR / name
        if not source.is_file():
            raise DocumentationError(f"Theme asset is missing: {source}")
        shutil.copy2(source, theme_target / name)


def prepare_staging(graph: DocumentationGraph, staging_root: Path, site_dir: Path) -> Path:
    docs_dir = staging_root / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)

    for page in graph.pages:
        target = docs_dir / staged_relative(page)
        target.parent.mkdir(parents=True, exist_ok=True)
        source_text = page.read_text(encoding="utf-8")
        target.write_text(rewrite_local_links(source_text, page), encoding="utf-8")

    for asset in graph.assets:
        target = docs_dir / staged_relative(asset)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(asset, target)

    copy_theme(docs_dir)
    config = staging_root / "mkdocs.yml"
    config.write_text(mkdocs_configuration(graph, docs_dir, site_dir), encoding="utf-8")
    return config


def requirements_fingerprint() -> str:
    digest = hashlib.sha256()
    digest.update(REQUIREMENTS.read_bytes())
    digest.update(f"{sys.version_info.major}.{sys.version_info.minor}".encode("ascii"))
    return digest.hexdigest()


def venv_python() -> Path:
    if os.name == "nt":
        return VENV_DIR / "Scripts" / "python.exe"
    return VENV_DIR / "bin" / "python"


def ensure_mkdocs() -> Path:
    if importlib.util.find_spec("mkdocs") is not None:
        return Path(sys.executable)

    if not REQUIREMENTS.is_file():
        raise DocumentationError(f"Dependency file is missing: {REQUIREMENTS}")

    python = venv_python()
    stamp = VENV_DIR / ".aexp-doc-requirements"
    wanted = requirements_fingerprint()
    installed = stamp.read_text(encoding="ascii").strip() if stamp.is_file() else ""

    if not python.is_file():
        print(f"Creating documentation environment in {VENV_DIR.relative_to(REPO_ROOT)} ...")
        subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)], check=True)

    if installed != wanted:
        print("Installing pinned documentation dependencies ...")
        subprocess.run(
            [
                str(python),
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "-r",
                str(REQUIREMENTS),
            ],
            check=True,
        )
        stamp.write_text(wanted + "\n", encoding="ascii")

    return python


def mkdocs_environment() -> dict[str, str]:
    environment = os.environ.copy()
    # This project deliberately pins MkDocs 1.x. Material's warning concerns a
    # possible future MkDocs 2.x migration and otherwise obscures build errors.
    environment.setdefault("NO_MKDOCS_2_WARNING", "true")
    return environment


def validate_output_path(output: Path) -> Path:
    output = output.expanduser().resolve()
    protected = {REPO_ROOT, DOC_DIR, THEME_DIR, ENTRY_DOCUMENT}
    if output in protected:
        raise DocumentationError(f"Refusing unsafe output directory: {output}")
    if output in REPO_ROOT.parents or (output / ".git").exists():
        raise DocumentationError(f"Refusing unsafe output directory: {output}")
    return output


def generated_target(site_dir: Path, source: Path, reference: str) -> tuple[Path, str] | None:
    if not reference or is_external(reference):
        return None
    parsed = urlsplit(html.unescape(reference))
    if not parsed.path:
        return source, unquote(parsed.fragment)

    path = unquote(parsed.path)
    if path.startswith("/AExp/"):
        target = site_dir / path.removeprefix("/AExp/")
    elif path == "/AExp/":
        target = site_dir
    elif path.startswith("/"):
        return None
    else:
        target = (source.parent / path).resolve()

    try:
        target.relative_to(site_dir)
    except ValueError as exc:
        raise DocumentationError(
            f"Generated link escapes the site: {source.relative_to(site_dir)} -> {reference}"
        ) from exc

    if path.endswith("/") or target.is_dir():
        target /= "index.html"
    return target, unquote(parsed.fragment)


def validate_generated_site(site_dir: Path) -> None:
    parsed_pages: dict[Path, SiteHTMLParser] = {}
    for page in site_dir.rglob("*.html"):
        parser = SiteHTMLParser()
        parser.feed(page.read_text(encoding="utf-8"))
        parsed_pages[page.resolve()] = parser

    errors: list[str] = []
    for page, parser in parsed_pages.items():
        for reference in parser.references:
            resolved = generated_target(site_dir, page, reference)
            if resolved is None:
                continue
            target, fragment = resolved
            if not target.is_file():
                errors.append(f"{page.relative_to(site_dir)} -> {reference} (missing file)")
                continue
            if fragment and target.suffix.lower() == ".html":
                target_parser = parsed_pages.get(target.resolve())
                if target_parser is not None and fragment not in target_parser.identifiers:
                    errors.append(f"{page.relative_to(site_dir)} -> {reference} (missing anchor)")

    if errors:
        details = "\n  ".join(errors[:20])
        remainder = "" if len(errors) <= 20 else f"\n  ... and {len(errors) - 20} more"
        raise DocumentationError(f"Generated site contains broken links:\n  {details}{remainder}")
    print(f"Generated-site links are valid across {len(parsed_pages)} HTML pages")


def print_graph(graph: DocumentationGraph) -> None:
    print(f"Documentation graph is valid: {len(graph.pages)} pages, {len(graph.assets)} assets")
    for page in graph.pages:
        print(f"  page   {repo_relative(page)}")
    for asset in graph.assets:
        print(f"  asset  {repo_relative(asset)}")


def command_check(_args: argparse.Namespace) -> int:
    print_graph(discover_documentation())
    return 0


def command_build(args: argparse.Namespace) -> int:
    graph = discover_documentation()
    output = validate_output_path(Path(args.output))
    python = ensure_mkdocs()

    with tempfile.TemporaryDirectory(prefix="aexp-docs-") as temporary:
        config = prepare_staging(graph, Path(temporary), output)
        subprocess.run(
            [str(python), "-m", "mkdocs", "build", "--clean", "--strict", "-f", str(config)],
            cwd=REPO_ROOT,
            env=mkdocs_environment(),
            check=True,
        )

    (output / ".nojekyll").touch()
    validate_generated_site(output)
    print_graph(graph)
    print(f"Static site built in {output}")
    return 0


def command_serve(args: argparse.Namespace) -> int:
    graph = discover_documentation()
    python = ensure_mkdocs()

    with tempfile.TemporaryDirectory(prefix="aexp-docs-preview-") as temporary:
        staging = Path(temporary)
        config = prepare_staging(graph, staging, staging / "site")
        print_graph(graph)
        print(
            f"Previewing at http://{args.address}/AExp/ "
            "(restart after editing source documents)"
        )
        subprocess.run(
            [str(python), "-m", "mkdocs", "serve", "-f", str(config), "--dev-addr", args.address],
            cwd=REPO_ROOT,
            env=mkdocs_environment(),
            check=True,
        )
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Build the AExp GitHub Pages documentation from README.md and local links."
    )
    subparsers = result.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check", help="validate and display the documentation graph")
    check.set_defaults(handler=command_check)

    build = subparsers.add_parser("build", help="build the static HTML site")
    build.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help=f"output directory (default: {DEFAULT_OUTPUT.relative_to(REPO_ROOT)})",
    )
    build.set_defaults(handler=command_build)

    serve = subparsers.add_parser("serve", help="serve a local snapshot for preview")
    serve.add_argument("--address", default="127.0.0.1:8000", help="preview host and port")
    serve.set_defaults(handler=command_serve)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return args.handler(args)
    except DocumentationError as exc:
        print(f"documentation error: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"documentation command failed with exit code {exc.returncode}", file=sys.stderr)
        return exc.returncode or 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
