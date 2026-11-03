"""The deploy check's logic, against throwaway Git repos, a fake Cloudflare and a fake live site. Nothing real is
touched. Run: python3 -m unittest discover -s scripts/tests"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy_site as ds  # noqa: E402

GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Test",
           "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com"}
saved_env = {}


def setUpModule():
    for key, value in GIT_ENV.items():
        saved_env[key] = os.environ.get(key)
        os.environ[key] = value


def tearDownModule():
    for key, value in saved_env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


SITE = {
    "site/index.html": '<!doctype html><title>Burn</title><a href="demo/">Demo</a><img src="assets/og.png">'
                       '<script type="module" src="signature/signature.js"></script>',
    "site/demo/index.html": '<!doctype html><link rel="stylesheet" href="demo.css"><img src="poster.png">',
    "site/demo/demo.css": "body{background:url(poster.png)}",
    "site/demo/poster.png": "poster",
    "site/assets/og.png": "og",
    "site/signature/signature.js": "export {}",
    "wrangler.jsonc": '{"name": "burn-site", "account_id": "acct123", "assets": {"directory": "./site"}}',
    "README.md": "# Burn",
}


def sh(cwd, *args):
    return subprocess.run(args, cwd=str(cwd), check=True, capture_output=True, text=True).stdout.strip()


class Repo:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.mkdir(parents=True, exist_ok=True)
        sh(self.path, "git", "init", "-q", "-b", "main")
        self.git = ds.Git(self.path)

    def write(self, rel: str, text: str) -> None:
        file = self.path / rel
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self, message: str, files=None, delete=()) -> str:
        for rel, text in (files or {}).items():
            self.write(rel, text)
        for rel in delete:
            (self.path / rel).unlink()
        sh(self.path, "git", "add", "-A")
        sh(self.path, "git", "commit", "-q", "-m", message)
        return sh(self.path, "git", "rev-parse", "HEAD")

    def switch(self, *args: str) -> None:
        sh(self.path, "git", "switch", "-q", *args)

    def site_files(self, commit: str) -> dict:
        names = sh(self.path, "git", "ls-tree", "-r", "--name-only", commit, "site").splitlines()
        return {name[len("site/"):]: subprocess.run(["git", "show", f"{commit}:{name}"], cwd=str(self.path),
                                                   capture_output=True, check=True).stdout for name in names}


class Host:
    """A fake live site: serves a dict of files the way the Worker (404) or Pages (home page) does."""

    def __init__(self, files: dict, missing_is_404: bool):
        self.files = dict(files)
        self.missing_is_404 = missing_is_404

    def get(self, path: str):
        path = urllib.parse.unquote(path.lstrip("/"))
        if path == "" or path.endswith("/"):
            path += "index.html"
        if path in self.files:
            return 200, self.files[path]
        if (self.files.get(path + "/index.html")) is not None:
            return 200, self.files[path + "/index.html"]
        return (404, b"not found") if self.missing_is_404 else (200, self.files.get("index.html", b""))


class Web:
    def __init__(self, **hosts):
        self.hosts = {host.replace("_", "."): value for host, value in hosts.items()}

    def __call__(self, url: str):
        parts = urllib.parse.urlsplit(url)
        host = self.hosts.get(parts.netloc)
        return host.get(parts.path) if host else (404, b"")


class FakeCloud:
    def __init__(self, web: Web, versions=("v-old",), notes=(), pages=()):
        self.web, self.versions, self.notes, self.pages, self.deployed = web, list(versions), list(notes), list(pages), []

    def worker_now(self):
        return list(self.versions), list(self.notes)

    def pages_now(self, branch):
        return [row for row in self.pages if row["Branch"] == branch]

    @staticmethod
    def _read(site: Path) -> dict:
        return {str(p.relative_to(site)): p.read_bytes() for p in site.rglob("*") if p.is_file()}

    def deploy_worker(self, export, note):
        self.deployed.append(("worker", note))
        self.web.hosts[ds.WORKER_SITE.host].files = self._read(export / "site")
        return "ok"

    def deploy_pages(self, export, branch, commit, message):
        self.deployed.append(("pages", branch, commit))
        host = ds.PAGES_SITE.host if branch == ds.MAIN else ds.STAGING_SITE.host
        self.web.hosts.setdefault(host, Host({}, False)).files = self._read(export / "site")
        return "ok"


def passing():
    return True, ["Ran 1 test in 0.001s", "", "OK"]


class DeployCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = Repo(self.root / "repo")
        self.a = self.repo.commit("First site", SITE)
        self.b = self.repo.commit("Add pricing", {"site/index.html": SITE["site/index.html"] + "<p>Pricing</p>"})

    def tearDown(self):
        self.tmp.cleanup()

    def serving(self, commit, pages_commit=None):
        return Web(**{ds.WORKER_SITE.host: Host(self.repo.site_files(commit), True),
                      ds.PAGES_SITE.host: Host(self.repo.site_files(pages_commit or commit), False)})

    def run_tool(self, *argv, web=None, cloud=None, tests=passing, tty=False):
        web = web or self.serving(self.b)
        cloud = cloud or FakeCloud(web, pages=[{"Branch": "main", "Source": self.b[:7], "Id": "p-old"}])
        lines = []
        report = ds.Report(out=lines.append)
        code = ds.run(ds.parse(list(argv)), self.repo.git, cloud, web, report, tty, tests,
                      sleep=lambda s: None, wait_seconds=0)
        return code, "\n".join(lines), report, cloud

    # ── what's live ──

    def test_the_deploy_note_names_the_live_commit(self):
        web = self.serving(self.b)
        report = ds.Report(out=lambda s: None)
        live = ds.find_live(self.repo.git, FakeCloud(web, notes=[self.b]), web, ds.WORKER_SITE, None, report)
        self.assertEqual(live.commits, [self.b])
        self.assertEqual(live.how, "its deploy note")
        self.assertEqual(live.rollback_to, "v-old")

    def test_without_a_note_the_live_files_name_the_commit(self):
        web = self.serving(self.a)
        live = ds.find_live(self.repo.git, FakeCloud(web), web, ds.WORKER_SITE, None, ds.Report(out=lambda s: None))
        self.assertEqual(live.commits, [self.a])
        self.assertIn("matching the live files", live.how)

    def test_a_deleted_file_tells_two_commits_apart(self):
        c = self.repo.commit("Add extra", {"site/extra.txt": "extra"})
        d = self.repo.commit("Remove extra", delete=["site/extra.txt"])
        for commit, missing_is_404 in ((c, True), (d, True), (d, False)):
            host = ds.WORKER_SITE if missing_is_404 else ds.PAGES_SITE
            web = Web(**{host.host: Host(self.repo.site_files(commit), missing_is_404)})
            matched = ds.match_live_files(self.repo.git, web, host)
            # D's site/ is B's again, so either names it.
            self.assertEqual(matched, [c] if commit == c else [d, self.b])

    def test_a_note_for_a_commit_this_copy_lacks_says_push_and_fetch(self):
        web = self.serving(self.b)
        report = ds.Report(out=lambda s: None)
        live = ds.find_live(self.repo.git, FakeCloud(web, notes=["f" * 40]), web, ds.WORKER_SITE, None, report)
        self.assertIsNone(live)
        self.assertIn("which this copy doesn't have", report.stops[0])

    def test_files_matching_no_commit_stop_and_explain_naming_it_by_hand(self):
        web = Web(**{ds.WORKER_SITE.host: Host({"index.html": b"edited by hand, never committed"}, True)})
        report = ds.Report(out=lambda s: None)
        self.assertIsNone(ds.find_live(self.repo.git, FakeCloud(web), web, ds.WORKER_SITE, None, report))
        self.assertIn("Can't tell which commit", report.stops[0])
        live = ds.find_live(self.repo.git, FakeCloud(web), web, ds.WORKER_SITE, self.b, ds.Report(out=lambda s: None))
        self.assertEqual((live.commits, live.how), ([self.b], "named by hand with --live-commit"))

    def test_a_note_that_no_longer_matches_the_files_falls_back_to_the_files(self):
        web = self.serving(self.a)  # rolled back to A, but the note still names B
        live = ds.find_live(self.repo.git, FakeCloud(web, notes=[self.b]), web, ds.WORKER_SITE, None,
                            ds.Report(out=lambda s: None))
        self.assertEqual(live.commits, [self.a])

    # ── this branch ──

    def test_uncommitted_site_changes_stop_but_other_files_dont(self):
        self.repo.write("README.md", "changed")
        code, out, report, _ = self.run_tool("--check")
        self.assertFalse(any("not committed" in s for s in report.stops), out)
        self.repo.write("site/index.html", "changed")
        self.repo.write("site/new.png", "new")
        code, out, report, _ = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertTrue(any("not committed" in s for s in report.stops))
        self.assertIn("site/new.png", out)

    def test_a_branch_missing_live_work_stops_and_lists_what_would_be_lost(self):
        self.repo.switch("-c", "side", self.a)
        self.repo.commit("Side change", {"site/side.txt": "side"})
        code, out, report, _ = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertIn("This branch is missing work that's live on burn.tommymassaro.com", report.stops)
        self.assertIn("This branch is missing work that's live on burn-1hx.pages.dev", report.stops)
        self.assertIn("Add pricing", out)
        self.assertIn("git merge main", out)

    def test_a_branch_with_live_work_passes_and_asks_its_questions(self):
        self.repo.switch("-c", "side", self.b)
        c = self.repo.commit("Side change", {"site/index.html": SITE["site/index.html"] + "<p>Side</p>"})
        code, out, report, _ = self.run_tool("--check")
        self.assertEqual(code, 0, out)
        questions = " ".join(q for q, _ in report.confirms)
        self.assertIn("You're deploying from side, not main", questions)
        self.assertIn("isn't on GitHub", questions)
        self.assertIn("Side change", out)  # what the deploy adds
        self.assertIn("site/index.html", out)
        self.assertIn(f"npx wrangler rollback v-old --name {ds.WORKER}", out)
        self.assertTrue(c)

    def test_unpushed_commits_and_newer_github_commits_are_questions(self):
        remote = self.root / "remote.git"
        sh(self.root, "git", "init", "-q", "--bare", str(remote))
        sh(self.repo.path, "git", "remote", "add", "origin", str(remote))
        sh(self.repo.path, "git", "push", "-q", "-u", "origin", "main")
        self.repo.commit("Not pushed", {"site/index.html": SITE["site/index.html"] + "<p>Local</p>"})
        _, _, report, _ = self.run_tool("--check")
        self.assertIn("1 commit(s) here aren't pushed to origin/main. Deploy anyway?", [q for q, _ in report.confirms])
        other = Repo(self.root / "other")
        sh(other.path, "git", "pull", "-q", str(remote), "main")
        other.commit("Someone else's", {"README.md": "theirs"})
        sh(other.path, "git", "push", "-q", str(remote), "HEAD:main")
        _, _, report, _ = self.run_tool("--check")
        self.assertIn("origin/main has 1 commit(s) this branch doesn't. Deploy without them?",
                      [q for q, _ in report.confirms])

    # ── deploying ──

    def test_yes_never_gets_past_a_stop(self):
        self.repo.switch("-c", "side", self.a)
        self.repo.commit("Side change", {"site/side.txt": "side"})
        ran = []
        code, out, report, cloud = self.run_tool("--yes", tests=lambda: ran.append(1) or passing())
        self.assertEqual(code, 1)
        self.assertEqual(cloud.deployed, [])
        self.assertEqual(ran, [], "it stops before running the tests")
        self.assertIn("Nothing was deployed", out)

    def test_without_a_terminal_or_yes_it_stops_before_deploying(self):
        c = self.repo.commit("Next", {"site/index.html": SITE["site/index.html"] + "<p>Next</p>"})
        web = self.serving(self.b)
        cloud = FakeCloud(web)
        with self.assertRaises(ds.Stop) as raised:
            self.run_tool(web=web, cloud=cloud)
        self.assertIn("no terminal", raised.exception.title)
        self.assertEqual(cloud.deployed, [])
        self.assertTrue(c)

    def test_failing_tests_stop_the_deploy(self):
        self.repo.commit("Next", {"site/index.html": SITE["site/index.html"] + "<p>Next</p>"})
        code, out, report, cloud = self.run_tool("--yes", tests=lambda: (False, ["FAILED (failures=1)"]))
        self.assertEqual(code, 1)
        self.assertIn("The tests failed", report.stops)
        self.assertEqual(cloud.deployed, [])

    def test_a_deploy_records_the_commit_and_checks_the_live_site(self):
        c = self.repo.commit("Next", {"site/index.html": SITE["site/index.html"] + "<p>Next</p>"})
        code, out, report, cloud = self.run_tool("--yes")
        self.assertEqual(code, 0, out)
        self.assertEqual(cloud.deployed, [("worker", f"deploy-site commit={c} branch=main"), ("pages", "main", c)])
        self.assertIn(f"burn.tommymassaro.com: serving {c[:7]}", out)
        self.assertIn(f"burn-1hx.pages.dev: serving {c[:7]}", out)
        self.assertIn(f"npx wrangler rollback v-old --name {ds.WORKER}", out)
        self.assertIn("pages/view/burn/p-old", out)
        self.assertIn("Write a release note", out)
        self.assertIn("Push main to GitHub when Tommy says so", out)

    def test_a_broken_link_in_the_commit_stops_before_deploying(self):
        self.repo.commit("Broken", {"site/index.html": SITE["site/index.html"] + '<img src="assets/missing.png">'})
        code, out, report, cloud = self.run_tool("--yes")
        self.assertEqual(code, 1)
        self.assertIn("index.html → assets/missing.png", out)
        self.assertEqual(cloud.deployed, [])

    def test_staging_notes_missing_live_work_and_deploys_the_preview(self):
        self.repo.switch("-c", "side", self.a)
        c = self.repo.commit("Side change", {"site/side.txt": "side"})
        code, out, report, cloud = self.run_tool("--staging", "--yes")
        self.assertEqual(code, 0, out)
        self.assertEqual(cloud.deployed, [("pages", ds.STAGING_BRANCH, c)])
        self.assertIn("Fine for a staging preview", out)
        self.assertIn(f"{ds.STAGING_SITE.host}: serving {c[:7]}", out)

    # ── the site and the live checks ──

    def test_the_site_check_reads_tags_not_script_text(self):
        site = self.root / "export" / "site"
        for rel, text in SITE.items():
            if rel.startswith("site/"):
                (site / rel[5:]).parent.mkdir(parents=True, exist_ok=True)
                (site / rel[5:]).write_text(text)
        (site / "index.html").write_text(
            '<a href="demo/?embed">x</a><a href="https://github.com/tmass1/burn">gh</a><a href="#top">t</a>'
            '<meta property="og:image" content="https://burn.tommymassaro.com/assets/missing-og.png">'
            '<img src="assets/missing.png"><script>/* <a href="/Mark.dmg"> */</script><svg><use href="#pm"/></svg>'
            '<style>.x{background:url(signature/missing.woff2)}'
            """body::after{background-image:url("data:image/svg+xml;utf8,<svg><rect filter='url(%23n)'/></svg>")}</style>""")
        missing = ds.site_check(site)
        self.assertEqual(missing, ["index.html → https://burn.tommymassaro.com/assets/missing-og.png",
                                   "index.html → assets/missing.png", "index.html → signature/missing.woff2"])

    def test_a_repo_file_served_publicly_is_flagged(self):
        files = self.repo.site_files(self.b)
        files["README.md"] = SITE["README.md"].encode()
        web = Web(**{ds.WORKER_SITE.host: Host(files, True)})
        flagged = []
        ok = ds.check_serving(self.repo.git, web, ds.WORKER_SITE, self.b, lambda title, *lines: flagged.append(title))
        self.assertFalse(ok)
        self.assertEqual(flagged, ["https://burn.tommymassaro.com/README.md is public, and it should never be served"])

    def test_cloudflares_injected_beacon_isnt_part_of_the_page(self):
        page = b"<p>Burn</p>\n</body>\n</html>\n"
        served = page.replace(b"\n</body>", b'\n<script defer src="https://static.cloudflareinsights.com/beacon.min.js/'
                                            b'v1" data-cf-beacon=\'{"token":"x"}\' crossorigin="anonymous"></script>'
                                            b"\n</body>")
        self.assertEqual(ds.CLOUDFLARE_BEACON.sub(b"", served), page)

    def test_the_pages_home_page_fallback_is_not_a_leak(self):
        web = Web(**{ds.PAGES_SITE.host: Host(self.repo.site_files(self.b), False)})
        flagged = []
        self.assertTrue(ds.check_serving(self.repo.git, web, ds.PAGES_SITE, self.b, lambda t, *l: flagged.append(t)))
        self.assertEqual(flagged, [])


if __name__ == "__main__":
    unittest.main()
