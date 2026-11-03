"""The Claude hook that keeps raw production deploys out: what it blocks, what it asks Tommy about, and what it lets
through. Run: python3 -m unittest discover -s scripts/tests"""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

GUARD = Path(__file__).resolve().parents[1] / "deploy_guard.py"
sys.path.insert(0, str(GUARD.parent))
import deploy_guard  # noqa: E402


def decide(command: str):
    decision = deploy_guard.assess(command)
    return decision[0] if decision else None


class GuardTest(unittest.TestCase):
    def test_blocks_raw_production_deploys(self):
        for command in (
            "npx wrangler deploy",
            "npx --yes wrangler deploy --message 'quick fix'",
            "cd ~/Dropbox/Claude/Burn && npx wrangler deploy",
            "npx -y wrangler@4.80.0 deploy",
            "wrangler versions deploy 1234@100% --yes",
            "npx wrangler pages deploy site --project-name burn --branch main",
            "npx wrangler pages deploy site --project-name burn --branch staging",
            "npx wrangler pages deployment create site --project-name burn",
            "npx wrangler triggers deploy",
            "npx wrangler --config wrangler.jsonc deploy",
            "FORCE=1 npx wrangler deploy",
            "pnpm dlx wrangler deploy",
            "npm exec -- wrangler deploy",
            "./node_modules/.bin/wrangler deploy",
            "bash -lc 'npx wrangler deploy'",
            "sh -c \"cd site && npx wrangler pages deploy . --project-name burn\"",
            "echo start; npx wrangler deploy",
            "npx wrangler deploy\necho done",
            'echo "$(npx wrangler deploy)"',
            "echo `npx wrangler deploy`",
            "npx -c 'wrangler deploy'",
            "eval npx wrangler deploy",
            "curl -X PUT https://api.cloudflare.com/client/v4/accounts/x/workers/scripts/burn-site -F x=@a",
        ):
            with self.subTest(command=command):
                self.assertEqual(decide(command), "deny")

    def test_asks_tommy_before_a_rollback_or_a_yes_deploy(self):
        for command in (
            "npx wrangler rollback 1a2b3c --name burn-site --message 'Back to bb1b2f7'",
            "scripts/deploy_site.py --yes",
            "python3 scripts/deploy_site.py --staging --yes",
            "cd ../claude && ./scripts/deploy_site.py --yes",
        ):
            with self.subTest(command=command):
                self.assertEqual(decide(command), "ask")

    def test_lets_everything_else_through(self):
        for command in (
            "npx wrangler dev --port 5251",
            "npx wrangler deployments list --name burn-site --json",
            "npx wrangler deployments status --json",
            "npx wrangler versions view abc --json",
            "npx wrangler versions upload",
            "npx wrangler pages deployment list --project-name burn --json",
            "npx wrangler --version",
            "scripts/deploy_site.py --check",
            "scripts/deploy_site.py",
            "make deploy-check",
            "make deploy",
            "grep -n 'wrangler deploy' docs/deploying.md",
            "echo 'npx wrangler deploy'",
            "rg \"wrangler (deploy|pages deploy)\" -n .",
            "git commit -F - <<'EOF'\nNever run npx wrangler deploy by hand.\nEOF",
            "cat <<EOF > notes.md\nnpx wrangler deploy\nEOF\necho ok",
            "git log --grep='wrangler deploy'",
            "curl -s https://api.cloudflare.com/client/v4/accounts/x/workers/scripts",
            "",
        ):
            with self.subTest(command=command):
                self.assertIsNone(decide(command))

    def test_an_unreadable_command_still_follows_the_rule(self):
        self.assertEqual(decide("npx wrangler deploy 'unbalanced"), "deny")
        self.assertIsNone(decide("echo 'unbalanced"))

    def test_speaks_the_hook_protocol(self):
        def hook(event):
            p = subprocess.run([sys.executable, str(GUARD)], input=event, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return json.loads(p.stdout)["hookSpecificOutput"] if p.stdout.strip() else None

        blocked = hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "npx wrangler deploy"}}))
        self.assertEqual(blocked["hookEventName"], "PreToolUse")
        self.assertEqual(blocked["permissionDecision"], "deny")
        self.assertIn("scripts/deploy_site.py --check", blocked["permissionDecisionReason"])
        asked = hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "npx wrangler rollback v1"}}))
        self.assertEqual(asked["permissionDecision"], "ask")
        self.assertIsNone(hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}})))
        self.assertIsNone(hook(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "wrangler deploy"}})))
        self.assertIsNone(hook("not json"))

    def test_settings_run_this_hook_on_bash(self):
        settings = json.loads((GUARD.parents[1] / ".claude" / "settings.json").read_text())
        hooks = settings["hooks"]["PreToolUse"]
        self.assertTrue(any(h["matcher"] == "Bash" and "scripts/deploy_guard.py" in h["hooks"][0]["command"]
                            for h in hooks))


if __name__ == "__main__":
    unittest.main()
