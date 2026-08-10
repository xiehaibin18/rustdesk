#!/usr/bin/env python3
import argparse
import os
import subprocess
from pathlib import Path


USAGE = (
    "Usage: RustDesk-Herbin --terminal --headless "
    "[--relay] [--persistent] <peer-id>"
)
FILE_TRANSFER_USAGE = (
    "Usage: RustDesk-Herbin --file-transfer --headless "
    "[--relay] [--overwrite] <peer-id> <push|pull> "
    "<source-file> <destination-file>"
)
CAPABILITIES = "headless-terminal\nheadless-file-transfer\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify that the macOS app routes RDH CLI before AppKit."
    )
    parser.add_argument("app", type=Path, help="RustDesk-Herbin.app to test")
    return parser.parse_args()


def run_cli(executable: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [str(executable), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise AssertionError(
            f"CLI command did not exit before AppKit: {arguments!r}"
        ) from error


def decode(output: bytes) -> str:
    return output.decode("utf-8", errors="replace")


def main() -> None:
    args = parse_args()
    executable = args.app / "Contents" / "MacOS" / "RustDesk-Herbin"
    if not executable.is_file():
        raise SystemExit(f"missing RDH executable: {executable}")

    upstream_version = os.environ.get("UPSTREAM_VERSION")
    assert upstream_version, "UPSTREAM_VERSION must identify the candidate under test"
    revision = os.environ.get("RDH_REVISION")
    assert revision, "RDH_REVISION must identify the candidate under test"

    completed = run_cli(executable, "--help")
    stdout = decode(completed.stdout)
    stderr = decode(completed.stderr)
    assert completed.returncode == 0, (
        f"--help must exit successfully before AppKit; got {completed.returncode}"
    )
    assert stderr == "", f"--help must keep stderr empty: {stderr!r}"
    for marker in (
        "RustDesk-Herbin CLI",
        "--help [terminal|file-transfer]",
        "--version",
        "--capabilities",
        "--terminal --headless",
        "--file-transfer --headless",
    ):
        assert marker in stdout, f"missing --help marker {marker!r}: {stdout!r}"

    completed = run_cli(executable, "--help", "terminal")
    assert completed.returncode == 0
    assert completed.stderr == b""
    assert USAGE in decode(completed.stdout)

    completed = run_cli(executable, "--help", "file-transfer")
    assert completed.returncode == 0
    assert completed.stderr == b""
    assert FILE_TRANSFER_USAGE in decode(completed.stdout)

    completed = run_cli(executable, "--version")
    assert completed.returncode == 0
    assert completed.stderr == b""
    assert decode(completed.stdout) == (
        f"RustDesk-Herbin {upstream_version}-rdh.{revision}\n"
    )

    completed = run_cli(executable, "--capabilities")
    assert completed.returncode == 0
    assert completed.stderr == b""
    assert decode(completed.stdout) == CAPABILITIES

    completed = run_cli(executable, "--headless")
    stderr = decode(completed.stderr)
    assert completed.returncode == 2, (
        "unsupported headless command must fail closed before AppKit; "
        f"got status {completed.returncode}, stderr={stderr!r}"
    )
    assert completed.stdout == b""
    assert "unsupported headless command" in stderr

    completed = run_cli(executable, "--file-transfer", "--headless")
    stderr = decode(completed.stderr)
    assert completed.returncode == 2, (
        "headless file-transfer usage error must exit before AppKit; "
        f"got status {completed.returncode}, stderr={stderr!r}"
    )
    assert completed.stdout == b""
    assert FILE_TRANSFER_USAGE in stderr

    completed = run_cli(executable, "--terminal", "--headless")
    stderr = decode(completed.stderr)

    assert completed.returncode == 2, (
        "headless usage error must exit through the Rust CLI before AppKit; "
        f"got status {completed.returncode}, stderr={stderr!r}"
    )
    assert USAGE in stderr, f"missing headless usage text in stderr: {stderr!r}"


if __name__ == "__main__":
    main()
