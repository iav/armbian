#!/bin/bash
# Demo file for reviewdog/action-shellcheck PR-review test.
# Intentionally broken — do not source or execute.
#
# Mix of severities so the level=error / fail_level=error gate can be
# observed: only the SC1xxx parser error below should turn into a PR
# review-comment when the new maintenance-lint-scripts-reviewdog.yml
# workflow runs.

# SC2086 — unquoted variable expansion (info)
arg=$1
echo $arg

# SC2034 — assigned but never used (warning)
unused="dead"

# SC2046 — quote $() to prevent word splitting (warning)
ls $(echo /tmp)

# SC1073 — parser error: unmatched $( (error)
broken=$(echo hello
