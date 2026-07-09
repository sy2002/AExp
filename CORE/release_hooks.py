"""Optional release hooks for AExp.

The generic make_release.py imports this module when present. Keep release
policy in CORE/release.toml whenever possible; use hooks only for checks or
artifacts that cannot be expressed declaratively.
"""

from pathlib import Path


# End-user screen-centering artifacts shipped in every release, relative to the
# repository root. See doc/screen_adjust.md.
#
# The official screen-position config (destined for the SD card's /amiga/
# folder) ships as one OR MORE files: a single aexp_screen.cfg, or several
# per-monitor-geometry variants alongside or instead of it (e.g.
# aexp_screen.cfg_4_3, aexp_screen.cfg_16_9), or any mix. Everything matching
# SCREEN_CONFIG_GLOB is copied into the release; at least one match is
# mandatory. The glob deliberately does NOT match the editor tool
# aexp_screen_cfg.py (that name has "_cfg", not ".cfg").
SCREEN_CONFIG_GLOB = "aexp_screen.cfg*"

# The tool users run to create/edit those config files. Always required.
SCREEN_TOOL = Path("aexp_screen_cfg.py")


def validate(ctx):
    """Run core-specific validation before the output folder is written."""
    return None


def after_package(ctx):
    """Copy the screen-centering artifacts into the release folder.

    Returns the destination paths so make_release.py lists them in the release
    summary. A release without the official screen config or its editor tool is
    incomplete, so a missing source aborts. The config may be a single
    aexp_screen.cfg or one/several per-geometry variants (see
    SCREEN_CONFIG_GLOB); every match is shipped and at least one is mandatory.
    """
    artifacts = []

    configs = sorted(p for p in ctx.repo.glob(SCREEN_CONFIG_GLOB) if p.is_file())
    if not configs:
        ctx.die(
            f"No screen-centering config found: expected at least one file "
            f"matching '{SCREEN_CONFIG_GLOB}' in the repository root"
        )
    for src in configs:
        dst = ctx.out / src.name
        ctx.copy_preserving_timestamps(src, dst)
        artifacts.append(dst)

    tool = ctx.repo / SCREEN_TOOL
    if not tool.is_file():
        ctx.die(f"Required release artifact not found: {SCREEN_TOOL}")
    dst = ctx.out / tool.name
    ctx.copy_preserving_timestamps(tool, dst)
    artifacts.append(dst)

    return artifacts
