# Release workflow

A manually triggered GitHub Actions workflow that cuts release candidates (RCs) from a milestone branch, rolls fixes into new RCs, and promotes the last RC to a final release. Every step pushes an annotated tag on the exact commit it refers to.

The workflow does **not** merge anything. After promotion you open the PR into the final branch yourself.

Files:

| File | Purpose |
|---|---|
| `.github/workflows/release.yml` | The workflow (inputs, permissions, runner) |
| `.github/scripts/release.sh` | All the logic; can also be run locally |
| `.github/release-configs/<project>.json` | One config per project built from this codebase |

## How a release flows

```
milestone_X ──rc──▶ release/<project>-1.4.0-RC0 ──fix──▶ …-RC1 ──fix──▶ …-RC2 ──promote──▶ release/<project>-1.4.0-release ──(manual PR)──▶ final_branch
                    tag <project>-v1.4.0-RC0             tag …-RC1      tag …-RC2           tag <project>-v1.4.0
```

| Action | What it does |
|---|---|
| `rc` | Reads `version` from the config **on the milestone branch**, applies the bump (major/minor/patch), creates branch `release/<project>-X.Y.Z-RC0` at the milestone head and tags it `<project>-vX.Y.Z-RC0`. |
| `fix` | Tags the current RC branch head as the next RC (`-RC1`, `-RC2`, …) and renames the branch to match. Refuses if nothing was pushed since the last RC. |
| `promote` | Tags the last RC commit as `<project>-vX.Y.Z`, renames the branch to `release/<project>-X.Y.Z-release`, commits `"version": "X.Y.Z"` to the config on that branch, and deletes the milestone branch if all of its commits are in the release. Prints a link to open the PR into `final_branch`. |

Naming rules:

- Release branches live under `release/` (`release/uprint-1.4.0-RC0`). This groups them in GitHub and lets one ruleset on `release/**` protect them all. The prefix comes from `branch_prefix`.
- Branches have no `v` and tags do (`uprint-v1.4.0-RC0`). Git gets confused when a branch and a tag share a name, so keep the `v`.
- The config's `version` is the **last released** version. Only `promote` changes it, and the change reaches `final_branch` through the release PR.
- Each release uses its own milestone branch. Cut it from `final_branch` **after** the previous release PR is merged, so it starts from the right `version`. If you forget, `rc` notices that a newer release tag exists, uses that tag as the base, and prints a warning.

## Adopting it in another repo

1. **Copy the files.** Copy `.github/workflows/release.yml`, `.github/scripts/release.sh` and this guide.
2. **Add a config** for each project at `.github/release-configs/<project>.json`. The file name must match its `project` value:

   ```json
   {
     "project": "uprint",
     "final_branch": "master",
     "tag_prefix": "v",
     "branch_prefix": "release/",
     "version": "0.0.0",
     "github_release": true
   }
   ```

   | Key | Required | Meaning |
   |---|---|---|
   | `project` | yes | Prefix for every branch and tag. Letters, digits, `.`, `_`, `-`. |
   | `final_branch` | yes | Branch the release PR targets (used for the PR link). |
   | `version` | yes | Last released `X.Y.Z`. Use `0.0.0` for a new project, or your current version if you already ship. |
   | `tag_prefix` | no (`v`) | Goes between the project and the version in tag names. Letters, `.`, `_`, `-` only. |
   | `branch_prefix` | no (`release/`) | Folder-style prefix for RC and release branches. Must end in `/`; `""` turns it off. |
   | `github_release` | no (`false`) | `true` also creates a GitHub Release for each tag (RCs marked as pre-release) with auto-generated notes. |

3. **List the project in the dropdown.** In `release.yml`, add one line per config file under `inputs.project.options`. GitHub cannot fill this list from the folder.
4. **Allow the workflow to push.** Go to Settings → Actions → General → Workflow permissions and select **Read and write permissions**. If the option is greyed out, an org admin has to allow it, or you can use a token stored as a secret.
5. **Commit everything to the default branch.** "Run workflow" runs the workflow and script from the branch you pick in "Use workflow from", which is usually the default branch. Keep workflow changes there, not on milestone or RC branches.
6. **Runners.** `ubuntu-latest` already has `git`, `node` and `gh`. On a self-hosted runner (e.g. `[self-hosted, docker, linux, dev2]`), make sure those three are installed.

## Running a release

Go to **Actions → Release → Run workflow**, pick the project and fill in:

| Input | Used by | Notes |
|---|---|---|
| `action` | all | `rc`, `fix` or `promote` |
| `milestone_branch` | `rc` | Branch to cut RC0 from |
| `bump` | `rc` | `patch`, `minor` or `major` |
| `version` | `fix`, `promote` | Only needed when RCs for more than one version are open at once |
| `dry_run` | all | Prints what would change and pushes nothing. Use it the first time. |

The run's **Summary** page shows the version, branches, tags and next steps.

### Typical cycle

1. Create `milestone_1.4` from `master` and merge the features into it.
2. Run `rc` with `milestone_branch=milestone_1.4` and `bump=minor`. This creates `release/uprint-1.4.0-RC0`.
3. QA tests RC0. Push fixes **to the RC branch**, then run `fix`. RC1 is tagged and the branch is renamed. Repeat as needed.
4. When the RC is approved, run `promote`. This creates the `uprint-v1.4.0` tag and the `release/uprint-1.4.0-release` branch.
5. Open the PR from the link in the summary (`release/uprint-1.4.0-release` → `final_branch`) and paste the milestone ticket as its description. Merge it once it's reviewed.

## For developers: after a rename

`fix` and `promote` rename the RC branch on GitHub. **Your local clone keeps the old name.** If you run a plain `git push` from it, GitHub creates the old branch again, and your commits end up outside the release. After every rename (the run summary shows these commands):

```bash
git fetch --prune
git branch -m release/uprint-1.4.0-RC0 release/uprint-1.4.0-RC1
git branch -u origin/release/uprint-1.4.0-RC1
```

If this happens anyway, the next `fix` or `promote` stops and lists the commits on the outdated branch. Move them to the current RC branch (cherry-pick or rebase) and run again. Outdated RC branches with nothing missing are deleted automatically.

## Errors and what to do

| Message | Fix |
|---|---|
| `config file not found … (configs in …: …)` | The dropdown lists a project without a config file. Add the file, or fix the list. |
| `the file must be named <project>.json` | Rename the config file to match its `project` key. |
| `"version" missing from … on <milestone>` | The milestone branch was cut before the config existed. Merge `master` into it. |
| `no commits since <tag>` | Push the fixes to the RC branch before running `fix`. |
| `has commits not in <last RC tag>` | Something was pushed after the last RC. Run `fix` first; only tested commits get promoted. |
| `older RC branches have commits it does not contain` | Someone pushed to an old RC name. See "For developers: after a rename" above. |
| `RCs open for several versions` | Fill in the `version` input. |
| Push or delete rejected | Branch protection or rulesets block the workflow's token. Exempt it, or use a token stored as a secret. |

## Limitations

- Tags and branches pushed by the workflow's built-in token **do not trigger other workflows**. A "build on tag" workflow needs a personal access token or a GitHub App token.
- The milestone branch is deleted only if it has no commits beyond the release. Otherwise it's kept and a warning is shown.
- Releases made before a project adopted this workflow have no record of their milestone. Clean those milestone branches up by hand.
