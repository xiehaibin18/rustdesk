#!/usr/bin/env python3

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "res" / "rdh-macos-signing-policy.sh"
HASH_A = "a" * 64
HASH_B = "b" * 64


def write_report(
    path: Path,
    *,
    signature: str = "apple-development",
    team_id: str = "7373GRMT82",
    bundle_id: str = "com.herbin.rustdesk",
    designated_requirement_sha256: str = HASH_A,
    entitlements_sha256: str = HASH_B,
) -> None:
    path.write_text(
        "\n".join(
            (
                f"signature={signature}",
                f"team_id={team_id}",
                f"bundle_id={bundle_id}",
                f"designated_requirement_sha256={designated_requirement_sha256}",
                f"entitlements_sha256={entitlements_sha256}",
                "",
            )
        ),
        encoding="utf-8",
    )


class SigningContinuityPolicyTests(unittest.TestCase):
    def run_policy(self, baseline: Path, candidate: Path) -> subprocess.CompletedProcess[str]:
        self.assertTrue(POLICY.is_file(), f"missing signing policy: {POLICY}")
        return subprocess.run(
            ["/bin/bash", str(POLICY), "--check-reports", str(baseline), str(candidate)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_matching_certificate_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.txt"
            candidate = Path(directory) / "candidate.txt"
            write_report(baseline)
            write_report(candidate)

            result = self.run_policy(baseline, candidate)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("signing_continuity=ok team_id=7373GRMT82", result.stdout)

    def test_rejects_ad_hoc_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.txt"
            candidate = Path(directory) / "candidate.txt"
            write_report(baseline)
            write_report(candidate, signature="ad-hoc", team_id="not set")

            result = self.run_policy(baseline, candidate)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("candidate must be certificate-signed", result.stderr)

    def test_rejects_team_id_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.txt"
            candidate = Path(directory) / "candidate.txt"
            write_report(baseline)
            write_report(candidate, team_id="DIFFERENT1")

            result = self.run_policy(baseline, candidate)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Team ID does not match baseline", result.stderr)

    def test_rejects_designated_requirement_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.txt"
            candidate = Path(directory) / "candidate.txt"
            write_report(baseline)
            write_report(candidate, designated_requirement_sha256="c" * 64)

            result = self.run_policy(baseline, candidate)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Designated Requirement does not match baseline", result.stderr)

    def test_rejects_entitlements_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.txt"
            candidate = Path(directory) / "candidate.txt"
            write_report(baseline)
            write_report(candidate, entitlements_sha256="d" * 64)

            result = self.run_policy(baseline, candidate)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("entitlements do not match baseline", result.stderr)


if __name__ == "__main__":
    unittest.main()
