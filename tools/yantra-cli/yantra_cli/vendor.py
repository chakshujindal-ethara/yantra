"""`yantra vendor sync|check`: code Yantra runs but does not own (Ethara's Assessment v2 addon, its token gateway, its
exam app) is copied in at a pinned upstream commit, patched by a numbered patch series, and fingerprinted.

A manifest (`VENDOR.toml`, beside the copies) names each source: the upstream repository and commit, the paths taken
from it, the prefix stripped from them, where the copy lands, and the sha256 of the tree after the patches. `sync`
rebuilds a copy from a local checkout of the upstream (`git archive` at the commit, so an unclean working tree never
leaks in), applies `patches/*.patch` in name order with `git apply`, and records the fingerprint. `check` recomputes
every fingerprint and fails on any drift, so CI catches a hand edit that bypassed the patch series."""

import hashlib
import io
import os
import shutil
import subprocess
import tarfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MANIFESTS = (
    Path("services/odoo/vendor/VENDOR.toml"),
    Path("services/assess-app/vendor/VENDOR.toml"),
)


class VendorError(Exception):
    """A sync or check that cannot go on; the message says what to do."""


@dataclass
class Source:
    name: str
    repo: str
    commit: str
    paths: list[str]
    strip: str
    dest: str
    tree_sha256: str


@dataclass
class Manifest:
    path: Path
    patches: str
    sources: list[Source]

    @property
    def base(self) -> Path:
        return self.path.parent

    def patch_files(self) -> list[Path]:
        return sorted((self.base / self.patches).glob("*.patch"))


def load(path: Path) -> Manifest:
    doc = tomllib.loads(path.read_text())
    sources = [
        Source(
            name=s["name"],
            repo=s["repo"],
            commit=s["commit"],
            paths=list(s["paths"]),
            strip=s.get("strip", ""),
            dest=s["dest"],
            tree_sha256=s.get("tree_sha256", ""),
        )
        for s in doc["source"]
    ]
    return Manifest(path=path, patches=doc.get("patches", "patches"), sources=sources)


def _quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def dump(m: Manifest) -> str:
    """The manifest as TOML: a fixed layout, so a sync rewrites only the fingerprints."""
    lines = [
        "# Vendored upstream code: rebuilt by `yantra vendor sync`, verified by `yantra vendor check`.",
        "# Never edit the copies by hand: add a numbered patch under the patches directory instead.",
        f"patches = {_quote(m.patches)}",
    ]
    for s in m.sources:
        lines += [
            "",
            "[[source]]",
            f"name = {_quote(s.name)}",
            f"repo = {_quote(s.repo)}",
            f"commit = {_quote(s.commit)}",
            "paths = [" + ", ".join(_quote(p) for p in s.paths) + "]",
            f"strip = {_quote(s.strip)}",
            f"dest = {_quote(s.dest)}",
            f"tree_sha256 = {_quote(s.tree_sha256)}",
        ]
    return "\n".join(lines) + "\n"


# What building and testing a copy writes into it: never part of the fingerprint.
GENERATED_DIRS = frozenset({".dart_tool", "build", "__pycache__", ".pytest_cache", ".idea"})
GENERATED_FILES = frozenset({".flutter-plugins", ".flutter-plugins-dependencies", ".packages"})


def _generated(rel: Path) -> bool:
    return bool(GENERATED_DIRS.intersection(rel.parts[:-1])) or rel.name in GENERATED_FILES or rel.suffix == ".pyc"


def tree_hash(root: Path) -> str:
    """sha256 over every file's relative path and content, in path order; independent of timestamps and modes.
    Build and test output (`.dart_tool`, `build`, `__pycache__`...) is left out."""
    digest = hashlib.sha256()
    for f in sorted(p for p in root.rglob("*") if p.is_file() and not _generated(p.relative_to(root))):
        digest.update(f.relative_to(root).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(f.read_bytes()).hexdigest().encode() + b"\n")
    return digest.hexdigest()


def _archive(checkout: Path, s: Source) -> bytes:
    try:
        out = subprocess.run(
            ["git", "-C", str(checkout), "archive", "--format=tar", s.commit, *s.paths],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        raise VendorError(f"{s.name}: git archive {s.commit} failed: {e.stderr.decode().strip()}") from e
    return out.stdout


def _extract(data: bytes, s: Source, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    prefix = s.strip.rstrip("/") + "/" if s.strip else ""
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            if not member.name.startswith(prefix):
                raise VendorError(f"{s.name}: {member.name} is outside the strip prefix {s.strip!r}")
            rel = Path(member.name[len(prefix) :])
            if rel.is_absolute() or ".." in rel.parts:
                raise VendorError(f"{s.name}: unsafe path {member.name}")
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            source = tar.extractfile(member)
            assert source is not None  # a regular file always has content
            target.write_bytes(source.read())
            target.chmod(member.mode & 0o777 or 0o644)  # keep executables executable (and patches' modes valid)


def _apply(patch: Path, dest_root: Path) -> None:
    """`git apply` with the enclosing repository hidden: inside a repository it reads a patch's paths from the
    repository root and silently SKIPS the ones outside the working directory, which is every path here."""
    env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(dest_root.resolve().parent)}
    try:
        done = subprocess.run(
            ["git", "apply", "--verbose", "--whitespace=nowarn", str(patch)],
            cwd=dest_root,
            env=env,
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        raise VendorError(f"{patch.name} does not apply: {e.stderr.decode().strip()}") from e
    if "Skipped patch" in done.stderr.decode():
        raise VendorError(f"{patch.name} skipped some paths: {done.stderr.decode().strip()}")


def sync(manifest_path: Path, checkouts: dict[str, Path]) -> Manifest:
    """Rebuild every source of the manifest from the given checkouts (by repo name or source name), apply the
    patch series once over the whole vendor directory, and record the fingerprints."""
    m = load(manifest_path)
    for s in m.sources:
        checkout = checkouts.get(s.name) or checkouts.get(s.repo)
        if checkout is None:
            raise VendorError(f"{s.name}: no checkout given for {s.repo}")
        _extract(_archive(checkout, s), s, m.base / s.dest)
    for patch in m.patch_files():
        _apply(patch, m.base)
    for s in m.sources:
        s.tree_sha256 = tree_hash(m.base / s.dest)
    manifest_path.write_text(dump(m))
    return m


def check(manifest_path: Path) -> list[str]:
    """The sources whose copy no longer matches its recorded fingerprint (empty when all match)."""
    m = load(manifest_path)
    drifted = []
    for s in m.sources:
        dest = m.base / s.dest
        if not dest.is_dir() or tree_hash(dest) != s.tree_sha256:
            drifted.append(s.name)
    return drifted


def check_all(root: Path = ROOT) -> dict[str, list[str]]:
    return {str(p): check(root / p) for p in MANIFESTS if (root / p).exists()}
