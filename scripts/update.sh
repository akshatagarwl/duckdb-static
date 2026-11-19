#!/usr/bin/env bash
# Regenerate sources.json for a DuckDB release: the latest one by default.
#
# The out-of-tree extensions are the ones already in sources.json. Their
# commits are never chosen here: they are read from the release's own
# .github/config/extensions/<name>.cmake, i.e. exactly what DuckDB built and
# tested that release with. Submodules an extension's config asks for are
# pinned too, except DuckDB itself and its CI tooling, which a build inside the
# DuckDB tree does not use.
#
# Usage: scripts/update.sh [vX.Y.Z]    FORCE=1 rewrites even when current.
# Needs curl, jq and nix. GITHUB_TOKEN, if set, avoids API rate limits.
set -euo pipefail
cd "$(dirname "$0")/.."

api() {
  curl -fsSL --retry 3 ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}
prefetch() { # owner/repo rev
  nix store prefetch-file --json --unpack "https://github.com/$1/archive/$2.tar.gz" | jq -r .hash
}

tag="${1:-$(api repos/duckdb/duckdb/releases/latest | jq -r .tag_name)}"
version="${tag#v}"
current="$(jq -r .duckdb.version sources.json)"
if [[ "$version" == "$current" && "${FORCE:-}" != 1 ]]; then
  echo "DuckDB $current is current"
  exit 0
fi

rev="$(api "repos/duckdb/duckdb/commits/$tag" | jq -r .sha)"
echo "DuckDB $tag = $rev"
json="$(jq -n --arg version "$version" --arg rev "$rev" --arg hash "$(prefetch duckdb/duckdb "$rev")" \
  '{duckdb: {version: $version, rev: $rev, hash: $hash}, extensions: {}}')"

for name in $(jq -r '.extensions | keys[]' sources.json); do
  cfg="$(curl -fsSL "https://raw.githubusercontent.com/duckdb/duckdb/$rev/.github/config/extensions/$name.cmake")" || {
    echo "DuckDB $tag has no .github/config/extensions/$name.cmake" >&2
    exit 1
  }
  url="$(grep -oP 'GIT_URL\s+\K\S+' <<<"$cfg")"
  ext_rev="$(grep -oP 'GIT_TAG\s+\K\S+' <<<"$cfg")"
  repo="${url#https://github.com/}"
  repo="${repo%.git}"
  echo "  $name: $repo @ $ext_rev"
  entry="$(jq -n --arg owner "${repo%%/*}" --arg repo "${repo#*/}" --arg rev "$ext_rev" \
    --arg hash "$(prefetch "$repo" "$ext_rev")" '{owner: $owner, repo: $repo, rev: $rev, hash: $hash}')"

  for sub in $(grep -oP 'SUBMODULES\s+\K[^)]+' <<<"$cfg" | tr ';' ' ' || true); do
    case "$sub" in duckdb | extension-ci-tools) continue ;; esac
    info="$(api "repos/$repo/contents/$sub?ref=$ext_rev")"
    sub_rev="$(jq -r .sha <<<"$info")"
    sub_repo="$(jq -r .submodule_git_url <<<"$info")"
    sub_repo="${sub_repo#https://github.com/}"
    sub_repo="${sub_repo%.git}"
    echo "    submodule $sub: $sub_repo @ $sub_rev"
    entry="$(jq --arg path "$sub" --arg owner "${sub_repo%%/*}" --arg repo "${sub_repo#*/}" --arg rev "$sub_rev" \
      --arg hash "$(prefetch "$sub_repo" "$sub_rev")" \
      '.submodules[$path] = {owner: $owner, repo: $repo, rev: $rev, hash: $hash}' <<<"$entry")"
  done

  json="$(jq --arg name "$name" --argjson entry "$entry" '.extensions[$name] = $entry' <<<"$json")"
done

jq . <<<"$json" >sources.json
echo "DuckDB $current -> $version"
