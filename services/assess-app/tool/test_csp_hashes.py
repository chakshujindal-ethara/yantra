"""The policy hashes exactly the inline scripts that shipped: not a script with a src, and not one byte more or less."""

import base64
import hashlib
import subprocess
import sys
from pathlib import Path

import csp_hashes


def _source(body: str) -> str:
    return "'sha256-" + base64.b64encode(hashlib.sha256(body.encode()).digest()).decode() + "'"


def test_each_inline_script_is_hashed_byte_for_byte_and_external_ones_are_not() -> None:
    html = (
        "<script>window.a = 1;</script>\n"
        '<script src="flutter_bootstrap.js" async></script>\n'
        '<SCRIPT type="text/javascript">\n  b();\n</SCRIPT>'
    )
    assert csp_hashes.hashes(html) == [_source("window.a = 1;"), _source("\n  b();\n")]


def test_the_command_fails_on_a_page_with_no_inline_scripts(tmp_path: Path) -> None:
    page = tmp_path / "index.html"
    page.write_text('<script src="x.js"></script>', encoding="utf-8")
    script = Path(__file__).with_name("csp_hashes.py")
    run = subprocess.run([sys.executable, str(script), str(page)], capture_output=True, text=True, check=False)
    assert run.returncode == 1
    assert "no inline scripts" in run.stderr
    page.write_text("<script>x()</script>", encoding="utf-8")
    run = subprocess.run([sys.executable, str(script), str(page)], capture_output=True, text=True, check=True)
    assert run.stdout.strip() == _source("x()")
