# Building the documentation website

`make_doc.py` turns the repository's existing Markdown documentation into the
static website published at <https://sy2002.github.io/AExp/>. Generated HTML is
disposable: it is ignored by Git and never written back into the source files.

## What it does

The script starts at the root `README.md` and follows repository-local links
recursively. Linked Markdown files become pages, while linked images and other
files become static assets. External web links remain external. Missing files,
paths that escape the repository, and broken links or anchors in the generated
site cause the build to fail.

For each build, the script creates a temporary MkDocs source tree, stages the
root README as the site's `index.md`, rewrites local links for the staged layout,
adds the navigation and Amiga-inspired theme, and runs a strict MkDocs build.
The temporary tree is removed afterwards.

The first build creates an ignored Python environment in `doc/.venv` and
installs the versions pinned in `doc/requirements-doc.txt`. No manual MkDocs
installation is necessary.

## The work-in-progress build list

The **Releases → Work-in-progress builds** navigation entry
(`doc/inofficial.md`) is version-aware. `make_doc.py` reads the `CORE_VERSION`
constant from `CORE/vhdl/config.vhd` and decides accordingly:

- **Alpha/beta cores** — a `WIP-*` version such as `WIP-V1-A11` — show the entry
  in the left-hand navigation.
- **Tagged releases** — `V1`, `V1.1`, `V2`, and so on — hide it. The page is
  still built, still reachable through the link in `README.md` and by direct
  URL, and still indexed for search; only the navigation entry is removed.

If the version cannot be read, the entry is hidden, matching a tagged release.
Each `check`, `build`, and `serve` run reports the detected version and whether
the list is shown.

## How to use it

Run these commands from the repository root:

```bash
# Show and validate the recursively discovered pages and assets.
python3 doc/make_doc.py check

# Build the static site in site/.
python3 doc/make_doc.py build

# Preview a snapshot at http://127.0.0.1:8000/AExp/.
python3 doc/make_doc.py serve
```

Use `--output` to select another build directory:

```bash
python3 doc/make_doc.py build --output /tmp/aexp-site
```

The preview is a snapshot. Restart it after changing a source document so the
temporary source tree is regenerated.

## Publishing

The workflow in `.github/workflows/pages.yml` runs the same build when relevant
documentation changes reach `develop`. It uploads the generated `_site`
directory directly to GitHub Pages and does not create or update a `gh-pages`
branch. Pull requests build the site for validation but do not deploy it.

GitHub Pages must be configured once under **Settings → Pages → Source: GitHub
Actions**. After that, documentation updates are published automatically.
