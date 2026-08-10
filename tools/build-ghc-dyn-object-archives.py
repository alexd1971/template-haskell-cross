"""Build static archives from preserved GHC boot-package dynamic objects.

GHC's shared-library build produces position-independent ``*.dyn_o`` objects.
The default GHC installation does not keep them in a form that downstream
embedders can link statically into another shared library.

This helper groups preserved boot-package ``*.dyn_o`` files by package and
builds matching ``libHS*.a`` archives using the target archiver.
"""

import argparse
import subprocess
from pathlib import Path


BOOT_PACKAGE_PATHS = [
    ("base", "stage1/libraries/base"),
    ("ghc-internal", "stage1/libraries/ghc-internal"),
    ("ghc-bignum", "stage1/libraries/ghc-bignum"),
    ("ghc-prim", "stage1/libraries/ghc-prim"),
    ("rts", "stage1/rts"),
]


def command_output(command: list[str]) -> str:
    """Run a command and return stdout without surrounding whitespace."""
    return subprocess.check_output(command, text=True).strip()


def ghc_pkg_words(ghc_pkg: Path, package_name: str, field: str) -> list[str]:
    """Read a whitespace-separated field from a GHC package database."""
    return command_output(
        [
            str(ghc_pkg),
            "field",
            package_name,
            field,
            "--simple-output",
        ]
    ).split()


def hs_library_name(ghc_pkg: Path, package_name: str) -> str:
    """Read the installed Haskell archive library name for a package."""
    names = ghc_pkg_words(ghc_pkg, package_name, "hs-libraries")
    if not names:
        raise RuntimeError(f"ghc-pkg returned no hs-libraries for {package_name}")
    return names[0]


def dyn_objects_for(dyn_object_root: Path, path_fragment: str) -> list[Path]:
    """Find preserved dynamic objects whose paths belong to one boot package."""
    marker = f"/{path_fragment}/"
    return sorted(
        path
        for path in dyn_object_root.rglob("*.dyn_o")
        if marker in f"/{path.as_posix()}"
    )


def make_archive(
    *,
    ar: Path,
    ranlib: Path,
    ghc_pkg: Path,
    dyn_object_root: Path,
    output_dir: Path,
    package_name: str,
    path_fragment: str,
) -> None:
    """Archive all preserved dynamic objects for one GHC boot package."""
    objects = dyn_objects_for(dyn_object_root, path_fragment)
    if not objects:
        raise RuntimeError(
            f"Could not find dyn objects for {package_name} under {dyn_object_root}"
        )

    archive = output_dir / f"lib{hs_library_name(ghc_pkg, package_name)}.a"
    subprocess.check_call([str(ar), "rcs", str(archive), *map(str, objects)])
    subprocess.check_call([str(ranlib), str(archive)])


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments passed by the Nix builder."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--ar", required=True, type=Path)
    parser.add_argument("--ranlib", required=True, type=Path)
    parser.add_argument("--ghc-pkg", required=True, type=Path)
    parser.add_argument("--dyn-object-root", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    """Build all required GHC boot-package dynamic-object archives."""
    args = parse_args()
    if not args.dyn_object_root.is_dir():
        raise RuntimeError(f"GHC does not provide dyn objects: {args.dyn_object_root}")

    args.out.mkdir(parents=True, exist_ok=True)
    for package_name, path_fragment in BOOT_PACKAGE_PATHS:
        make_archive(
            ar=args.ar,
            ranlib=args.ranlib,
            ghc_pkg=args.ghc_pkg,
            dyn_object_root=args.dyn_object_root,
            output_dir=args.out,
            package_name=package_name,
            path_fragment=path_fragment,
        )


if __name__ == "__main__":
    main()
