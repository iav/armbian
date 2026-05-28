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
