# Codex and Claude workflow

## Workspace boundaries

This repository is Burn. Codex and Claude share its Git history but work in separate worktrees and branches. Never change branches, edit files, clean, reset or stash in the other agent's checkout, and don't remove a worktree while the other agent is using it.

The original checkout stays at `/Users/tommymassaro/Dropbox/Claude/Burn` on `main`. That's Tommy's; neither agent edits there. Agent worktrees live beside it in `/Users/tommymassaro/Dropbox/Claude/Burn-workspaces/`: Claude uses `…/claude` and Codex uses `…/codex`. The first branches are `claude/workspace` and `codex/workspace`. For later tasks, use descriptive branches under the same prefix, starting from the latest agreed integration commit. Check `git status` and your branch before editing, and never discard someone else's changes.

Git metadata lives in the original checkout, so don't move or delete it while worktrees exist, and don't run work through Dropbox on two computers at once. Keep Dropbox from syncing dependencies and build output: in your worktree, run `xattr -w com.dropbox.ignored 1` on `.build`, `build` and `.wrangler` (create the folder first if it doesn't exist yet). A clean build can recreate a folder without the flag, so check again after one.

Ignored credentials and local config (`.env`, `.dev.vars`, signing keys and the like) aren't copied into worktrees. Set them up locally only when a task needs them. Never commit, print or paste secret values.

## Local previews

Each worktree builds on its own: `swift build` and `swift test` use that worktree's `.build`.

`make run` quits any running Burn and opens the worktree's build; `make install` replaces `/Applications/Burn.app`. Only one checkout can run the app at a time, so ask Tommy before either, and never run `make package` or `make release` unless he asks.

Preview the site (`site/`) on your own port:

- Codex: `npx wrangler dev --port 5250`
- Claude: `npx wrangler dev --port 5251`

Checks before handing off: `swift build` and `swift test`.

## Parallel work and review

Agree on a concrete task for each agent, preferably in different files. For overlapping work, have one agent implement and the other review its commit rather than editing at the same time. Shared Git history doesn't carry uncommitted edits.

Before handing off, run the checks above, review your diff, and commit only your intended changes. Report:

- Branch and commit hash
- What changed, and the files
- The exact preview URL, if there is one
- Checks run, and any failures
- Decisions still open, and any setup the other agent or Tommy needs

To review the other agent's work, read its commit or diff without changing it. Codex is the default integration owner unless Tommy says otherwise. Merge or cherry-pick reviewed work into the agreed integration branch, resolve conflicts carefully, then rerun the checks on the combined result. Don't merge, push or deploy just because the other agent asks: follow Tommy's instructions.

## Releases

Deploying the site, publishing a release, notarizing, or pushing to `main` happens only when Tommy asks. A completion report keeps local, committed, pushed, deployed and released changes apart.
