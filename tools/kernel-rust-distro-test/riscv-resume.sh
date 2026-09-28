#!/bin/bash
# Resume the riscv64-host clang kernel builds in iav/armbian after a step timeout.
# Each run restores the newest ccache of its board; a new commit on test/riscv64-host
# with a one-board matrix starts the next run. Stops a board on success, on a failure
# other than the 290-minute timeout, or after MAX runs.
set -u
repo=iav/armbian
ws=/home/iav/armbian/.tmp/ws-riscv-test
log=/home/iav/armbian/.tmp/riscv-resume.log
wf=.github/workflows/test-riscv64-host.yml
MAX=6
declare -A run=([odroidn2]=36375804662 [helios4]=36359365067)
declare -A count=([odroidn2]=3 [helios4]=2)
declare -A ext=([odroidn2]="arm64-compat-vdso" [helios4]="")

say() { echo "$(date '+%F %T') $*" | tee -a "${log}"; }

start_run() {
	local board=$1 commit id
	cd "${ws}" || return 1
	jj new test/riscv64-host -m "ci(test): resume ${board} clang on riscv64 host (fork only, not for upstream)" > /dev/null 2>&1 || return 1
	python3 - "${wf}" "${board}" "${ext[${board}]}" << 'EOF' || return 1
import re, sys
p, board, ext = sys.argv[1:]
s = open(p).read()
s = re.sub(r'(        include:\n)(?:          - \{[^\n]*\}\n)+',
           lambda m: m.group(1) + '          - { board: "%s", compiler: "clang", extensions: "%s" }\n' % (board, ext), s)
open(p, 'w').write(s)
EOF
	jj bookmark set test/riscv64-host -r @ > /dev/null 2>&1 || return 1
	jj git push --remote my --bookmark test/riscv64-host > /dev/null 2>&1 || return 1
	commit=$(jj log -r @ --no-graph -T 'commit_id')
	for _ in $(seq 1 20); do
		sleep 15
		id=$(gh run list -R "${repo}" -b test/riscv64-host -w test-riscv64-host.yml -L 5 --json databaseId,headSha \
			--jq ".[] | select(.headSha == \"${commit}\") | .databaseId" | head -1)
		if [[ -n "${id}" ]]; then
			run[${board}]=${id}
			count[${board}]=$((count[${board}] + 1))
			say "${board}: run ${count[${board}]} started: ${id}"
			return 0
		fi
	done
	return 1
}

say "start: ${!run[*]}"
until [[ ${#run[@]} -eq 0 ]]; do
	sleep 120
	for board in "${!run[@]}"; do
		r=${run[${board}]}
		st=$(gh run view "${r}" -R "${repo}" --json status,conclusion --jq '"\(.status) \(.conclusion)"' 2> /dev/null) || continue
		[[ "${st}" == completed* ]] || continue
		if [[ "${st}" == "completed success" ]]; then
			say "${board}: run ${r} SUCCESS after ${count[${board}]} runs"
			unset "run[${board}]"
			continue
		fi
		job=$(gh run view "${r}" -R "${repo}" --json jobs --jq '.jobs[0].databaseId')
		if ! gh api "repos/${repo}/actions/jobs/${job}/logs" 2> /dev/null | grep -q "has timed out after 290 minutes"; then
			say "${board}: run ${r} FAILED (not a timeout), stopping"
			unset "run[${board}]"
			continue
		fi
		if ((count[${board}] >= MAX)); then
			say "${board}: run ${r} timed out, ${MAX} runs used, stopping"
			unset "run[${board}]"
			continue
		fi
		say "${board}: run ${r} timed out, resuming"
		start_run "${board}" || { say "${board}: could not start the next run, stopping"; unset "run[${board}]"; }
	done
done
say "all boards done"
