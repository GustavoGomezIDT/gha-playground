#!/usr/bin/env bash
# Release-candidate / promote helper.
#
#   release.sh rc      <major|minor|patch>   new RC0 branch from $MILESTONE_BRANCH
#   release.sh fix     [version]             tag current RC branch head as RC<n+1> and rename the branch
#   release.sh promote [version]             tag final release on the last RC commit
#                                            (the PR into the final branch is opened manually)
#
# Env:
#   CONFIG            path to the JSON config (default .github/release-config.json)
#   MILESTONE_BRANCH  branch to cut RC0 from (required for "rc"; each release has its own)
#   DRY_RUN           "true" prints the git commands that change the remote instead of running them
#   GH_TOKEN + GITHUB_REPOSITORY  (set in Actions) enable the GitHub branch-rename API
#                     and GitHub Releases.
#
# Naming (with project "pos-cr", tag_prefix "v"):
#   branch      pos-cr-1.4.0-RC0, pos-cr-1.4.0-RC1, ...
#   RC tag      pos-cr-v1.4.0-RC0, pos-cr-v1.4.0-RC1, ...
#   final tag   pos-cr-v1.4.0
# Tags carry the prefix so a tag never has the same name as a branch (git treats that as ambiguous).
set -euo pipefail

CONFIG="${CONFIG:-.github/release-config.json}"
DRY_RUN="${DRY_RUN:-false}"
ACTION="${1:-}"
ARG="${2:-}"

die()  { echo "::error::$*" >&2; exit 1; }
note() { echo "==> $*"; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }
run() {
  if [[ "$DRY_RUN" == "true" ]]; then echo "[dry-run] $*"; else "$@"; fi
}

# ---------- config ----------
[[ -f "$CONFIG" ]] || die "config file not found: $CONFIG"
cfg() { # cfg <key> [default]   (empty default + missing key = error)
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const v = c[process.argv[2]];
    if (v === undefined || v === null || v === "") {
      if (process.argv.length > 3) { console.log(process.argv[3]); process.exit(0); }
      console.error("missing config key: " + process.argv[2]); process.exit(1);
    }
    console.log(v);' "$CONFIG" "$@"
}
PROJECT="$(cfg project)"
FINAL="$(cfg final_branch)"
TAG_PREFIX="$(cfg tag_prefix v)"
INITIAL="$(cfg initial_version 0.0.0)"
GH_RELEASE="$(cfg github_release false)"
MILESTONE="${MILESTONE_BRANCH:-}"

[[ "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]]        || die "project must match [A-Za-z0-9._-]+: $PROJECT"
[[ "$INITIAL" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "initial_version must be X.Y.Z: $INITIAL"

branch_name()   { echo "${PROJECT}-$1-RC$2"; }             # version rc
rc_tag()        { echo "${PROJECT}-${TAG_PREFIX}$1-RC$2"; } # version rc
release_tag()   { echo "${PROJECT}-${TAG_PREFIX}$1"; }      # version

# ---------- remote state ----------
note "Fetching branches and tags"
git fetch --quiet --prune --prune-tags --tags origin "+refs/heads/*:refs/remotes/origin/*"

remote_branch_exists() { git show-ref --verify --quiet "refs/remotes/origin/$1"; }
tag_exists()           { git show-ref --verify --quiet "refs/tags/$1"; }

latest_release() { # highest X.Y.Z that has a final tag
  local t v best=""
  while read -r t; do
    v="${t#"${PROJECT}-${TAG_PREFIX}"}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && best+="$v"$'\n'
  done < <(git tag -l "${PROJECT}-${TAG_PREFIX}*")
  printf '%s' "$best" | sort -V | tail -n1
}

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

# Sets RC_BRANCH / RC_VERSION / RC_NUM to the open RC branch.
# "Open" = matches <project>-X.Y.Z-RC<n> and X.Y.Z has no final tag yet.
find_open_rc() {
  local want="${1:-}" b rest matches=()
  while read -r b; do
    rest="${b#"${PROJECT}-"}"
    [[ "$rest" != "$b" && "$rest" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-RC([0-9]+)$ ]] || continue
    tag_exists "$(release_tag "${BASH_REMATCH[1]}")" && continue
    [[ -z "$want" || "$want" == "${BASH_REMATCH[1]}" ]] || continue
    matches+=("$b")
  done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin)

  if (( ${#matches[@]} == 0 )); then
    die "no open RC branch for ${PROJECT}${want:+ version $want}"
  elif (( ${#matches[@]} > 1 )); then
    die "several open RC branches (${matches[*]}); pass the version to pick one"
  fi
  RC_BRANCH="${matches[0]}"
  rest="${RC_BRANCH#"${PROJECT}-"}"
  [[ "$rest" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-RC([0-9]+)$ ]]
  RC_VERSION="${BASH_REMATCH[1]}"
  RC_NUM="${BASH_REMATCH[2]}"
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

    base="$(latest_release)"; base="${base:-$INITIAL}"
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
    push_tag "$tag" "$sha" "$PROJECT $version release candidate 0 (from $MILESTONE)"
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
    ;;

  promote)
    find_open_rc "$ARG"
    sha="$(git rev-parse "refs/remotes/origin/$RC_BRANCH")"
    last_rc_tag="$(rc_tag "$RC_VERSION" "$RC_NUM")"
    tag_exists "$last_rc_tag" || die "missing tag $last_rc_tag"
    [[ "$(git rev-list -n1 "$last_rc_tag")" == "$sha" ]] \
      || die "$RC_BRANCH has commits not in $last_rc_tag; cut a new RC with 'fix' before promoting"
    remote_branch_exists "$FINAL" || die "final branch '$FINAL' not found on origin"

    tag="$(release_tag "$RC_VERSION")"
    note "Promoting $last_rc_tag (${sha:0:9}) -> $tag"
    push_tag "$tag" "$sha" "$PROJECT $RC_VERSION release (promoted from $last_rc_tag)"
    github_release "$tag" false

    pr_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-<owner>/<repo>}/compare/${FINAL}...${RC_BRANCH}?expand=1"
    note "Open the PR manually: $pr_url"

    summary "### Release promoted"
    summary "| | |"$'\n'"|---|---|"
    summary "| Tag | \`$tag\` → \`${sha:0:9}\` (same commit as \`$last_rc_tag\`) |"
    summary "| Next step | [Open PR \`$RC_BRANCH\` → \`$FINAL\`]($pr_url) and use the milestone ticket as the description |"
    ;;

  *)
    die "usage: release.sh <rc <major|minor|patch> | fix [version] | promote [version]>"
    ;;
esac
note "Done"
