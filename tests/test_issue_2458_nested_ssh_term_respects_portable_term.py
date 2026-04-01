#!/usr/bin/env python3
"""
Regression: cmux's bundled Ghostty zsh integration must preserve a user-selected
portable TERM across SSH hops.

When the active local TERM is xterm-256color, the SSH wrapper should keep that
TERM for remote sessions and skip the xterm-ghostty terminfo bootstrap. This
avoids deeper nested hops inheriting xterm-ghostty on hosts that do not also
run Ghostty shell integration.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def _run_case(
    *,
    root: Path,
    wrapper_dir: Path,
    features: str,
    term: str,
    expect_term: str,
    expect_infocmp: bool,
) -> tuple[bool, str]:
    base = Path(tempfile.mkdtemp(prefix="cmux_issue_2458_"))
    try:
        home = base / "home"
        orig = base / "orig-zdotdir"
        fakebin = base / "fakebin"
        term_out = base / "term.txt"
        infocmp_out = base / "infocmp.txt"

        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)
        fakebin.mkdir(parents=True, exist_ok=True)

        for filename in (".zshenv", ".zprofile", ".zshrc"):
            (orig / filename).write_text("", encoding="utf-8")

        _write_executable(
            fakebin / "ssh",
            """#!/bin/sh
if [ "$1" = "-G" ]; then
  printf 'user nested\\n'
  printf 'hostname nested.example\\n'
  exit 0
fi
printf '%s\\n' "${TERM:-}" > "$CMUX_TEST_TERM_OUT"
printf '%s\\n' "$*" > "$CMUX_TEST_SSH_ARGS_OUT"
exit 0
""",
        )
        _write_executable(
            fakebin / "infocmp",
            """#!/bin/sh
printf 'called\\n' >> "$CMUX_TEST_INFOCMP_OUT"
exit "${CMUX_TEST_INFOCMP_STATUS:-1}"
""",
        )

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["TERM"] = term
        env["PATH"] = f"{fakebin}:{env.get('PATH', '')}"
        env["ZDOTDIR"] = str(wrapper_dir)
        env["GHOSTTY_ZSH_ZDOTDIR"] = str(orig)
        env["GHOSTTY_RESOURCES_DIR"] = str(root / "ghostty" / "src")
        env["CMUX_SHELL_INTEGRATION_DIR"] = str(wrapper_dir)
        env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        env["CMUX_SHELL_INTEGRATION"] = "0"
        env["GHOSTTY_SHELL_FEATURES"] = features
        env["CMUX_TEST_TERM_OUT"] = str(term_out)
        env["CMUX_TEST_SSH_ARGS_OUT"] = str(base / "ssh-args.txt")
        env["CMUX_TEST_INFOCMP_OUT"] = str(infocmp_out)
        env["CMUX_TEST_INFOCMP_STATUS"] = "1"
        env.pop("GHOSTTY_BIN_DIR", None)
        env.pop("TERMINFO", None)

        result = subprocess.run(
            ["zsh", "-d", "-i", "-c", "ssh nested.example"],
            env=env,
            capture_output=True,
            text=True,
            timeout=8,
        )
        if result.returncode != 0:
            combined = ((result.stdout or "") + (result.stderr or "")).strip()
            return False, f"zsh exited non-zero rc={result.returncode}: {combined}"

        if not term_out.exists():
            return False, "fake ssh did not record TERM"

        recorded_term = term_out.read_text(encoding="utf-8").strip()
        if recorded_term != expect_term:
            return False, f"expected remote TERM={expect_term!r}, got {recorded_term!r}"

        infocmp_called = infocmp_out.exists()
        if infocmp_called != expect_infocmp:
            return False, f"expected infocmp_called={expect_infocmp}, got {infocmp_called}"

        return True, ""
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0

    if shutil.which("zsh") is None:
        print("SKIP: zsh not installed")
        return 0

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        features="ssh-env,ssh-terminfo",
        term="xterm-256color",
        expect_term="xterm-256color",
        expect_infocmp=False,
    )
    if not ok:
        print(f"FAIL: portable TERM case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        features="ssh-env",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=False,
    )
    if not ok:
        print(f"FAIL: ssh-env-only fallback case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        features="ssh-env,ssh-terminfo",
        term="tmux-256color",
        expect_term="xterm-256color",
        expect_infocmp=False,
    )
    if not ok:
        print(f"FAIL: tmux/custom TERM normalization case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=True,
    )
    if not ok:
        print(f"FAIL: xterm-ghostty fallback case failed: {detail}")
        return 1

    print("PASS: Ghostty zsh SSH wrapper preserves portable TERM and still falls back from xterm-ghostty")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
