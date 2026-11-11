#!/usr/bin/env python3
"""Prepare a patched ReXGlue SDK source tree (and optional MoltenVK xcframework) for iOS builds."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REXGLUE_REPO = "https://github.com/rexglue/rexglue-sdk.git"
REXGLUE_COMMIT = "bd833a2"
DEFAULT_REXGLUE_DIR = REPO_ROOT / "build" / "rexglue-source"
DEFAULT_PATCH = Path(__file__).resolve().parent / "rexglue-ios.patch"
DEFAULT_MOLTENVK_OUT = REPO_ROOT / "build" / "moltenvk" / "MoltenVK.xcframework"


def _run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, cwd=cwd, check=check, text=True)


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return _run(["git", "-C", str(repo), *args], check=check)


def ensure_checkout(rexglue_dir: Path, skip_checkout: bool) -> None:
    if not (rexglue_dir / ".git").exists():
        rexglue_dir.parent.mkdir(parents=True, exist_ok=True)
        _run(["git", "clone", REXGLUE_REPO, str(rexglue_dir)])
    if not skip_checkout:
        head = subprocess.run(
            ["git", "-C", str(rexglue_dir), "rev-parse", "--short=7", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if head != REXGLUE_COMMIT:
            _git(rexglue_dir, "fetch", "origin")
            _git(rexglue_dir, "checkout", REXGLUE_COMMIT)


def init_submodules(rexglue_dir: Path) -> None:
    res = _git(rexglue_dir, "submodule", "update", "--init", "--recursive", "--depth", "1", check=False)
    if res.returncode != 0:
        _git(rexglue_dir, "submodule", "update", "--init", "--recursive")


def export_patch(rexglue_dir: Path, patch_path: Path) -> None:
    """Write 'git diff --binary' as raw bytes so LF endings are preserved on all OSes."""
    result = subprocess.run(
        ["git", "-C", str(rexglue_dir), "diff", "--binary"],
        capture_output=True,
        check=True,
    )
    patch_path.write_bytes(result.stdout)
    print(f"Exported iOS patch ({len(result.stdout):,} bytes) -> {patch_path}")


def apply_patch(rexglue_dir: Path, patch_path: Path, verify_only: bool) -> None:
    if not patch_path.is_file():
        raise FileNotFoundError(f"Patch file not found: {patch_path}")

    already = _git(rexglue_dir, "apply", "--check", "--reverse", str(patch_path), check=False)
    if already.returncode == 0:
        print(f"Patch already applied cleanly: {patch_path}")
        return

    can_apply = _git(rexglue_dir, "apply", "--check", str(patch_path), check=False)
    if can_apply.returncode != 0:
        raise RuntimeError(f"Patch does not apply cleanly to {rexglue_dir}: {patch_path}")

    if verify_only:
        print(f"Patch verified cleanly (not applied): {patch_path}")
        return

    _git(rexglue_dir, "apply", str(patch_path))
    print(f"Applied iOS patch: {patch_path}")


def build_moltenvk(rexglue_dir: Path, target: str, out_dir: Path, force: bool = False) -> None:
    if target == "none":
        return
    if sys.platform != "darwin":
        raise RuntimeError("Building MoltenVK for iOS requires macOS with Xcode installed.")

    required_slices = []
    if target in ("ios", "both"):
        required_slices.append("ios-arm64")
    if target in ("iossim", "both"):
        required_slices.append("ios-arm64_x86_64-simulator")

    if not force and all((out_dir / slice_name / "MoltenVK.framework").is_dir() for slice_name in required_slices):
        print(f"Using cached MoltenVK.xcframework at {out_dir}")
        return

    moltenvk_dir = rexglue_dir / "thirdparty" / "moltenvk"
    if not (moltenvk_dir / "MoltenVKPackaging.xcodeproj").exists():
        _git(rexglue_dir, "submodule", "update", "--init", "--recursive", "thirdparty/moltenvk")

    fetch_flags: list[str] = []
    make_targets: list[str] = []
    if target in ("ios", "both"):
        fetch_flags.append("--ios")
        make_targets.append("ios")
    if target in ("iossim", "both"):
        fetch_flags.append("--iossim")
        make_targets.append("iossim")

    _run(["./fetchDependencies", *fetch_flags], cwd=moltenvk_dir)
    _run(["make", *make_targets], cwd=moltenvk_dir)

    candidates = [
        moltenvk_dir / "Package" / "Latest" / "MoltenVK" / "dynamic" / "MoltenVK.xcframework",
        moltenvk_dir / "Package" / "Release" / "MoltenVK" / "dynamic" / "MoltenVK.xcframework",
    ]
    built = next((c for c in candidates if c.is_dir()), None)
    if built is None:
        raise FileNotFoundError(
            "MoltenVK build finished, but dynamic MoltenVK.xcframework was not found under Package/"
        )

    out_dir.parent.mkdir(parents=True, exist_ok=True)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    shutil.copytree(built, out_dir, symlinks=True)
    print(f"Staged MoltenVK.xcframework -> {out_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--rexglue-dir",
        type=Path,
        default=DEFAULT_REXGLUE_DIR,
        help=f"Destination rexglue-sdk checkout directory (default: {DEFAULT_REXGLUE_DIR})",
    )
    parser.add_argument(
        "--patch",
        type=Path,
        default=DEFAULT_PATCH,
        help=f"iOS patch path (default: {DEFAULT_PATCH})",
    )
    parser.add_argument(
        "--skip-checkout",
        action="store_true",
        help="Do not clone or switch commits in --rexglue-dir",
    )
    parser.add_argument(
        "--skip-submodules",
        action="store_true",
        help="Do not initialize git submodules inside --rexglue-dir",
    )
    parser.add_argument(
        "--export-patch",
        action="store_true",
        help="Re-export the iOS patch from --rexglue-dir's current working-tree diff (raw bytes, LF-safe)",
    )
    parser.add_argument(
        "--verify-patch",
        action="store_true",
        help="Check whether the iOS patch applies (or is already applied) without modifying files",
    )
    parser.add_argument(
        "--build-moltenvk",
        choices=("none", "ios", "iossim", "both"),
        default="none",
        help="Build dynamic MoltenVK.xcframework from thirdparty/moltenvk on macOS",
    )
    parser.add_argument(
        "--moltenvk-out",
        type=Path,
        default=DEFAULT_MOLTENVK_OUT,
        help=f"Output MoltenVK.xcframework path (default: {DEFAULT_MOLTENVK_OUT})",
    )
    parser.add_argument(
        "--force-moltenvk",
        action="store_true",
        help="Rebuild MoltenVK.xcframework even if the requested slices are already staged",
    )
    args = parser.parse_args()

    rexglue_dir = args.rexglue_dir.resolve()
    patch_path = args.patch.resolve()

    if not args.skip_checkout:
        ensure_checkout(rexglue_dir, skip_checkout=False)
    elif not (rexglue_dir / ".git").exists():
        raise FileNotFoundError(f"ReXGlue git repository not found: {rexglue_dir}")

    if not args.skip_submodules and not args.verify_patch:
        init_submodules(rexglue_dir)

    if args.export_patch:
        export_patch(rexglue_dir, patch_path)
        return 0

    apply_patch(rexglue_dir, patch_path, verify_only=args.verify_patch)

    if args.build_moltenvk != "none" and not args.verify_patch:
        build_moltenvk(rexglue_dir, args.build_moltenvk, args.moltenvk_out.resolve(), force=args.force_moltenvk)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
