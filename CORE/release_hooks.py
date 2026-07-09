"""Optional release hooks for AExp.

The generic make_release.py imports this module when present. Keep release
policy in CORE/release.toml whenever possible; use hooks only for checks or
artifacts that cannot be expressed declaratively.
"""

from pathlib import Path


# End-user screen-centering artifacts shipped in every release, relative to the
# repository root. aexp_screen.cfg is the official screen-position config that
# ships in the SD card's /amiga/ folder; aexp_screen_cfg.py is the tool users
# run to edit it. See doc/screen_adjust.md.
SCREEN_ARTIFACTS = (
    Path("aexp_screen.cfg"),
    Path("aexp_screen_cfg.py"),
)


def validate(ctx):
    """Run core-specific validation before the output folder is written."""
    return None


def after_package(ctx):
    """Copy the screen-centering artifacts into the release folder.

    Returns the destination paths so make_release.py lists them in the release
    summary. Both files are mandatory: a release without the official screen
    config or its editor tool is incomplete, so a missing source aborts.
    """
    artifacts = []
    for rel in SCREEN_ARTIFACTS:
        src = ctx.repo / rel
        if not src.is_file():
            ctx.die(f"Required release artifact not found: {rel}")
        dst = ctx.out / src.name
        ctx.copy_preserving_timestamps(src, dst)
        artifacts.append(dst)
    return artifacts
