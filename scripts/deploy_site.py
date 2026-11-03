#!/usr/bin/env python3
"""The one way to deploy Burn's site.

Production is burn.tommymassaro.com (the Worker `burn-site`) and burn-1hx.pages.dev (the Pages project `burn`), always
deployed together; `--staging` sends a preview to staging.burn-1hx.pages.dev instead. Before anything ships it asks
Cloudflare which commit is live and refuses to deploy a branch that doesn't contain it, so a deploy can't quietly take
live work off the site. docs/deploying.md explains every stop in plain language.

  scripts/deploy_site.py --check        every check against real production, without building or deploying
  scripts/deploy_site.py                production: checks, tests, build, then asks you to type `deploy`
  scripts/deploy_site.py --staging      the staging preview
  --yes                                 for running without a terminal, and only after Tommy has said yes in chat:
                                        answers the confirmations yes; it never gets past a stop
  --live-commit <commit>                names the live commit by hand when the check can't tell
"""
from __future__ import annotations

import argparse
import hashlib
import html.parser
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional, Tuple

REPO = Path(__file__).resolve().parent.parent
MAIN = "main"
REMOTE = "origin"
WORKER = "burn-site"
PAGES_PROJECT = "burn"
STAGING_BRANCH = "staging"
# What a deploy is made of. Uncommitted changes to any of these stop it.
INPUTS = ("site", "wrangler.jsonc", "scripts/deploy_site.py")
# Pages that must load, byte for byte as committed, after a deploy (paths inside site/).
PUBLIC = ("index.html", "demo/index.html", "assets/og.png", "demo/poster.png", "signature/signature.js")
# Repo files that sit beside site/, not in it, and must never be served.
HIDDEN = ("wrangler.jsonc", "README.md", "AGENTS.md", "Package.swift", "scripts/release.sh")
# The note every deploy through this script leaves on its Worker version.
NOTE = re.compile(r"deploy-site commit=([0-9a-f]{40})")


@dataclass(frozen=True)
class Target:
    host: str
    # The Worker answers a missing file with 404; Pages answers it with the home page.
    missing_is_404: bool

    @property
    def url(self) -> str:
        return f"https://{self.host}"


WORKER_SITE = Target("burn.tommymassaro.com", True)
PAGES_SITE = Target("burn-1hx.pages.dev", False)
STAGING_SITE = Target(f"{STAGING_BRANCH}.burn-1hx.pages.dev", False)
OWN_HOSTS = {WORKER_SITE.host, PAGES_SITE.host}

Fetch = Callable[[str], Tuple[int, bytes]]


class Stop(Exception):
    """Something that ends the run at once, such as Cloudflare not answering. Nothing is deployed after one."""

    def __init__(self, title: str, *lines: str):
        super().__init__(title)
        self.title = title
        self.lines = [line for line in lines if line]


@dataclass
class Report:
    """What the run found, printed as it goes. Stops can't be overridden; confirmations are questions for Tommy."""

    out: Callable[[str], None] = print
    stops: List[str] = field(default_factory=list)
    confirms: List[Tuple[str, List[str]]] = field(default_factory=list)
    problems: List[str] = field(default_factory=list)

    def section(self, title: str) -> None:
        self.out(f"\n{title}")

    def line(self, text: str = "") -> None:
        self.out(f"  {text}")

    def _block(self, label: str, title: str, lines) -> None:
        self.out(f"  {label}  {title}")
        for line in lines:
            if line:
                self.out(f"        {line}")

    def stop(self, title: str, *lines: str) -> None:
        self.stops.append(title)
        self._block("STOP", title, lines)

    def confirm(self, question: str, *lines: str) -> None:
        self.confirms.append((question, [line for line in lines if line]))
        self._block("ASK ", question, lines)

    def warn(self, title: str, *lines: str) -> None:
        self._block("NOTE", title, lines)

    def problem(self, title: str, *lines: str) -> None:
        self.problems.append(title)
        self._block("FAIL", title, lines)


# ── Git ──────────────────────────────────────────────────────────────────────────────────────────────────────────


class Git:
    def __init__(self, root: Path):
        self.root = Path(root)

    def _run(self, args, data: Optional[bytes] = None):
        return subprocess.run(["git", "-C", str(self.root), *args], input=data, capture_output=True)

    def run(self, *args: str) -> str:
        p = self._run(args)
        if p.returncode:
            raise Stop(f"git {args[0]} failed", p.stderr.decode(errors="replace").strip())
        return p.stdout.decode(errors="replace").strip()

    def maybe(self, *args: str) -> Optional[str]:
        p = self._run(args)
        return p.stdout.decode(errors="replace").strip() if p.returncode == 0 else None

    def lines(self, *args: str) -> List[str]:
        out = self.run(*args)
        return out.splitlines() if out else []

    def resolve(self, rev: str) -> Optional[str]:
        return self.maybe("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}") or None

    def contains(self, commit: str, rev: str = "HEAD") -> bool:
        return self._run(["merge-base", "--is-ancestor", commit, rev]).returncode == 0

    def subject(self, rev: str) -> str:
        return self.run("log", "-1", "--format=%h “%s”", rev)

    def blob(self, rev: str, path: str) -> Optional[str]:
        return self.maybe("rev-parse", "--verify", "--quiet", f"{rev}:{path}") or None

    def show(self, rev: str, path: str) -> Optional[bytes]:
        p = self._run(["show", f"{rev}:{path}"])
        return p.stdout if p.returncode == 0 else None

    def branch(self) -> str:
        return self.maybe("symbolic-ref", "--short", "-q", "HEAD") or "(no branch)"

    def batch_check(self, specs: List[str]) -> List[Optional[str]]:
        """Object ids for `rev:path` specs in one call; None where the path doesn't exist."""
        p = self._run(["cat-file", "--batch-check"], ("\n".join(specs) + "\n").encode())
        out = []
        for line in p.stdout.decode().splitlines():
            parts = line.split()
            out.append(parts[0] if len(parts) == 3 and parts[1] in ("tree", "blob") else None)
        return out

    def archive(self, rev: str, *paths: str) -> bytes:
        p = self._run(["archive", "--format=tar", rev, *paths])
        if p.returncode:
            raise Stop("Couldn't export the commit", p.stderr.decode(errors="replace").strip())
        return p.stdout


# ── Cloudflare ───────────────────────────────────────────────────────────────────────────────────────────────────


class Cloudflare:
    """What Cloudflare records about each deploy, read and written through wrangler (`npx wrangler login` once)."""

    def __init__(self, root: Path):
        self.root = Path(root)

    def wrangler(self, *args: str, cwd: Optional[Path] = None) -> str:
        p = subprocess.run(["npx", "--yes", "wrangler", *args], cwd=str(cwd or self.root), capture_output=True, text=True)
        if p.returncode:
            tail = (p.stderr.strip() or p.stdout.strip()).splitlines()[-6:]
            raise Stop(f"`wrangler {' '.join(args[:2])}` failed", *tail,
                       "If it says you're signed out of Cloudflare, run `npx wrangler login` and try again.")
        return p.stdout

    def _json(self, *args: str):
        text = self.wrangler(*args)
        starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
        try:
            return json.loads(text[min(starts):]) if starts else None
        except json.JSONDecodeError:
            raise Stop(f"`wrangler {' '.join(args[:2])}` gave an answer this script can't read", text.strip()[:300])

    def worker_now(self) -> Tuple[List[str], List[str]]:
        """The versions serving burn.tommymassaro.com now, and the commits their deploy notes name."""
        status = self._json("deployments", "status", "--name", WORKER, "--json") or {}
        versions = [v["version_id"] for v in status.get("versions", []) if v.get("version_id")]
        commits = set()
        for version in versions:
            view = self._json("versions", "view", version, "--name", WORKER, "--json") or {}
            match = NOTE.search((view.get("annotations") or {}).get("workers/message") or "")
            if match:
                commits.add(match.group(1))
        return versions, sorted(commits)

    def pages_now(self, branch: str) -> List[dict]:
        """The Pages project's deploys of `branch`, newest first."""
        environment = "production" if branch == MAIN else "preview"
        rows = self._json("pages", "deployment", "list", "--project-name", PAGES_PROJECT,
                          "--environment", environment, "--json") or []
        return [row for row in rows if row.get("Branch") == branch]

    def deploy_worker(self, export: Path, note: str) -> str:
        return self.wrangler("deploy", "--config", str(export / "wrangler.jsonc"), "--message", note, cwd=export)

    def deploy_pages(self, export: Path, branch: str, commit: str, message: str) -> str:
        return self.wrangler("pages", "deploy", str(export / "site"), "--project-name", PAGES_PROJECT,
                             "--branch", branch, "--commit-hash", commit, "--commit-message", message,
                             "--commit-dirty=false", cwd=export)


# ── The live site ────────────────────────────────────────────────────────────────────────────────────────────────


# Cloudflare Web Analytics adds its beacon to HTML on the way out, so a page as served isn't byte for byte the file
# that was deployed. Asking for */* rather than text/html usually skips it; this takes it out when it doesn't.
CLOUDFLARE_BEACON = re.compile(rb'\n?<script[^>]*static\.cloudflareinsights\.com/beacon[^>]*>\s*</script>')


def fetch(url: str) -> Tuple[int, bytes]:
    request = urllib.request.Request(url, headers={"User-Agent": "burn-deploy-site", "Accept": "*/*",
                                                   "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
            if "html" in (response.headers.get("Content-Type") or ""):
                body = CLOUDFLARE_BEACON.sub(b"", body)
            return response.status, body
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except (urllib.error.URLError, OSError) as error:
        raise Stop(f"Couldn't load {url}", str(getattr(error, "reason", error)))


def blob_id(data: bytes) -> str:
    """The id Git gives a file with these bytes, so a live file can be compared with a committed one."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def page_url(target: Target, path: str) -> str:
    if path == "index.html" or path.endswith("/index.html"):
        path = path[: -len("index.html")]
    return f"{target.url}/{urllib.parse.quote(path, safe='/@')}"


def serves(git: Git, get: Fetch, target: Target, commit: str, path: str = "index.html") -> bool:
    want = git.blob(commit, f"site/{path}")
    status, body = get(page_url(target, path))
    return want is not None and status == 200 and blob_id(body) == want


def match_live_files(git: Git, get: Fetch, target: Target, limit: int = 300) -> List[str]:
    """For deploys without a note: the commits whose site/ is exactly what `target` serves, newest first. Empty when no
    commit in this copy matches, because the live files were never committed here or haven't been fetched."""
    commits = git.lines("log", "--all", f"-n{limit}", "--format=%H", "--", "site")
    trees = git.batch_check([f"{commit}:site" for commit in commits])
    by_tree = {}
    for commit, tree in zip(commits, trees):
        if tree:
            by_tree.setdefault(tree, []).append(commit)
    files = {}
    for tree in by_tree:
        entries = {}
        for line in git.lines("ls-tree", "-r", tree):
            meta, path = line.split("\t", 1)
            entries[path] = meta.split()[2]
        files[tree] = entries
    every_path = set().union(*files.values()) if files else set()
    live = {}

    def live_blob(path: str) -> Optional[str]:
        if path not in live:
            status, body = get(page_url(target, path))
            live[path] = blob_id(body) if status == 200 else None
        return live[path]

    for tree, tree_commits in by_tree.items():
        mine = files[tree]
        order = sorted(mine, key=lambda p: (p != "index.html", p))
        if any(live_blob(path) != mine[path] for path in order):
            continue
        # A file this commit doesn't have must not be served with the contents another commit gave it.
        if any(live_blob(path) in {f[path] for f in files.values() if path in f} for path in every_path - set(mine)):
            continue
        return tree_commits
    return []


@dataclass
class Live:
    target: Target
    commits: List[str]          # newest first; all have this exact site/, so a branch with any of them is fine
    how: str
    rollback_to: Optional[str]  # what an undo would go back to: a Worker version, or a Pages deployment

    @property
    def commit(self) -> str:
        """The oldest of the matching commits: the least a branch has to contain."""
        return self.commits[-1]


def find_live(git: Git, cloud: Cloudflare, get: Fetch, target: Target, by_hand: Optional[str],
              report: Report, stop: Optional[Callable] = None) -> Optional[Live]:
    """`stop` is how a dead end is reported: a stop for production, a note for a staging preview."""
    stop = stop or report.stop
    if target is WORKER_SITE:
        versions, noted = cloud.worker_now()
        rollback_to = versions[0] if versions else None
        how = "its deploy note"
    else:
        rows = cloud.pages_now(MAIN if target is PAGES_SITE else STAGING_BRANCH)
        rollback_to = rows[0].get("Id") if rows else None
        noted = [rows[0]["Source"]] if rows and rows[0].get("Source") else []
        how = "the commit Pages recorded"

    if len(noted) == 1:
        commit = git.resolve(noted[0])
        if commit is None:
            stop(f"{target.host} is running {noted[0][:7]}, which this copy doesn't have",
                        "Push that commit from the copy it was deployed from, run `git fetch` here, and check again.")
            return None
        if serves(git, get, target, commit):
            return Live(target, [commit], how, rollback_to)
        report.warn(f"{target.host}: {how} says {commit[:7]}, but the live files don't match it",
                    "Maybe it was rolled back. Matching the live files to a commit instead.")

    commits = match_live_files(git, get, target)
    if commits:
        return Live(target, commits, "matching the live files (that deploy left no note)", rollback_to)
    if by_hand:
        commit = git.resolve(by_hand)
        if commit is None:
            stop(f"--live-commit {by_hand} isn't a commit this copy has", "Run `git fetch` and check again.")
            return None
        return Live(target, [commit], "named by hand with --live-commit", rollback_to)
    stop(f"Can't tell which commit {target.host} is running",
                "Its deploy has no note, and its files don't match any commit in this copy.",
                "If it was deployed from another copy, push that commit, run `git fetch`, and check again.",
                "If you know which commit it is, run again with --live-commit <commit>.")
    return None


def check_serving(git: Git, get: Fetch, target: Target, commit: str, flag: Callable) -> bool:
    """The public pages load as committed; repo files beside site/ stay unserved."""
    ok = True
    for path in PUBLIC:
        want = git.blob(commit, f"site/{path}")
        url = page_url(target, path)
        status, body = get(url)
        if status != 200:
            flag(f"{url} doesn't load (HTTP {status})")
            ok = False
        elif want and blob_id(body) != want:
            flag(f"{url} isn't the file in {commit[:7]}")
            ok = False
    for path in HIDDEN:
        secret = git.show(commit, path)
        if secret is None:
            continue
        status, body = get(f"{target.url}/{path}")
        if status == 200 and body == secret:
            flag(f"{target.url}/{path} is public, and it should never be served",
                 "Check that wrangler.jsonc still serves only ./site.")
            ok = False
    return ok


# ── This branch ──────────────────────────────────────────────────────────────────────────────────────────────────


def check_contains_live(git: Git, branch: str, lives: List[Live], report: Report, staging: bool = False) -> None:
    for live in lives:
        if any(git.contains(commit) for commit in live.commits):
            report.line(f"Has everything live on {live.target.host}.")
            continue
        lost = git.lines("log", "--format=%h %s", f"HEAD..{live.commit}")
        holders = [b for b in git.lines("branch", "-a", "--format=%(refname:short)", "--contains", live.commit)
                   if not b.endswith("/HEAD") and b != REMOTE]
        holders.sort(key=lambda b: (b not in (MAIN, f"{REMOTE}/{MAIN}"), b.startswith(f"{REMOTE}/"), b))
        listed = [f"  {line}" for line in lost[:12]] + ([f"  …and {len(lost) - 12} more"] if len(lost) > 12 else [])
        if not holders:
            fix = "No branch here holds it. Push it from where it was made, `git fetch`, then merge."
        elif branch == "(no branch)":
            fix = f"This copy isn't on a branch. Switch to {holders[0]} (`git switch {holders[0]}`), then check again."
        else:
            fix = f"Merge {holders[0]} into {branch} (`git merge {holders[0]}`), then check again."
        if staging:
            report.warn(f"This branch is missing {len(lost)} commit(s) that are live on {live.target.host}",
                        *listed, "Fine for a staging preview, but production would stop on this.", fix)
        else:
            report.stop(f"This branch is missing work that's live on {live.target.host}",
                        f"Deploying it would take these {len(lost)} commit(s) off the site:", *listed, fix)


def check_in_step(git: Git, branch: str, fetched: bool, report: Report) -> None:
    before = len(report.confirms)
    if not fetched:
        report.confirm("GitHub couldn't be reached, so it's unknown whether it has commits you don't. Deploy anyway?")
    if branch != MAIN:
        report.confirm(f"You're deploying from {branch}, not {MAIN}. Deploy anyway?",
                       f"Afterwards merge it into {MAIN}; until then a deploy from {MAIN} would stop.")
    upstream = git.maybe("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if not upstream:
        report.confirm(f"{branch} isn't on GitHub, so this deploy's commits would exist only on this Mac. Deploy anyway?")
    else:
        ahead = git.lines("log", "--format=%h %s", f"{upstream}..HEAD")
        behind = git.lines("log", "--format=%h %s", f"HEAD..{upstream}")
        if ahead:
            report.confirm(f"{len(ahead)} commit(s) here aren't pushed to {upstream}. Deploy anyway?",
                           *[f"  {line}" for line in ahead[:8]])
        if behind:
            report.confirm(f"{upstream} has {len(behind)} commit(s) this branch doesn't. Deploy without them?",
                           *[f"  {line}" for line in behind[:8]])
    remote_main = f"{REMOTE}/{MAIN}"
    if upstream != remote_main and git.resolve(remote_main) and not git.contains(remote_main):
        behind = git.lines("log", "--format=%h %s", f"HEAD..{remote_main}")
        report.confirm(f"GitHub's {MAIN} has {len(behind)} commit(s) this branch doesn't. Deploy without them?",
                       *[f"  {line}" for line in behind[:8]])
    if len(report.confirms) == before:
        report.line(f"On {MAIN}, and in step with GitHub.")


def show_additions(git: Git, lives: List[Live], report: Report) -> None:
    shown = set()
    for live in lives:
        base = next((c for c in live.commits if git.contains(c)), live.commit)
        hosts = ", ".join(l.target.host for l in lives if next((c for c in l.commits if git.contains(c)), l.commit) == base)
        if base in shown:
            continue
        shown.add(base)
        changes = git.lines("log", "--format=%h %s", f"{base}..HEAD", "--", *INPUTS)
        others = len(git.lines("rev-list", f"{base}..HEAD")) - len(changes)
        report.line(f"{hosts}, running {git.subject(base)}:")
        if not changes:
            report.line("  Nothing new for the site. Deploying would change nothing.")
            continue
        for line in changes[:15]:
            report.line(f"  {line}")
        if len(changes) > 15:
            report.line(f"  …and {len(changes) - 15} more")
        for line in git.lines("diff", "--stat=90", base, "HEAD", "--", *INPUTS):
            report.line(f"    {line.strip()}")
        if others > 0:
            report.line(f"  (plus {others} commit(s) that don't touch the site)")


# ── Tests and build ──────────────────────────────────────────────────────────────────────────────────────────────


def run_tests(root: Path) -> Tuple[bool, List[str]]:
    p = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-p", "test_*.py"],
                       cwd=str(root), capture_output=True, text=True)
    tail = (p.stderr or p.stdout).strip().splitlines()
    return p.returncode == 0, tail[-25:]


def build(git: Git, commit: str) -> Path:
    """The committed site/ and wrangler.jsonc of `commit`, in a fresh folder: exactly what ships, nothing loose."""
    export = Path(tempfile.mkdtemp(prefix="burn-site-"))
    with tarfile.open(fileobj=io.BytesIO(git.archive(commit, "site", "wrangler.jsonc"))) as tar:
        try:
            tar.extractall(export, filter="data")
        except TypeError:
            tar.extractall(export)
    return export


CSS_URL = re.compile(r"""url\(\s*['"]?([^'")]+)['"]?\s*\)""")


class _Refs(html.parser.HTMLParser):
    """The addresses a page's own tags point at. Text inside scripts is left alone."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs: List[str] = []
        self._style = False

    def handle_starttag(self, tag, attrs):
        a = {k: v or "" for k, v in attrs}
        for name in ("href", "src", "poster"):
            if a.get(name):
                self.refs.append(a[name])
        if a.get("srcset"):
            self.refs += [part.split()[0] for part in a["srcset"].split(",") if part.strip()]
        if tag == "meta" and a.get("content", "").startswith("https://"):
            self.refs.append(a["content"])
        if a.get("style"):
            self.refs += CSS_URL.findall(a["style"])
        self._style = self._style or tag == "style"

    def handle_endtag(self, tag):
        if tag == "style":
            self._style = False

    def handle_data(self, data):
        if self._style:
            self.refs += CSS_URL.findall(data)


def _resolves(site: Path, base: Path, ref: str) -> bool:
    ref = ref.strip()
    # `url(%23n)` inside an inline SVG is an encoded `#n`: a fragment, not a file.
    if not ref or urllib.parse.unquote(ref).startswith(("#", "data:", "mailto:", "tel:", "javascript:", "about:", "blob:")):
        return True
    parts = urllib.parse.urlsplit(ref)
    if parts.scheme or parts.netloc:
        if parts.netloc not in OWN_HOSTS:
            return True
        path = parts.path or "/"
    else:
        path = parts.path
    if not path:
        return True
    path = urllib.parse.unquote(path)
    root = site.resolve()
    target = (root / path.lstrip("/")) if path.startswith("/") else (base / path)
    target = target.resolve()
    if target != root and root not in target.parents:
        return False
    if target.is_dir():
        target = target / "index.html"
    return target.is_file()


def site_check(site: Path) -> List[str]:
    """Every page, image, script and stylesheet the site's own pages point at, that isn't there."""
    missing = []
    for page in sorted(site.rglob("*.html")):
        refs = _Refs()
        refs.feed(page.read_text(encoding="utf-8"))
        missing += [f"{page.relative_to(site)} → {ref}" for ref in refs.refs if not _resolves(site, page.parent, ref)]
    for sheet in sorted(site.rglob("*.css")):
        missing += [f"{sheet.relative_to(site)} → {ref}" for ref in CSS_URL.findall(sheet.read_text(encoding="utf-8"))
                    if not _resolves(site, sheet.parent, ref)]
    missing += [f"{path} (checked on the live site after every deploy)" for path in PUBLIC if not (site / path).is_file()]
    return missing


# ── The run ──────────────────────────────────────────────────────────────────────────────────────────────────────


def ask(question: str, lines: List[str], yes: bool, tty: bool, out) -> bool:
    if yes:
        out(f"  {question} yes (--yes)")
        return True
    if not tty:
        raise Stop("This needs an answer, and there's no terminal to ask in",
                   "Run it in Terminal yourself. An agent may add --yes, but only after Tommy has said yes in chat "
                   "to this deploy and its target.")
    for line in lines:
        out(f"    {line}")
    return input(f"  {question} [y/N] ").strip().lower() in ("y", "yes")


def type_word(word: str, yes: bool, tty: bool, out) -> bool:
    if yes:
        out(f"  Going ahead (--yes).")
        return True
    if not tty:
        raise Stop("This needs you to type `deploy`, and there's no terminal to type it in",
                   "Run it in Terminal yourself, or (agents) add --yes only after Tommy said yes in chat.")
    return input(f"  Type {word} to go ahead, anything else to stop: ").strip() == word


def account_id(root: Path) -> str:
    match = re.search(r'"account_id"\s*:\s*"(\w+)"', (root / "wrangler.jsonc").read_text())
    return match.group(1) if match else "<account>"


def rollback_lines(git: Git, lives: List[Live], account: str) -> List[str]:
    lines = []
    for live in lives:
        if not live.rollback_to:
            continue
        short = live.commits[0][:7]
        if live.target is WORKER_SITE:
            lines += [f"{live.target.host} (back to {short}):",
                      f"  npx wrangler rollback {live.rollback_to} --name {WORKER} --message \"Back to {short}\""]
        else:
            lines += [f"{live.target.host} (back to {short}): open",
                      f"  https://dash.cloudflare.com/{account}/pages/view/{PAGES_PROJECT}/{live.rollback_to}",
                      "  and choose ⋯ → Rollback to this deployment"]
    return lines


def wait_until_serving(git: Git, get: Fetch, target: Target, commit: str, seconds: int = 120,
                       sleep: Callable[[float], None] = time.sleep) -> bool:
    deadline = time.monotonic() + seconds
    while True:
        if serves(git, get, target, commit):
            return True
        if time.monotonic() > deadline:
            return False
        sleep(5)


def run(args, git: Git, cloud: Cloudflare, get: Fetch, report: Report, tty: bool,
        tests: Callable[[], Tuple[bool, List[str]]], sleep: Callable[[float], None] = time.sleep,
        wait_seconds: int = 120) -> int:
    staging = args.staging
    out = report.out
    branch = git.branch()
    head = git.run("rev-parse", "HEAD")
    targets = [STAGING_SITE] if staging else [WORKER_SITE, PAGES_SITE]
    name = "staging preview" if staging else "production"
    out(f"Burn site · {name} {'check' if args.check else 'deploy'}")
    out(f"  From {branch}, at {git.subject('HEAD')}")
    out(f"  To {' and '.join(t.host for t in targets)}")

    report.section("1. Uncommitted changes in what ships")
    dirty = git.lines("status", "--porcelain", "--untracked-files=all", "--", *INPUTS)
    if dirty:
        report.stop("These files are changed or new but not committed:", *[f"  {line}" for line in dirty],
                    "Commit them, or put them aside, and run again. A deploy ships commits, never loose edits.")
    else:
        report.line("None.")

    fetched = git.maybe("fetch", "--quiet", REMOTE) is not None

    report.section("2. What's live")
    lives = []
    for target in (WORKER_SITE, PAGES_SITE):
        live = find_live(git, cloud, get, target, args.live_commit, report, report.warn if staging else None)
        if live:
            lives.append(live)
            report.line(f"{target.host}: {git.subject(live.commits[0])}, found by {live.how}")
    if staging:
        rows = cloud.pages_now(STAGING_BRANCH)
        report.line(f"{STAGING_SITE.host}: " + (f"{rows[0].get('Source')} (the last preview)" if rows else "nothing yet"))

    report.section("3. Does this branch have everything that's live?")
    check_contains_live(git, branch, lives, report, staging=staging)

    report.section("4. Questions before deploying")
    if staging:
        report.line("None for a staging preview.")
    else:
        check_in_step(git, branch, fetched, report)

    if report.stops and not args.check:
        return finish_stopped(report)

    report.section("5. Tests")
    ok, tail = tests()
    if ok:
        report.line("Passed. " + next((line for line in tail if line.startswith("Ran ")), ""))
    else:
        report.stop("The tests failed", *tail)

    report.section("6. What this deploy adds")
    if any(s.startswith("This branch is missing") for s in report.stops):
        report.line("(Not shown until the branch has everything that's live.)")
    else:
        show_additions(git, lives, report)

    if args.check:
        report.section("7. The live site right now")
        for live in lives:
            if check_serving(git, get, live.target, live.commit, report.warn):
                report.line(f"{live.target.host}: public pages load; repo files stay hidden.")
        undo = rollback_lines(git, lives if not staging else [], account_id(git.root))
        if undo and not staging:
            report.section("If you deployed now, the undo would be")
            for line in undo:
                report.line(line)
        if report.stops:
            return finish_stopped(report)
        report.section("Result")
        report.line(f"Ready. Nothing was built or deployed (--check).")
        if report.confirms:
            report.line(f"A real deploy would first ask you {len(report.confirms)} question(s) above.")
        report.line("A real deploy would then build, show the site check, ask you to type "
                    f"`{'staging' if staging else 'deploy'}`, deploy, check the live site and print the undo.")
        return 0

    if report.stops:
        return finish_stopped(report)

    if report.confirms:
        report.section("Your answers")
        for question, lines in report.confirms:
            if not ask(question, lines, args.yes, tty, out):
                out("  Stopped at your answer. Nothing was deployed.")
                return 1

    report.section("7. Build")
    export = build(git, head)
    try:
        missing = site_check(export / "site")
        if missing:
            report.stop("The site points at files that aren't in the commit:", *[f"  {m}" for m in missing],
                        "Add or fix them, commit, and run again.")
            return finish_stopped(report)
        report.line(f"Exported {head[:7]}'s site/; every page, image and script it points at is there.")

        word = "staging" if staging else "deploy"
        report.section(f"8. Deploy {head[:7]} to {' and '.join(t.host for t in targets)}?")
        if not type_word(word, args.yes, tty, out):
            out("  Stopped. Nothing was deployed.")
            return 1

        subject = git.run("log", "-1", "--format=%s", "HEAD")
        message = f"{subject} · deploy-site from {branch}"
        done = []
        try:
            if staging:
                cloud.deploy_pages(export, STAGING_BRANCH, head, message)
                done.append(STAGING_SITE)
            else:
                cloud.deploy_worker(export, f"deploy-site commit={head} branch={branch}")
                done.append(WORKER_SITE)
                report.line(f"{WORKER_SITE.host}: deployed, with the note commit={head[:7]} branch={branch}.")
                cloud.deploy_pages(export, MAIN, head, message)
                done.append(PAGES_SITE)
                report.line(f"{PAGES_SITE.host}: deployed, with Pages' commit field set to {head[:7]}.")
        except Stop as stop:
            report.problem(stop.title, *stop.lines)
            if done:
                report.problem(f"Only {' and '.join(t.host for t in done)} got the new commit",
                               "Run the deploy again once the cause is fixed; it will pick up from here.")
    finally:
        shutil.rmtree(export, ignore_errors=True)

    report.section("9. Checking the live site")
    for target in done:
        if not wait_until_serving(git, get, target, head, wait_seconds, sleep):
            report.problem(f"{target.host} still isn't serving {head[:7]} after {wait_seconds} seconds")
            continue
        if check_serving(git, get, target, head, report.problem):
            report.line(f"{target.host}: serving {head[:7]}; public pages load; repo files stay hidden.")

    if staging:
        report.section("Done" if not report.problems else "Done, with problems")
        report.line(f"Preview: {STAGING_SITE.url}/ (anyone with the address can open it)")
        return 1 if report.problems else 0

    report.section("If something's wrong, undo it")
    for line in rollback_lines(git, [l for l in lives if l.target in done], account_id(git.root)):
        report.line(line)

    report.section("To do")
    report.line("Write a release note: a line on what visitors will see change.")
    upstream = git.maybe("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if branch != MAIN:
        report.line(f"Merge {branch} into {MAIN}. Until then, a deploy from {MAIN} will stop, because it's missing this.")
    if not upstream or git.lines("rev-list", f"{upstream}..HEAD"):
        report.line(f"Push {branch} to GitHub when Tommy says so (`git push {REMOTE} {branch}`).")
    return 1 if report.problems else 0


def finish_stopped(report: Report) -> int:
    report.section("Result")
    report.line(f"STOPPED: {len(report.stops)} thing(s) to fix first. Nothing was deployed.")
    for title in report.stops:
        report.line(f"  • {title}")
    report.line("docs/deploying.md explains each stop.")
    return 1


def parse(argv=None):
    parser = argparse.ArgumentParser(prog="deploy_site.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="run every check against production, deploy nothing")
    parser.add_argument("--staging", action="store_true", help=f"deploy a preview to {STAGING_SITE.url}")
    parser.add_argument("--yes", action="store_true",
                        help="no terminal: answer the confirmations yes (only after Tommy said yes in chat)")
    parser.add_argument("--live-commit", metavar="COMMIT", help="the live commit, when the check can't tell")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse(argv)
    report = Report()
    try:
        return run(args, Git(REPO), Cloudflare(REPO), fetch, report, sys.stdin.isatty(), lambda: run_tests(REPO))
    except Stop as stop:
        report.stop(stop.title, *stop.lines)
        return finish_stopped(report)
    except KeyboardInterrupt:
        print("\n  Stopped. Nothing new was deployed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
