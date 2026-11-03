# Deploying the site

The site is the `site/` folder. Production is two addresses, always deployed together:

- **burn.tommymassaro.com**: the main site (a Cloudflare Worker called `burn-site`).
- **burn-1hx.pages.dev**: a second copy (the Pages project `burn`). The Portfolio embeds its demo.

Staging is **staging.burn-1hx.pages.dev**, a preview on the same Pages project. Anyone with the address can open it.

## The one rule

Deploy only with `scripts/deploy_site.py`. A plain `wrangler deploy` ships whatever is in the folder you run it from.
If that copy is missing work that's already live, the work silently disappears from the site. The script checks for
that first and refuses. Claude's project hook blocks the plain commands; for Codex, the rule is in `AGENTS.md`.

| Command | What it does |
| --- | --- |
| `make deploy-check` | Every check against the real site. Builds nothing, deploys nothing. Run it first, always. |
| `make deploy` | Deploys production: both addresses. Asks before anything ships. |
| `make deploy-staging` | Deploys the staging preview. |

The Make commands run `scripts/deploy_site.py --check`, `scripts/deploy_site.py` and `scripts/deploy_site.py --staging`.
Two options go on the script itself:

- `--yes`: for running without a terminal (an agent) after Tommy has said yes in chat. It answers the questions yes.
  It never gets past a stop.
- `--live-commit <commit>`: names the live commit by hand, for when the script can't tell (see the stops below).

## What it does, in order

1. **Uncommitted changes.** If `site/`, `wrangler.jsonc` or the script itself has edits or new files that aren't
   committed, it stops. A deploy ships commits, never loose edits.
2. **What's live.** It asks Cloudflare which commit each address is running. Every deploy through the script leaves a
   note saying which commit and branch it came from. Deploys from before the script have no note, so for those it
   compares the live files with every commit this copy knows and finds the one they match.
3. **Does this branch have everything that's live?** If not, it stops, lists the commits the deploy would take off
   the site, and says which branch to merge.
4. **Questions.** It asks you to confirm when you're deploying from a branch other than `main`, when your commits
   aren't pushed to GitHub, or when GitHub has commits you don't.
5. **Tests.** It runs its own tests. A failure stops it.
6. **What this deploy adds.** It lists the commits and files that change since what's live.
7. **Build.** It exports exactly the committed `site/` into a fresh folder and checks that every page, image, script
   and stylesheet the pages point at is there.
8. **Go ahead?** You type `deploy` (or `staging`). Anything else stops it.
9. **Deploy.** Both addresses get the same commit, each recording the commit and branch.
10. **Check the live site.** It waits until both addresses serve the new commit, then checks that the public pages
    (home, demo, share image, demo poster, signature bar) load exactly as committed, and that repo files that sit
    beside `site/` (README, `wrangler.jsonc`, the release script) are not served. The site has no sign-in, so there's
    nothing private to check beyond that.
11. **Undo and to-do.** It prints the exact undo for each address and a to-do list: write a release note, merge into
    `main` if you deployed from another branch, and push when Tommy says so.

`--check` runs steps 1–6 and the live-site check against what's live now, and prints the undo a deploy would offer.

## When it stops

A **STOP** can't be skipped, with `--yes` or anything else. Fix the cause and run it again.

| Message | What it means | What to do |
| --- | --- | --- |
| These files are changed or new but not committed | You have edits in what ships. | Commit them, or put them aside. |
| *address* is running *commit*, which this copy doesn't have | Someone deployed from another copy (another checkout, Mac or agent) and that commit never reached this one. | Push it from where it was made, `git fetch` here, run the check again. |
| Can't tell which commit *address* is running | The live deploy left no note, and its files match no commit this copy knows. Usually it was deployed from uncommitted edits, or from commits that aren't here. | `git fetch` and try again. If you know which commit it is, run with `--live-commit <commit>`. |
| This branch is missing work that's live on *address* | Deploying would take the listed commits off the site. | Merge the branch it names (`git merge …`), then check again. |
| The tests failed | Something in the deploy script or hook is broken. | Fix it before deploying. |
| The site points at files that aren't in the commit | A broken link or image. | Add or fix the file, commit, run again. |
| This needs an answer / you to type `deploy`, and there's no terminal | It was run without a terminal and without `--yes`. | Run it in Terminal yourself. An agent adds `--yes` only after Tommy said yes in chat. |
| `wrangler …` failed | Cloudflare didn't answer. Most often you're signed out. | `npx wrangler login`, then run again. |

Other labels in the output:

- **ASK**: a question it will put to you before deploying (not on `main`, not pushed, GitHub ahead, GitHub
  unreachable). In `--check` it only lists them.
- **NOTE**: worth knowing, nothing to fix. For example, a deploy note that no longer matches the live files because
  someone rolled back. The script then matches the files instead.
- **FAIL**: after a deploy, the live site didn't check out. Look at it, and undo if it's wrong.

## Undoing a deploy

The deploy prints the exact undo with the version that was live before it.

- **burn.tommymassaro.com:** `npx wrangler rollback <version> --name burn-site --message "Back to <commit>"`.
  `npx wrangler deployments list --name burn-site` lists earlier versions. Claude asks Tommy before running it.
- **burn-1hx.pages.dev:** wrangler can't roll Pages back. Open the link the deploy printed (Cloudflare dashboard →
  Workers & Pages → burn → Deployments → the previous one) and choose **⋯ → Rollback to this deployment**.

After an undo, the next check sees the older commit as live and the undone work as not live yet. That's expected: the
work is still in Git, ready for the next deploy.
