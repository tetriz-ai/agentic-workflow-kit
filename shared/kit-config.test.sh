#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests the settings resolution order of kit-config.sh, in shared/ and in every plugin's copy:
# an explicit value (unless empty or a literal "${user_config.<key>}"), then
# CLAUDE_PLUGIN_OPTION_<KEY>, then AGENTIC_KIT_<KEY>, then .agentic-workflow-kit.json at the repo
# root, then the default in the copy's own plugin.json.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; git init -q "$REPO"
printf '{"base_branch":"from-file"}\n' > "$REPO/.agentic-workflow-kit.json"
NOFILE="$TMP/nofile"; git init -q "$NOFILE"

# resolve <copy> <dir> <explicit> <option> <kit env>: the value kit_config base_branch gives.
resolve() {
  (cd "$2" && env -u CLAUDE_PLUGIN_OPTION_BASE_BRANCH -u AGENTIC_KIT_BASE_BRANCH \
     ${4:+CLAUDE_PLUGIN_OPTION_BASE_BRANCH="$4"} ${5:+AGENTIC_KIT_BASE_BRANCH="$5"} \
     bash -c '. "$1"; kit_config base_branch "$2"' _ "$1" "$3")
}

# Rows: name | dir (REPO or NOFILE) | explicit | plugin option | AGENTIC_KIT_ | want
# shellcheck disable=SC2016
CASES=(
  'an explicit value wins|REPO|explicit|option|env|explicit'
  'a literal ${user_config.x} counts as empty|REPO|${user_config.base_branch}|option|env|option'
  'the plugin option beats AGENTIC_KIT_|REPO||option|env|option'
  'AGENTIC_KIT_ beats the repo file|REPO|||env|env'
  'the repo file beats the default|REPO||||from-file'
)
copies=("$KIT/shared/kit-config.sh")
while IFS= read -r c; do copies+=("$c"); done < <(find "$KIT/plugins" -name kit-config.sh -path '*/scripts/*' | sort)
for copy in "${copies[@]}"; do
  rel=${copy#"$KIT"/}
  for row in "${CASES[@]}"; do
    IFS='|' read -r name dir explicit option kitenv want <<<"$row"
    if [ "$dir" = REPO ]; then d=$REPO; else d=$NOFILE; fi
    got=$(resolve "$copy" "$d" "$explicit" "$option" "$kitenv")
    if [ "$got" = "$want" ]; then ok "$rel: $name"; else bad "$rel: $name (got [$got], want [$want])"; fi
  done
  # With nothing set, the copy's own plugin.json default applies (blank when it declares none).
  manifest="$(cd "$(dirname "$copy")/.." && pwd)/.claude-plugin/plugin.json"
  want=""; [ -f "$manifest" ] && want=$(jq -r '.userConfig.base_branch.default // empty' "$manifest")
  got=$(resolve "$copy" "$NOFILE" "" "" "")
  if [ "$got" = "$want" ]; then ok "$rel: the plugin default applies last ([$want])"; else bad "$rel: plugin default (got [$got], want [$want])"; fi
done

# Credential destinations must never come from a reviewed repository.
printf '{"ocr_gateways":[{"name":"untrusted","url":"https://untrusted.example"}]}\n' > "$REPO/.agentic-workflow-kit.json"
for copy in "${copies[@]}"; do
  got=$(cd "$REPO" && env -u CLAUDE_PLUGIN_OPTION_OCR_GATEWAYS -u AGENTIC_KIT_OCR_GATEWAYS bash "$copy" get ocr_gateways)
  trusted=$(cd "$REPO" && AGENTIC_KIT_OCR_GATEWAYS='[{"name":"trusted"}]' bash "$copy" get ocr_gateways)
  [ "$trusted" = '[{"name":"trusted"}]' ] && ok "${copy#"$KIT"/}: user OCR environment wins" || bad "${copy#"$KIT"/}: user OCR environment lost"
  case "$got" in ''|'[]') ok "${copy#"$KIT"/}: ignores repository OCR gateways" ;; *) bad "${copy#"$KIT"/}: accepts repository OCR gateways" ;; esac
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
