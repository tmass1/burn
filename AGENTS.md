# Burn: agent instructions

Codex and Claude work on this project in separate worktrees. Read `docs/agent-workflow.md` before making changes.

## Deploying the site

Production is burn.tommymassaro.com and burn-1hx.pages.dev, deployed together; staging is staging.burn-1hx.pages.dev.
The only way to deploy either is `scripts/deploy_site.py` (`make deploy`, `make deploy-staging`). Never run
`wrangler deploy`, `wrangler versions deploy` or `wrangler pages deploy` yourself, and run `wrangler rollback` only when
Tommy asks for that rollback.

- Deploy only when Tommy names the target, production or staging, for that deploy. Approval doesn't carry over.
- Run `scripts/deploy_site.py --check` first and show Tommy its whole output, including what the deploy adds, the
  questions it would ask, and the undo.
- Never get around a stop. Fix its cause instead, usually by merging the branch that holds the live commit.
- `--yes` is only for running without a terminal after Tommy has said yes in chat. It answers the questions; it never
  gets past a stop.
- After a deploy, show Tommy the undo and the to-do list it prints. After a deploy from a side branch, remind him to
  merge it into `main`.

`docs/deploying.md` explains each step and stop.
