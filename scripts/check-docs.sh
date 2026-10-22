#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Keeps the kit's manifests and prose honest. Checks, each reported by name:
#   skills       every SKILL.md has YAML frontmatter that parses, a name equal to its folder, and
#                a description of at most 1,536 characters (Claude Code's cap)
#   links        every relative Markdown link outside a code fence resolves to a file or folder
#   skill-refs   every /<plugin>:<skill> reference names a skill that exists, and no bare
#                /<skill> names a shipped skill (scripts/check-skill-refs.sh)
#   marketplace  both marketplaces list exactly the plugin folders (Codex: all but `all`), with
#                the plugins' own names and versions, and `all` depends on every other plugin
#   settings     each plugin's userConfig matches files/settings.json and docs/settings.md, and a
#                key shared by several plugins is declared the same way in each
#   hooks        every hook command points at an executable script in its plugin
#   openai-yaml  every agents/openai.yaml parses and turns implicit invocation off
#   skill-list   the docs-health check's list of kit skills (_LIB_KIT_SKILLS in
#                plugins/guards/scripts/lib/check-docs-md.sh) equals the kit's skill folders
#   examples     examples/README.md lists exactly the folders under examples/, and the README's
#                run-examples output block equals a real scripts/run-examples.sh run
#   headers      every script outside examples/ (*.sh, *.py, *.jq, the starter githooks) has the
#                copyright line and the SPDX licence line in its first five lines
# Needs jq, mikefarah's yq and python3. Exit 1 when any check fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
for t in jq yq python3; do command -v "$t" >/dev/null 2>&1 || { echo "check-docs: $t is required" >&2; exit 2; }; done
problems=0
bad() { echo "  FAIL [$1] $2"; problems=$((problems + 1)); }
section() { echo "== $1"; }
frontmatter() { awk 'NR == 1 && $0 != "---" { exit } NR == 1 { next } $0 == "---" { exit } { print }' "$1"; }
plugins() { find plugins -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort; }

section skills
for f in plugins/*/skills/*/SKILL.md; do
  fm="$(frontmatter "$f")"
  [ -n "$fm" ] || { bad skills "$f has no frontmatter"; continue; }
  json="$(printf '%s\n' "$fm" | yq -o json . 2>/dev/null)" || { bad skills "$f frontmatter is not valid YAML"; continue; }
  name="$(printf '%s' "$json" | jq -r '.name // empty')"
  [ "$name" = "$(basename "$(dirname "$f")")" ] || bad skills "$f name '$name' is not its folder name"
  len="$(printf '%s' "$json" | jq -r '((.description // "") + (.when_to_use // "")) | length')"
  [ "$len" -gt 0 ] && [ "$len" -le 1536 ] || bad skills "$f description is $len characters (1 to 1536)"
done

section links
while IFS= read -r f; do
  dir="$(dirname "$f")"
  while IFS= read -r link; do
    target="${link%%#*}"; [ -n "$target" ] || continue
    case "$target" in http://*|https://*|mailto:*|/*|\<*) continue ;; esac
    [ -e "$dir/$target" ] || bad links "$f -> $link"
  done < <(awk '/^[ \t]*```/ { fence = !fence; next } !fence' "$f" | grep -oE '\]\([^)[:space:]]+\)' | sed -E 's/^\]\(//; s/\)$//')
done < <(find . -name '*.md' -not -path './.git/*' -not -path './node_modules/*' | sort)

section skill-refs
known="$(for p in $(plugins); do for s in plugins/"$p"/skills/*/; do [ -d "$s" ] && echo "$p:$(basename "$s")"; done; done)"
alts="$(plugins | tr '\n' '|' | sed 's/|$//')"
while IFS= read -r hit; do
  file="${hit%%:/*}"; ref="${hit#*:/}"
  printf '%s\n' "$known" | grep -qx "$ref" || bad skill-refs "$file names /$ref, which does not exist"
done < <(grep -rHoE --include='*.md' --include='*.json' --include='*.sh' --exclude-dir=.git "/($alts):[a-z][a-z0-9-]*" . 2>/dev/null | sort -u)
# A bare /<skill> naming a shipped skill, which Claude Code cannot invoke (check-skill-refs.sh).
while IFS= read -r hit; do bad skill-refs "$hit"; done < <(bash scripts/check-skill-refs.sh . 2>&1)

section marketplace
dirs="$(plugins | tr '\n' ' ')"
cm="$(jq -r '[.plugins[].name] | sort | join(" ")' .claude-plugin/marketplace.json)"
[ "$cm " = "$dirs" ] || bad marketplace "Claude marketplace lists [$cm], plugin folders are [$dirs]"
# `all` is the bundle: it depends on every other plugin, by design.
deps="$(jq -r '[.dependencies[]?] | sort | join(" ")' plugins/all/.claude-plugin/plugin.json)"
[ "$deps " = "$(plugins | grep -vx all | tr '\n' ' ')" ] || bad marketplace "plugins/all depends on [$deps], want every other plugin"
xm="$(jq -r '[.plugins[].name] | sort | join(" ")' .agents/plugins/marketplace.json)"
[ "$xm " = "$(plugins | grep -vx all | tr '\n' ' ')" ] || bad marketplace "Codex marketplace lists [$xm], want every folder but all"
for p in $(plugins); do
  v="$(jq -r '.version' "plugins/$p/.claude-plugin/plugin.json")"
  [ "$(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .source' .claude-plugin/marketplace.json)" = "./plugins/$p" ] || bad marketplace "$p source is not ./plugins/$p"
  [ "$(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .version' .claude-plugin/marketplace.json)" = "$v" ] || bad marketplace "$p version differs from its plugin.json ($v)"
  [ "$(jq -r '.name' "plugins/$p/.claude-plugin/plugin.json")" = "$p" ] || bad marketplace "plugins/$p/.claude-plugin/plugin.json name is not $p"
  [ "$p" = all ] && continue
  cx="plugins/$p/.codex-plugin/plugin.json"
  [ -f "$cx" ] || { bad marketplace "$cx is missing"; continue; }
  [ "$(jq -r '.name + " " + .version' "$cx")" = "$p $v" ] || bad marketplace "$cx name or version differs from the Claude manifest"
  jq -e --arg p "$p" '.plugins[] | select(.name == $p) | .policy.installation and .policy.authentication and .category' .agents/plugins/marketplace.json >/dev/null || bad marketplace "Codex entry $p lacks policy or category"
done

section settings
for p in $(plugins); do
  m="plugins/$p/.claude-plugin/plugin.json"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    jq -e --arg k "$k" 'has($k)' plugins/starter/files/settings.json >/dev/null || { bad settings "$p declares $k, missing from plugins/starter/files/settings.json"; continue; }
    [ "$(jq -c --arg k "$k" '.userConfig[$k] | [.type, .default, .description]' "$m")" = "$(jq -c --arg k "$k" '.[$k] | [.type, .default, .description]' plugins/starter/files/settings.json)" ] \
      || bad settings "$p declares $k differently from the shared definition"
    jq -e --arg k "$k" --arg p "$p" '.[$k].plugins | index($p) != null' plugins/starter/files/settings.json >/dev/null || bad settings "$k does not list $p among its plugins"
    grep -q "^| \`$k\` |" docs/settings.md || bad settings "$k is missing from docs/settings.md"
  done < <(jq -r '.userConfig // {} | keys[]' "$m")
done
while IFS= read -r k; do
  for p in $(jq -r --arg k "$k" '.[$k].plugins[]' plugins/starter/files/settings.json); do
    jq -e --arg k "$k" '.userConfig[$k]' "plugins/$p/.claude-plugin/plugin.json" >/dev/null 2>&1 || bad settings "$k lists $p, whose plugin.json does not declare it"
  done
done < <(jq -r 'keys[]' plugins/starter/files/settings.json)

section hooks
for h in plugins/*/hooks/hooks.json; do
  p="$(basename "$(dirname "$(dirname "$h")")")"
  while IFS= read -r c; do
    s="${c#*\"\$\{CLAUDE_PLUGIN_ROOT\}\"/}"
    [ "$s" != "$c" ] || { bad hooks "$h command does not start with \"\${CLAUDE_PLUGIN_ROOT}\"/: $c"; continue; }
    exe="${s%% *}"; arg=""; [ "$exe" = "$s" ] || arg="${s#* }"
    [ -x "plugins/$p/$exe" ] || { bad hooks "$h runs $exe, which is not an executable file in plugins/$p"; continue; }
    # hook-once.sh runs the script named after it, from its own folder.
    if [ "${exe##*/}" = hook-once.sh ]; then
      [ -n "$arg" ] && [ -x "plugins/$p/$(dirname "$exe")/$arg" ] \
        || bad hooks "$h runs hook-once.sh with [$arg], which is not an executable file beside it in plugins/$p"
    fi
  done < <(jq -r '.hooks[][].hooks[].command' "$h")
done

section openai-yaml
for y in plugins/*/skills/*/agents/openai.yaml; do
  yq -o json . "$y" >/dev/null 2>&1 || { bad openai-yaml "$y is not valid YAML"; continue; }
  [ "$(yq -r '.policy.allow_implicit_invocation' "$y")" = false ] || bad openai-yaml "$y does not turn implicit invocation off"
done

section skill-list
listed="$(sed -n '/^_LIB_KIT_SKILLS=(/,/^)/p' plugins/guards/scripts/lib/check-docs-md.sh | sed '1d;$d' | tr -s '[:space:]' '\n' | grep -v '^$' | sort)"
folders="$(for d in plugins/*/skills/*/; do basename "$d"; done | sort)"
[ "$listed" = "$folders" ] || bad skill-list "_LIB_KIT_SKILLS differs from the skill folders: $(diff <(printf '%s\n' "$listed") <(printf '%s\n' "$folders") | grep '^[<>]' | tr '\n' ' ')"

section examples
indexed="$(grep -oE '^\| \[[a-z0-9-]+\]\([a-z0-9-]+/story\.md\)' examples/README.md | sed -E 's/.*\(([a-z0-9-]+)\/story\.md\)/\1/' | sort)"
present="$(for d in examples/*/; do basename "$d"; done | sort)"
[ "$indexed" = "$present" ] || bad examples "examples/README.md lists [$(printf '%s' "$indexed" | tr '\n' ' ')], the folders are [$(printf '%s' "$present" | tr '\n' ' ')]"
# The text block right after the README's `scripts/run-examples.sh` command block.
shown="$(awk '/^```sh$/ { insh = 1; next } insh && /^```$/ { insh = 0; if (cmd) want = 1; next }
  insh && /^scripts\/run-examples\.sh$/ { cmd = 1; next }
  want && /^```text$/ { intext = 1; next } intext && /^```$/ { exit } intext { print }' README.md)"
real="$(bash scripts/run-examples.sh 2>&1)"
[ -n "$shown" ] || bad examples "README.md has no output block after scripts/run-examples.sh"
[ -z "$shown" ] || [ "$shown" = "$real" ] || bad examples "README.md's run-examples output differs from a real run: $(diff <(printf '%s\n' "$shown") <(printf '%s\n' "$real") | grep '^[<>]' | tr '\n' ' ')"

section headers
# The SPDX tag is assembled so this file's only licence line is its own header.
spdx_tag="$(printf 'SPDX%sLicense%sIdentifier: MIT' - -)"
while IFS= read -r f; do
  top="$(head -5 "$f")"
  printf '%s' "$top" | grep -q 'Copyright 2026 The agentic-workflow-kit Authors' \
    && printf '%s' "$top" | grep -qF "$spdx_tag" || bad headers "$f lacks the copyright or SPDX line in its first five lines"
done < <({ find plugins bridge shared scripts -type f \( -name '*.sh' -o -name '*.py' -o -name '*.jq' \); find plugins/starter/files/githooks -type f; } | sort)

echo "----"
[ "$problems" -eq 0 ] && { echo "check-docs: every check passed"; exit 0; }
echo "check-docs: $problems problem(s)"; exit 1
