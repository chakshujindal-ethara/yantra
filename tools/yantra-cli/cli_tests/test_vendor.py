"""`yantra vendor`: a copy rebuilt from a pinned commit (never the working tree), patched by a numbered series,
fingerprinted, and checked for drift."""

import subprocess
from pathlib import Path

import pytest

from yantra_cli import vendor
from yantra_cli.__main__ import main
from yantra_cli.vendor import Manifest, Source, VendorError, check, dump, load, sync, tree_hash


def git(cwd: Path, *args: str) -> str:
    out = subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)
    return out.stdout.strip()


@pytest.fixture
def upstream(tmp_path: Path) -> tuple[Path, str]:
    """A tiny upstream repository with an addon under custom_addons/, committed, then dirtied."""
    repo = tmp_path / "upstream"
    (repo / "custom_addons" / "addon" / "sub").mkdir(parents=True)
    (repo / "custom_addons" / "addon" / "__manifest__.py").write_text("{'depends': ['base', 'extra']}\n")
    (repo / "custom_addons" / "addon" / "sub" / "x.py").write_text("X = 1\n")
    (repo / "custom_addons" / "other").mkdir()
    (repo / "custom_addons" / "other" / "y.py").write_text("Y = 1\n")
    git(repo, "init", "-q")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
    commit = git(repo, "rev-parse", "HEAD")
    (repo / "custom_addons" / "addon" / "sub" / "x.py").write_text("X = 'uncommitted'\n")  # must never leak
    return repo, commit


def write_manifest(base: Path, commit: str, patch: str | None = None) -> Path:
    base.mkdir(parents=True, exist_ok=True)
    m = Manifest(
        path=base / "VENDOR.toml",
        patches="patches",
        sources=[
            Source(
                name="addon",
                repo="git@example:up.git",
                commit=commit,
                paths=["custom_addons/addon"],
                strip="custom_addons",
                dest="addons",
                tree_sha256="",
            )
        ],
    )
    m.path.write_text(dump(m))
    if patch is not None:
        (base / "patches").mkdir()
        (base / "patches" / "0001-drop-extra.patch").write_text(patch)
    return m.path


DROP_EXTRA = """--- a/addons/addon/__manifest__.py
+++ b/addons/addon/__manifest__.py
@@ -1 +1 @@
-{'depends': ['base', 'extra']}
+{'depends': ['base']}
"""


def test_sync_takes_the_commit_not_the_working_tree_applies_patches_and_records_the_fingerprint(tmp_path, upstream):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "vendor", commit, DROP_EXTRA)
    m = sync(manifest, {"addon": repo})
    dest = tmp_path / "vendor" / "addons"
    assert (dest / "addon" / "sub" / "x.py").read_text() == "X = 1\n"
    assert (dest / "addon" / "__manifest__.py").read_text() == "{'depends': ['base']}\n"
    assert not (dest / "other").exists()
    assert m.sources[0].tree_sha256 == tree_hash(dest)
    assert load(manifest).sources[0].tree_sha256 == tree_hash(dest)
    assert check(manifest) == []


def test_a_hand_edit_or_a_missing_copy_is_drift(tmp_path, upstream):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "vendor", commit)
    sync(manifest, {"git@example:up.git": repo})  # the checkout may be named by repo too
    (tmp_path / "vendor" / "addons" / "addon" / "sub" / "x.py").write_text("X = 2\n")
    assert check(manifest) == ["addon"]
    import shutil

    shutil.rmtree(tmp_path / "vendor" / "addons")
    assert check(manifest) == ["addon"]


def test_sync_refuses_a_missing_checkout_a_bad_commit_and_a_patch_that_does_not_apply(tmp_path, upstream):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "a", commit)
    with pytest.raises(VendorError, match="no checkout"):
        sync(manifest, {})
    bad = write_manifest(tmp_path / "b", "0" * 40)
    with pytest.raises(VendorError, match="git archive"):
        sync(bad, {"addon": repo})
    broken = write_manifest(tmp_path / "c", commit, DROP_EXTRA.replace("'extra'", "'nope'"))
    with pytest.raises(VendorError, match="does not apply"):
        sync(broken, {"addon": repo})


def test_paths_outside_the_strip_prefix_are_refused(tmp_path, upstream):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "v", commit)
    text = manifest.read_text().replace('strip = "custom_addons"', 'strip = "elsewhere"')
    manifest.write_text(text)
    with pytest.raises(VendorError, match="outside the strip prefix"):
        sync(manifest, {"addon": repo})


def test_unsafe_archive_paths_are_refused(tmp_path, monkeypatch):
    import io
    import tarfile

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        info = tarfile.TarInfo("custom_addons/../../evil.py")
        info.size = 1
        tar.addfile(info, io.BytesIO(b"x"))
    src = Source("addon", "r", "c", ["custom_addons"], "custom_addons", "addons", "")
    with pytest.raises(VendorError, match="unsafe path"):
        vendor._extract(buf.getvalue(), src, tmp_path / "out")


def test_no_strip_keeps_the_paths_and_a_rerun_replaces_the_copy(tmp_path, upstream):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "v", commit)
    manifest.write_text(manifest.read_text().replace('strip = "custom_addons"', 'strip = ""'))
    sync(manifest, {"addon": repo})
    assert (tmp_path / "v" / "addons" / "custom_addons" / "addon" / "sub" / "x.py").exists()
    sync(manifest, {"addon": repo})
    assert check(manifest) == []


def test_the_cli_checks_every_manifest_and_syncs_one(tmp_path, upstream, monkeypatch, capsys):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "services" / "x" / "vendor", commit)
    monkeypatch.setattr(vendor, "MANIFESTS", (Path("services/x/vendor/VENDOR.toml"), Path("missing/VENDOR.toml")))
    monkeypatch.setattr("yantra_cli.__main__.check_all", lambda: vendor.check_all(tmp_path))
    monkeypatch.setattr("yantra_cli.__main__.VENDOR_ROOT", tmp_path)
    assert main(["vendor", "check"]) == 1 and "vendor drifted" in capsys.readouterr().err
    assert main(["vendor", "sync"]) == 2
    rel = manifest.relative_to(tmp_path).as_posix()
    assert main(["vendor", "sync", rel, "--from", f"addon={repo}"]) == 0
    assert "addon:" in capsys.readouterr().out
    assert main(["vendor", "check"]) == 0 and "vendor current" in capsys.readouterr().out
    assert main(["vendor", "sync", rel]) == 1 and "no checkout" in capsys.readouterr().err


def test_the_repository_copies_match_their_fingerprints():
    """The real vendored trees (services/odoo/vendor, services/assess-app/vendor) never drift from their patches."""
    assert all(not names for names in vendor.check_all().values()), vendor.check_all()


def test_build_and_test_output_is_not_drift(tmp_path, upstream):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "v", commit)
    sync(manifest, {"addon": repo})
    addon = tmp_path / "v" / "addons" / "addon"
    for generated in ("__pycache__/x.cpython-312.pyc", "sub/y.pyc", ".dart_tool/package_config.json", "build/web/a.js"):
        (addon / generated).parent.mkdir(parents=True, exist_ok=True)
        (addon / generated).write_text("generated")
    (addon / ".flutter-plugins").write_text("generated")
    assert check(manifest) == []


def test_patches_apply_when_the_vendor_directory_sits_inside_another_repository(tmp_path, upstream):
    """The real copies live inside Yantra's repository, where a bare `git apply` silently skips every path."""
    repo, commit = upstream
    host = tmp_path / "host"
    host.mkdir()
    git(host, "init", "-q")
    manifest = write_manifest(host / "services" / "x" / "vendor", commit, DROP_EXTRA)
    sync(manifest, {"addon": repo})
    assert (host / "services" / "x" / "vendor" / "addons" / "addon" / "__manifest__.py").read_text() == (
        "{'depends': ['base']}\n"
    )


def test_a_patch_that_would_be_skipped_is_an_error(tmp_path, upstream, monkeypatch):
    repo, commit = upstream
    manifest = write_manifest(tmp_path / "v", commit, DROP_EXTRA)

    class Done:
        stderr = b"Skipped patch 'addons/addon/__manifest__.py'."

    monkeypatch.setattr(vendor.subprocess, "run", lambda *a, **k: Done())
    with pytest.raises(VendorError, match="skipped"):
        vendor._apply(manifest.parent / "patches" / "0001-drop-extra.patch", manifest.parent)


def test_executable_bits_survive_extraction(tmp_path, upstream):
    repo, commit = upstream
    script = repo / "custom_addons" / "addon" / "run.sh"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "exe")
    manifest = write_manifest(tmp_path / "v", git(repo, "rev-parse", "HEAD"))
    sync(manifest, {"addon": repo})
    assert (tmp_path / "v" / "addons" / "addon" / "run.sh").stat().st_mode & 0o111
