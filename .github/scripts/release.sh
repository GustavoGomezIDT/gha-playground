#!/usr/bin/env bash
# Release-candidate / promote helper.
#
#   release.sh rc      <major|minor|patch>   new RC0 branch from $MILESTONE_BRANCH; the base version
#                                            is "version" in the milestone branch's config file
#   release.sh fix     [version]             tag current RC branch head as RC<n+1> and rename the branch
#   release.sh promote [version]             tag final release on the last RC commit, rename the RC
#                                            branch to <project>-X.Y.Z-release, commit the new
#                                            "version" to the config on that branch, and delete the
#                                            milestone branch if it is fully contained in the release
#                                            (the PR into the final branch is opened manually)
#
# Env:
#   CONFIG            path to the JSON config, relative to the repo root; the workflow passes
#                     .github/release-configs/<project>.json (file name must match its "project" key)
#   MILESTONE_BRANCH  branch to cut RC0 from (required for "rc"; each release has its own)
#   DRY_RUN           "true" prints the commands that change the remote instead of running them
#   GH_TOKEN + GITHUB_REPOSITORY  (set in Actions) enable the GitHub branch-rename API
#                     and GitHub Releases.
#
# Naming (with project "pos-cr", tag_prefix "v"):
#   RC branch       pos-cr-1.4.0-RC0, pos-cr-1.4.0-RC1, ...
#   release branch  pos-cr-1.4.0-release   (the RC branch, renamed on promote)
#   RC tag          pos-cr-v1.4.0-RC0, pos-cr-v1.4.0-RC1, ...
#   final tag       pos-cr-v1.4.0
# Tags carry the prefix so a tag never has the same name as a branch (git treats that as ambiguous).
set -euo pipefail

CONFIG="${CONFIG:?CONFIG must point to a release config, e.g. .github/release-configs/uprint.json}"
CONFIG="${CONFIG#./}"
DRY_RUN="${DRY_RUN:-false}"
ACTION="${1:-}"
ARG="${2:-}"

die()  { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*" >&2; }
note() { echo "==> $*"; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }
run() {
  if [[ "$DRY_RUN" == "true" ]]; then echo "[dry-run] $*"; else "$@"; fi
}

# ---------- config ----------
if [[ ! -f "$CONFIG" ]]; then
  cfg_dir="$(dirname "$CONFIG")"
  available="$(cd "$cfg_dir" 2>/dev/null && ls -1 -- *.json 2>/dev/null | sed 's/\.json$//' | paste -sd, - || true)"
  die "config file not found: $CONFIG (configs in $cfg_dir: ${available:-none}). Add the file, or fix the project list in release.yml"
fi
read_key() { # read_key <key> [default]   reads JSON from stdin; empty default + missing key = error
  node -e '
    const c = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const v = c[process.argv[1]];
    if (v === undefined || v === null || v === "") {
      if (process.argv.length > 2) { console.log(process.argv[2]); process.exit(0); }
      console.error("missing config key: " + process.argv[1]); process.exit(1);
    }
    console.log(v);' "$@"
}
cfg() { read_key "$@" < "$CONFIG"; }

PROJECT="$(cfg project)"
FINAL="$(cfg final_branch)"
TAG_PREFIX="$(cfg tag_prefix v)"
GH_RELEASE="$(cfg github_release false)"
MILESTONE="${MILESTONE_BRANCH:-}"

[[ "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]] || die "project must match [A-Za-z0-9._-]+: $PROJECT"
[[ "$(basename "$CONFIG" .json)" == "$PROJECT" ]] \
  || die "$CONFIG has \"project\": \"$PROJECT\"; the file must be named $PROJECT.json"
# A non-empty prefix keeps tag names (pos-cr-v1.4.0) different from branch names (pos-cr-1.4.0-...).
[[ "$TAG_PREFIX" =~ ^[A-Za-z._-]+$ ]] || die "tag_prefix must be letters/._- (got '$TAG_PREFIX')"

is_semver()     { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
branch_name()   { echo "${PROJECT}-$1-RC$2"; }             # version rc
release_branch(){ echo "${PROJECT}-$1-release"; }          # version
rc_tag()        { echo "${PROJECT}-${TAG_PREFIX}$1-RC$2"; } # version rc
release_tag()   { echo "${PROJECT}-${TAG_PREFIX}$1"; }      # version

# ---------- remote state ----------
note "Fetching branches and tags"
git fetch --quiet --prune --prune-tags --tags origin "+refs/heads/*:refs/remotes/origin/*"

remote_branch_exists() { git show-ref --verify --quiet "refs/remotes/origin/$1"; }
tag_exists()           { git show-ref --verify --quiet "refs/tags/$1"; }

latest_release_tag_version() { # highest X.Y.Z that has a final tag
  local t v all=""
  while read -r t; do
    v="${t#"${PROJECT}-${TAG_PREFIX}"}"
    is_semver "$v" && all+="$v"$'\n'
  done < <(git tag -l "${PROJECT}-${TAG_PREFIX}*")
  printf '%s' "$all" | sort -V | tail -n1
}

version_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }

bump() { # bump <X.Y.Z> <major|minor|patch>
  local ma mi pa
  IFS=. read -r ma mi pa <<< "$1"
  case "$2" in
    major) echo "$((ma + 1)).0.0" ;;
    minor) echo "${ma}.$((mi + 1)).0" ;;
    patch) echo "${ma}.${mi}.$((pa + 1))" ;;
    *) die "bump must be major, minor or patch (got '$2')" ;;
  esac
}

# Sets RC_BRANCH / RC_VERSION / RC_NUM to the open RC branch, and STALE_RCS to older RC branches
# of the same version (e.g. RC0 pushed again from a clone that missed the rename to RC1).
# "Open" = matches <project>-X.Y.Z-RC<n> and X.Y.Z has no final tag yet.
# The highest RC number wins; a stale branch with commits the winner lacks is an error, so that
# work is never silently left out of a release.
find_open_rc() {
  local want="${1:-}" b rest versions=() lines=() v n
  while read -r b; do
    rest="${b#"${PROJECT}-"}"
    [[ "$rest" != "$b" && "$rest" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-RC([0-9]+)$ ]] || continue
    v="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
    tag_exists "$(release_tag "$v")" && continue
    [[ -z "$want" || "$want" == "$v" ]] || continue
    lines+=("$v $n $b")
    [[ " ${versions[*]} " == *" $v "* ]] || versions+=("$v")
  done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin)

  if (( ${#versions[@]} == 0 )); then
    die "no open RC branch for ${PROJECT}${want:+ version $want}"
  elif (( ${#versions[@]} > 1 )); then
    die "RCs open for several versions (${versions[*]}); pass the version to pick one"
  fi

  # Highest RC number first.
  mapfile -t lines < <(printf '%s\n' "${lines[@]}" | sort -k2,2nr)
  read -r RC_VERSION RC_NUM RC_BRANCH <<< "${lines[0]}"

  STALE_RCS=()
  local stale missing=""
  for stale in "${lines[@]:1}"; do
    b="${stale##* }"
    if [[ -n "$(git rev-list -n1 "refs/remotes/origin/$RC_BRANCH..refs/remotes/origin/$b")" ]]; then
      missing+=$'\n'"  $b:"$'\n'"$(git log --format='    %h %an: %s' "refs/remotes/origin/$RC_BRANCH..refs/remotes/origin/$b")"
    else
      STALE_RCS+=("$b")
    fi
  done
  if [[ -n "$missing" ]]; then
    die "$RC_BRANCH is the current RC, but older RC branches have commits it does not contain:${missing}
Cherry-pick or merge them into $RC_BRANCH (or delete those branches), then run again."
  fi
  if (( ${#STALE_RCS[@]} )); then
    note "Stale RC branches (fully contained in $RC_BRANCH, will be deleted): ${STALE_RCS[*]}"
  fi
}

delete_stale_rcs() {
  local b
  for b in "${STALE_RCS[@]}"; do run git push origin ":refs/heads/$b"; done
  if (( ${#STALE_RCS[@]} )); then
    summary "| Stale RC branches deleted | $(printf '`%s` ' "${STALE_RCS[@]}")|"
  fi
}

# Tell developers how to point their local clone at the renamed branch; a plain `git push`
# from the old local branch would otherwise create the old name on GitHub again.
rename_help() { # rename_help <old> <new>
  local cmds="git fetch --prune
git branch -m $1 $2
git branch -u origin/$2"
  note "Branch renamed. Anyone with '$1' checked out should run:"$'\n'"$cmds"
  summary ""
  summary "> **Branch renamed.** If you have \`$1\` locally, update it before pushing again,"
  summary "> otherwise \`git push\` recreates \`$1\` on GitHub:"
  summary ""
  summary '```bash'
  summary "$cmds"
  summary '```'
}

push_tag() { # push_tag <tag> <sha> <message>
  run git tag -a "$1" "$2" -m "$3"
  run git push origin "refs/tags/$1"
}

gh_available() { [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] && command -v gh >/dev/null; }

github_release() { # github_release <tag> <prerelease true|false>
  [[ "$GH_RELEASE" == "true" ]] || return 0
  if ! gh_available; then note "Skipping GitHub Release (no gh / GH_TOKEN)"; return 0; fi
  local flags=(--title "$1" --generate-notes --verify-tag)
  [[ "$2" == "true" ]] && flags+=(--prerelease)
  run gh release create "$1" "${flags[@]}"
}

rename_branch() { # rename_branch <old> <new>
  if gh_available; then
    # GitHub's rename keeps open PRs and branch protection pointed at the branch.
    run gh api -X POST "repos/${GITHUB_REPOSITORY}/branches/$1/rename" -f new_name="$2" --silent
  else
    run git push --atomic origin "refs/remotes/origin/$1:refs/heads/$2" ":refs/heads/$1"
  fi
}

# ---------- actions ----------
case "$ACTION" in
  rc)
    [[ -n "$ARG" ]] || die "usage: release.sh rc <major|minor|patch>"
    [[ -n "$MILESTONE" ]] || die "milestone branch is required for 'rc' (MILESTONE_BRANCH)"
    remote_branch_exists "$MILESTONE" || die "milestone branch '$MILESTONE' not found on origin"

    # Base version = "version" in the config as it is on the milestone branch (the code being released).
    ms_config="$(git show "refs/remotes/origin/$MILESTONE:$CONFIG" 2>/dev/null)" \
      || die "$CONFIG not found on $MILESTONE"
    base="$(read_key version <<< "$ms_config")" || die "\"version\" missing from $CONFIG on $MILESTONE"
    is_semver "$base" || die "\"version\" in $CONFIG on $MILESTONE must be X.Y.Z (got '$base')"

    # Safety net: another release may have been promoted but its PR not merged yet.
    tagged="$(latest_release_tag_version)"
    if [[ -n "$tagged" ]] && version_gt "$tagged" "$base"; then
      warn "$CONFIG on $MILESTONE says $base but $(release_tag "$tagged") exists; using $tagged as the base (is that release PR merged?)"
      base="$tagged"
    fi

    version="$(bump "$base" "$ARG")"
    branch="$(branch_name "$version" 0)"
    tag="$(rc_tag "$version" 0)"
    sha="$(git rev-parse "refs/remotes/origin/$MILESTONE")"

    tag_exists "$(release_tag "$version")" && die "$version is already released"
    tag_exists "$tag" && die "tag $tag already exists"
    for b in $(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/origin/${PROJECT}-${version}-RC*"); do
      die "an RC branch for $version already exists: $b (use 'fix' or 'promote')"
    done

    note "$PROJECT $base -> $version ($ARG); $MILESTONE @ ${sha:0:9}"
    run git push origin "$sha:refs/heads/$branch"
    # The "milestone:" line is read back by promote to clean up the milestone branch.
    push_tag "$tag" "$sha" "$PROJECT $version release candidate 0"$'\n\n'"milestone: $MILESTONE"
    github_release "$tag" true

    summary "### Release candidate created"
    summary "| | |"$'\n'"|---|---|"
    summary "| Version | \`$base\` → \`$version\` ($ARG) |"
    summary "| Branch | \`$branch\` (from \`$MILESTONE\`) |"
    summary "| Tag | \`$tag\` → \`${sha:0:9}\` |"
    ;;

  fix)
    find_open_rc "$ARG"
    sha="$(git rev-parse "refs/remotes/origin/$RC_BRANCH")"
    prev_tag="$(rc_tag "$RC_VERSION" "$RC_NUM")"
    if tag_exists "$prev_tag" && [[ "$(git rev-list -n1 "$prev_tag")" == "$sha" ]]; then
      die "$RC_BRANCH has no commits since $prev_tag; push the fixes to it first"
    fi

    next=$((RC_NUM + 1))
    new_branch="$(branch_name "$RC_VERSION" "$next")"
    tag="$(rc_tag "$RC_VERSION" "$next")"
    tag_exists "$tag" && die "tag $tag already exists"

    note "$RC_BRANCH @ ${sha:0:9} -> $new_branch"
    push_tag "$tag" "$sha" "$PROJECT $RC_VERSION release candidate $next"
    rename_branch "$RC_BRANCH" "$new_branch"
    github_release "$tag" true

    summary "### Release candidate updated"
    summary "| | |"$'\n'"|---|---|"
    summary "| Branch | \`$RC_BRANCH\` → \`$new_branch\` |"
    summary "| Tag | \`$tag\` → \`${sha:0:9}\` |"
    summary "| Fixes | $(git rev-list --count "$prev_tag..$sha" 2>/dev/null || echo '?') commit(s) since \`$prev_tag\` |"
    delete_stale_rcs
    rename_help "$RC_BRANCH" "$new_branch"
    ;;

  promote)
    find_open_rc "$ARG"
    sha="$(git rev-parse "refs/remotes/origin/$RC_BRANCH")"
    last_rc_tag="$(rc_tag "$RC_VERSION" "$RC_NUM")"
    tag_exists "$last_rc_tag" || die "missing tag $last_rc_tag"
    [[ "$(git rev-list -n1 "$last_rc_tag")" == "$sha" ]] \
      || die "$RC_BRANCH has commits not in $last_rc_tag; cut a new RC with 'fix' before promoting"
    remote_branch_exists "$FINAL" || die "final branch '$FINAL' not found on origin"
    git cat-file -e "$sha:$CONFIG" 2>/dev/null || die "$CONFIG not found on $RC_BRANCH"

    tag="$(release_tag "$RC_VERSION")"
    rel_branch="$(release_branch "$RC_VERSION")"
    remote_branch_exists "$rel_branch" && die "branch $rel_branch already exists"

    note "Promoting $last_rc_tag (${sha:0:9}) -> $tag; $RC_BRANCH -> $rel_branch"
    # 1. Final tag on the exact commit that was tested as the last RC.
    push_tag "$tag" "$sha" "$PROJECT $RC_VERSION release (promoted from $last_rc_tag)"
    rename_branch "$RC_BRANCH" "$rel_branch"

    # 2. Record the released version in the config, on top of the release branch.
    #    It reaches the final branch through the (manual) release PR.
    note "Setting \"version\": \"$RC_VERSION\" in $CONFIG on $rel_branch"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] commit $CONFIG version=$RC_VERSION on $rel_branch and push"
    else
      git checkout --quiet --detach "$sha"
      node -e '
        const fs = require("fs"), [file, ver] = process.argv.slice(1);
        const c = JSON.parse(fs.readFileSync(file, "utf8"));
        c.version = ver;
        fs.writeFileSync(file, JSON.stringify(c, null, 2) + "\n");' "$CONFIG" "$RC_VERSION"
      git commit --quiet -m "Release $tag: set $PROJECT version to $RC_VERSION" -- "$CONFIG"
      git push origin "HEAD:refs/heads/$rel_branch"
    fi
    github_release "$tag" false

    # 3. Delete the milestone branch the RC was cut from, if nothing on it would be lost.
    milestone="$(git tag -l --format='%(contents)' "$(rc_tag "$RC_VERSION" 0)" | sed -n 's/^milestone: //p' | head -n1)"
    if [[ -z "$milestone" ]]; then
      ms_result="unknown (no \`milestone:\` line in the RC0 tag); not deleted"
    elif [[ "$milestone" == "$FINAL" ]]; then
      ms_result="\`$milestone\` is the final branch; not deleted"
    elif ! remote_branch_exists "$milestone"; then
      ms_result="\`$milestone\` already gone"
    elif git merge-base --is-ancestor "refs/remotes/origin/$milestone" "$sha"; then
      run git push origin ":refs/heads/$milestone"
      ms_result="\`$milestone\` deleted (fully contained in the release)"
    else
      extra="$(git rev-list --count "$sha..refs/remotes/origin/$milestone")"
      warn "$milestone has $extra commit(s) not in the release; not deleting it"
      ms_result="\`$milestone\` **kept**: $extra commit(s) not in the release"
    fi
    note "Milestone: $ms_result"

    pr_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-<owner>/<repo>}/compare/${FINAL}...${rel_branch}?expand=1"
    note "Open the PR manually: $pr_url"

    summary "### Release promoted"
    summary "| | |"$'\n'"|---|---|"
    summary "| Tag | \`$tag\` → \`${sha:0:9}\` (same commit as \`$last_rc_tag\`) |"
    summary "| Branch | \`$RC_BRANCH\` → \`$rel_branch\` (+ commit setting \`version\` to \`$RC_VERSION\`) |"
    summary "| Milestone | $ms_result |"
    delete_stale_rcs
    summary "| Next step | [Open PR \`$rel_branch\` → \`$FINAL\`]($pr_url) and use the milestone ticket as the description |"
    rename_help "$RC_BRANCH" "$rel_branch"
    ;;

  *)
    die "usage: release.sh <rc <major|minor|patch> | fix [version] | promote [version]>"
    ;;
esac
note "Done"
