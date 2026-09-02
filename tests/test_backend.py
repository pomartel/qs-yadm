import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend.py"
SPEC = importlib.util.spec_from_file_location("qs_yadm_backend", BACKEND)
assert SPEC and SPEC.loader
backend_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend_module)


class AnonymousPullTest(unittest.TestCase):
    def test_converts_ssh_remotes_to_credential_free_https(self):
        self.assertEqual(
            backend_module.anonymous_https_url("git@github.com:owner/dotfiles.git"),
            "https://github.com/owner/dotfiles.git",
        )
        self.assertEqual(
            backend_module.anonymous_https_url("ssh://git@codeberg.org/owner/dotfiles.git"),
            "https://codeberg.org/owner/dotfiles.git",
        )
        self.assertEqual(
            backend_module.anonymous_https_url("https://token@github.com/owner/dotfiles.git"),
            "https://github.com/owner/dotfiles.git",
        )
        self.assertIsNone(backend_module.anonymous_https_url("/srv/git/dotfiles.git"))
        self.assertIsNone(backend_module.anonymous_https_url("ssh://git@example.com:2222/dotfiles.git"))
        self.assertIsNone(backend_module.anonymous_https_url("https://[invalid/dotfiles.git"))

    @mock.patch.object(backend_module, "anonymously_accessible", return_value=True)
    @mock.patch.object(backend_module, "yadm")
    def test_public_remote_is_pulled_anonymously_without_changing_origin(self, yadm, _accessible):
        yadm.side_effect = [
            subprocess.CompletedProcess([], 0, stdout="git@github.com:owner/dotfiles.git\n"),
            subprocess.CompletedProcess([], 0),
        ]

        backend_module.pull_origin("main")

        pull_args = yadm.call_args_list[1].args
        pull_kwargs = yadm.call_args_list[1].kwargs
        self.assertIn("credential.helper=", pull_args)
        self.assertIn(
            "url.https://github.com/owner/dotfiles.git.insteadOf=git@github.com:owner/dotfiles.git",
            pull_args,
        )
        self.assertEqual(pull_args[-5:], ("pull", "--rebase", "--autostash", "origin", "main"))
        self.assertEqual(pull_kwargs["env_updates"]["GIT_ASKPASS"], "/bin/false")

    @mock.patch.object(backend_module, "anonymously_accessible", return_value=False)
    @mock.patch.object(backend_module, "yadm")
    def test_private_remote_falls_back_to_configured_origin(self, yadm, _accessible):
        yadm.side_effect = [
            subprocess.CompletedProcess([], 0, stdout="git@github.com:owner/private.git\n"),
            subprocess.CompletedProcess([], 0),
        ]

        backend_module.pull_origin("main")

        self.assertEqual(
            yadm.call_args_list[1],
            mock.call(
                "pull", "--rebase", "--autostash", "origin", "main",
                check=False, timeout=180,
            ),
        )


class CodexEnvironmentTest(unittest.TestCase):
    def test_preserves_inherited_codex_home(self):
        with mock.patch.dict(os.environ, {"CODEX_HOME": "/custom/codex"}, clear=True):
            self.assertEqual(
                backend_module.codex_environment(),
                {"CODEX_HOME": "/custom/codex"},
            )

    def test_finds_xdg_codex_login_for_graphical_shell(self):
        with tempfile.TemporaryDirectory() as temp:
            candidate = Path(temp) / "codex"
            candidate.mkdir()
            (candidate / "auth.json").touch()
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": temp}, clear=True):
                self.assertEqual(
                    backend_module.codex_environment(),
                    {"CODEX_HOME": str(candidate)},
                )


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

    def test_diff_returns_changed_lines_with_two_lines_of_context(self):
        path = self.home / ".config/a.conf"
        path.write_text("outside top\ntop one\ntop two\nold\nbottom one\nbottom two\noutside bottom\n")
        self.run_yadm("add", ".config/a.conf")
        self.run_yadm("commit", "-m", "Add diff fixture")
        path.write_text("outside top\ntop one\ntop two\nnew\nbottom one\nbottom two\noutside bottom\n")

        status = self.backend("status")
        entry_id = next(item["id"] for item in status["files"] if item["path"] == ".config/a.conf")
        result = self.backend("diff", entry_id)
        texts = [line["text"] for line in result["lines"]]

        self.assertEqual(
            texts,
            [" top one", " top two", "-old", "+new", " bottom one", " bottom two"],
        )
        self.assertFalse(any(line["kind"] == "hunk" for line in result["lines"]))

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
