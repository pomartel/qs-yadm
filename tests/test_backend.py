import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend.py"


class BackendIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "QS_YADM_HOME": str(self.home),
            "QS_YADM_STATE_DIR": str(self.root / "state"),
            "QS_YADM_COMMIT_MESSAGE": "Update test dotfiles",
            "GIT_AUTHOR_NAME": "Test User",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test User",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }
        self.run_yadm("init")
        self.run_yadm("remote", "add", "origin", str(self.remote))
        (self.home / ".config").mkdir(exist_ok=True)
        (self.home / ".config/a.conf").write_text("one\n")
        (self.home / ".config/b.conf").write_text("one\n")
        self.run_yadm("add", ".config/a.conf", ".config/b.conf")
        self.run_yadm("commit", "-m", "Initial")
        self.run_yadm("branch", "-M", "master")
        self.run_yadm("push", "-u", "origin", "master")

    def tearDown(self):
        self.temp.cleanup()

    def run_yadm(self, *args, check=True):
        return subprocess.run(
            ["yadm", *args], cwd=self.home, env=self.env, text=True,
            capture_output=True, check=check,
        )

    def backend(self, *args, check=True):
        proc = subprocess.run(
            [sys.executable, str(BACKEND), *args], cwd=self.home, env=self.env,
            text=True, capture_output=True,
        )
        if check and proc.returncode:
            self.fail(f"backend failed: {proc.stdout}\n{proc.stderr}")
        return json.loads(proc.stdout)

    def test_status_ignores_untracked_and_counts_lines(self):
        (self.home / ".config/a.conf").write_text("one\ntwo\n")
        (self.home / "untracked.txt").write_text("ignore me\n")
        status = self.backend("status")
        self.assertEqual(status["count"], 1)
        self.assertEqual(status["files"][0]["path"], ".config/a.conf")
        self.assertEqual(status["files"][0]["added"], 1)
        self.assertEqual(status["files"][0]["deleted"], 0)

    def test_diff_returns_only_changed_lines(self):
        path = self.home / ".config/a.conf"
        path.write_text("top\nold\nbottom\n")
        self.run_yadm("add", ".config/a.conf")
        self.run_yadm("commit", "-m", "Add diff fixture")
        path.write_text("top\nnew\nbottom\n")

        status = self.backend("status")
        entry_id = next(item["id"] for item in status["files"] if item["path"] == ".config/a.conf")
        result = self.backend("diff", entry_id)
        texts = [line["text"] for line in result["lines"]]

        self.assertEqual(texts, ["-old", "+new"])
        self.assertFalse(any(line["kind"] in {"context", "hunk"} for line in result["lines"]))

    def test_single_file_commit_preserves_unrelated_staging_and_pushes(self):
        (self.home / ".config/a.conf").write_text("changed a\n")
        (self.home / ".config/b.conf").write_text("changed b\n")
        self.run_yadm("add", ".config/b.conf")
        status = self.backend("status")
        a_id = next(item["id"] for item in status["files"] if item["path"] == ".config/a.conf")
        result = self.backend("commit", a_id)
        self.assertTrue(result["ok"])
        self.assertEqual(self.run_yadm("diff", "--cached", "--name-only").stdout.strip(), ".config/b.conf")
        self.assertEqual(self.run_yadm("show", "--pretty=", "--name-only", "HEAD").stdout.strip(), ".config/a.conf")
        remote_head = subprocess.run(
            ["git", f"--git-dir={self.remote}", "rev-parse", "master"],
            text=True, capture_output=True, check=True,
        ).stdout.strip()
        self.assertEqual(remote_head, self.run_yadm("rev-parse", "HEAD").stdout.strip())

    def test_batch_commit_uses_one_commit(self):
        before = self.run_yadm("rev-parse", "HEAD").stdout.strip()
        (self.home / ".config/a.conf").write_text("batch a\n")
        (self.home / ".config/b.conf").write_text("batch b\n")
        status = self.backend("status")
        result = self.backend("commit", *(item["id"] for item in status["files"]))
        self.assertTrue(result["ok"])
        changed = set(self.run_yadm("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.splitlines())
        self.assertEqual(changed, {".config/a.conf", ".config/b.conf"})
        self.assertEqual(self.run_yadm("rev-list", "--count", f"{before}..HEAD").stdout.strip(), "1")

    def test_discard_restores_file_and_writes_recovery_patch(self):
        original = (self.home / ".config/a.conf").read_text()
        (self.home / ".config/a.conf").write_text("discard me\n")
        status = self.backend("status")
        a_id = next(item["id"] for item in status["files"] if item["path"] == ".config/a.conf")
        result = self.backend("discard", a_id)
        self.assertTrue(result["ok"])
        self.assertEqual((self.home / ".config/a.conf").read_text(), original)
        backup = Path(result["backup"])
        self.assertTrue(backup.is_file())
        self.assertIn("discard me", backup.read_text())
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
