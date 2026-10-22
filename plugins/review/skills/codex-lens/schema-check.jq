# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Checks the input against the JSON schema passed as $schema and prints one line per problem
# (nothing when the input conforms). It reads the schema itself, so it cannot drift from it.
# Covers the keywords codex-lens.schema.json uses: type (object, array, string, integer,
# number, boolean), required, properties, additionalProperties false, items, enum, minLength,
# minimum and maximum. Used by codex-lens.sh and claude-lens.sh:
#   jq -r --argjson schema "$(cat codex-lens.schema.json)" -f schema-check.jq <output.json>

def typeok($t):
  if   $t == "object"  then type == "object"
  elif $t == "array"   then type == "array"
  elif $t == "string"  then type == "string"
  elif $t == "integer" then (type == "number" and . == floor)
  elif $t == "number"  then type == "number"
  elif $t == "boolean" then type == "boolean"
  else true end;

def check($s; $path):
  if ($s.type != null and (typeok($s.type) | not)) then "\($path): not \($s.type)"
  else
    (if ($s.enum != null and ([. as $v | $s.enum[] | . == $v] | any | not)) then "\($path): not one of \($s.enum | map(tostring) | join(", "))" else empty end),
    (if ($s.minLength != null and type == "string" and length < $s.minLength) then "\($path): shorter than \($s.minLength)" else empty end),
    (if ($s.minimum != null and type == "number" and . < $s.minimum) then "\($path): below \($s.minimum)" else empty end),
    (if ($s.maximum != null and type == "number" and . > $s.maximum) then "\($path): above \($s.maximum)" else empty end),
    (if type == "object" then
       (. as $o | ($s.required // [])[] as $k | select(($o | has($k)) | not) | "\($path).\($k): missing"),
       (if $s.additionalProperties == false then
          (keys[] as $k | select((($s.properties // {}) | has($k)) | not) | "\($path).\($k): not allowed")
        else empty end),
       (to_entries[] | .key as $k | select((($s.properties // {}) | has($k))) | .value | check($s.properties[$k]; "\($path).\($k)"))
     else empty end),
    (if (type == "array" and $s.items != null) then
       (to_entries[] | .key as $i | .value | check($s.items; "\($path)[\($i)]"))
     else empty end)
  end;

check($schema; "$")
