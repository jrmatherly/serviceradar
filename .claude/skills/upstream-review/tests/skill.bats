load helpers
SKILL="$(dirname "$DRIVER")/../SKILL.md"

@test "frontmatter name matches the directory" {
  [ "$(sed -n 's/^name: //p' "$SKILL")" = "upstream-review" ]
}

@test "description is third person, under 1024 chars, and names the trigger phrases" {
  d="$(sed -n 's/^description: //p' "$SKILL")"
  [ "${#d}" -le 1024 ]
  [[ "$d" == *"what changed upstream"* ]]
  [[ "$d" == *"sync from upstream"* ]]
  [[ "$d" == Reviews* ]]
}

@test "allowed-tools lets the driver run without a prompt" {
  grep -qF 'Bash(${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh *)' "$SKILL"
}

@test "body is real and stays under 2000 words" {
  words="$(awk 'f{print} /^---$/{c++; if(c==2) f=1}' "$SKILL" | wc -w)"
  [ "$words" -ge 300 ]
  [ "$words" -le 2000 ]
}

@test "every bundled file is wired from SKILL.md and no file is ASCII-unclean" {
  for f in references/deviations.md references/decision-log-template.md references/validation.md scripts/upstream-review.sh; do
    grep -q "$f" "$SKILL"
  done
  ! LC_ALL=C grep -rn '[^ -~'"$(printf '\t')"']' "$(dirname "$SKILL")" --include='*.md'
}
