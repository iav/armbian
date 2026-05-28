#!/bin/bash
# Synthetic shellcheck failure for self-testing the Maintenance:
# Lint scripts gate (PR #146). Intentional SC2199. Remove together
# with the test PR after the gate flow is verified.

arr=(alpha beta gamma)
target="alpha"

# SC2199: arrays implicitly concatenate in [[ ]]; should be a loop
# or `${arr[*]}`. This line is the whole point of the file.
if [[ ! " ${arr[@]} " =~ " ${target} " ]]; then
	echo "not found"
fi

# Second intentional SC2199 on a fresh line, so reviewdog posts a
# new (non-deduplicated) comment on the Conversation tab.
other=(x y z)
if [[ ! " ${other[@]} " =~ " ${target} " ]]; then
	echo "still not found"
fi
