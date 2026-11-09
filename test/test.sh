#!/usr/bin/env bash
# Runs dyno.sh against a fake dynoapp.io and GitHub token service (fake_site.py) and a fake dyno,
# in a repo of two games, and checks what it asked for, what it uploaded and how it exited. Needs
# bash, curl and python3 3.11 or newer.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action="$here/../dyno.sh"
tmp="$(mktemp -d)"
server=""
failures=0

cleanup() {
	[[ -z "$server" ]] || kill "$server" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT

moon=6f1c2a8e-0000-4000-8000-000000000000
tile=1b4e28ba-2fa1-41d2-883f-0016d3cca427

# The fake dyno: `check` writes a result with the status in the build's `status` file and exits
# as dyno does; `upload` posts the result with DYNO_TOKEN.
mkdir -p "$tmp/archive/dyno-x86_64-unknown-linux-gnu"
cat >"$tmp/archive/dyno-x86_64-unknown-linux-gnu/dyno" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  check)
    build="$2"
    [[ "$3" == --browser && "$4" == --out ]] || { echo "unexpected flags: $*" >&2; exit 64; }
    [[ -d "$build" ]] || { echo "$build is not a folder" >&2; exit 64; }
    status="$(cat "$build/status")"
    printf '{"schema_version":0,"result_hash":"h","deterministic":{"status":"%s"},"run":{"release":{"game_id":"%s"}}}' \
      "$status" "$(cat "$build/game_id")" >"$5"
    case "$status" in pass | warn) exit 0 ;; fail) exit 1 ;; incomplete) exit 2 ;; *) exit 3 ;; esac
    ;;
  upload)
    answer="$(curl --silent --show-error --fail-with-body -H "Authorization: Bearer $DYNO_TOKEN" \
      -H "Content-Type: application/json" --data-binary "@$2" "$DYNO_API_URL/api/results")" ||
      { echo "the site refused it: $answer" >&2; exit 70; }
    echo "uploaded $2: $(python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])' <<<"$answer")" >&2
    ;;
esac
SH
chmod +x "$tmp/archive/dyno-x86_64-unknown-linux-gnu/dyno"
tar -czf "$tmp/dyno.tar.gz" -C "$tmp/archive" dyno-x86_64-unknown-linux-gnu

# Starts the fake site with these modes (fake_site.py), in a fresh state folder.
start() {
	[[ -z "$server" ]] || kill "$server" 2>/dev/null || true
	rm -rf "$tmp/state"
	mkdir -p "$tmp/state"
	python3 "$here/fake_site.py" "$tmp/state" "$tmp/dyno.tar.gz" "$@" &
	server=$!
	for _ in $(seq 50); do
		[[ -s "$tmp/state/port" ]] && return
		sleep 0.1
	done
	echo "the fake site did not start" >&2
	exit 1
}

# A repo with dyno.toml and the two games' builds: Moon Lander passes, Tile Pop fails.
repo() {
	rm -rf "$tmp/repo"
	mkdir -p "$tmp/repo/games/moon/dist" "$tmp/repo/games/tile/dist"
	echo pass >"$tmp/repo/games/moon/dist/status"
	echo "$moon" >"$tmp/repo/games/moon/dist/game_id"
	echo fail >"$tmp/repo/games/tile/dist/status"
	echo "$tile" >"$tmp/repo/games/tile/dist/game_id"
	cat >"$tmp/repo/dyno.toml" <<TOML
schema_version = 0

[build]
command = "true"

[[game]]
id = "$moon"
name = "Moon Lander"
build = "games/moon/dist"

[[game]]
id = "$tile"
name = "Tile Pop"
build = "games/tile/dist"
TOML
}

# Runs dyno.sh in the repo with these extra settings, and sets CODE and OUTPUT.
run() {
	local port
	port="$(cat "$tmp/state/port")"
	rm -rf "$tmp/runner"
	mkdir -p "$tmp/runner"
	CODE=0
	OUTPUT="$(cd "$tmp/repo" && env -i PATH="$PATH" HOME="$HOME" \
		ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?api-version=2.0" \
		ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token \
		DYNO_API_URL="http://127.0.0.1:$port" \
		GITHUB_STEP_SUMMARY="$tmp/runner/summary.md" GITHUB_OUTPUT="$tmp/runner/output" \
		RUNNER_TEMP="$tmp/runner" "$@" bash "$action" 2>&1)" || CODE=$?
}

check() {
	local what="$1"
	shift
	if "$@"; then
		echo "ok: $what"
	else
		echo "FAILED: $what"
		printf '    %s\n' "${OUTPUT//$'\n'/$'\n'    }"
		failures=$((failures + 1))
	fi
}

# How many requests the fake site logged that match a pattern.
requests() { cat "$tmp/state/requests.log" 2>/dev/null | grep -c "$1" || true; }

echo "Every game is checked and uploaded, each call with a fresh token"
start
repo
run
check "report-only passes a failing game" test "$CODE" -eq 0
check "three tokens, each for dynoapp.io" test "$(grep -c '"audience": \["https://dynoapp.io"\], "ok": true' "$tmp/state/requests.log")" -eq 3
check "one download of dyno" test "$(requests '/api/dist/latest/x86_64-unknown-linux-gnu')" -eq 1
check "an upload for each game, each with its own token" \
	test "$(grep -c '"POST", "path": "/api/results", "token": "oidc-' "$tmp/state/requests.log")" -eq 2
check "no token is refused" test "$(grep -c '"token": null' "$tmp/state/requests.log" || true)" -eq 0
check "the summary has each game, its status and its link" \
	grep -q "| Tile Pop | fail | \[Open\](http://127.0.0.1:.*/#/runs/$tile) |" "$tmp/runner/summary.md"
check "the results folder is an output" grep -q "^results=$tmp/runner/dyno\..*/results$" "$tmp/runner/output"
check "the token is masked" grep -q "::add-mask::oidc-2" <<<"$OUTPUT"

echo "report-only false fails a game that does not pass, after every upload"
start
run REPORT_ONLY=false
check "the job fails" test "$CODE" -eq 1
check "both results still upload" test "$(requests '"POST", "path": "/api/results"')" -eq 2
check "it says why" grep -q "a game did not pass" <<<"$OUTPUT"

echo "games picks games by name or id"
start
run GAMES="tile pop"
check "one upload, of Tile Pop" test "$(requests "\"game\": \"$tile\"")" -eq 1
check "Moon Lander is not checked" test "$(requests "\"game\": \"$moon\"")" -eq 0
start
run GAMES="nope, $moon"
check "a game dyno.toml does not have fails before any download" test "$CODE" -eq 1
check "nothing was asked of the site" test "$(requests /api/)" -eq 0

echo "A run with no OIDC token skips and passes"
start
run ACTIONS_ID_TOKEN_REQUEST_URL=
check "it passes" test "$CODE" -eq 0
check "it says why" grep -q "::notice title=dyno skipped::" <<<"$OUTPUT"
check "nothing was asked" test ! -e "$tmp/state/requests.log"
check "no results output" test ! -e "$tmp/runner/output"

echo "An archive that does not match its SHA-256 is not run"
start bad-sha
run
check "the job fails" test "$CODE" -eq 1
check "it says why" grep -q "does not match the SHA-256" <<<"$OUTPUT"
check "nothing was uploaded" test "$(requests /api/results)" -eq 0

echo "An upload that fails fails the job, even in report-only"
start refuse "$moon"
run
check "the job fails" test "$CODE" -eq 1
check "the site's reason shows" grep -q "the repo is not connected to dyno" <<<"$OUTPUT"
check "the other game still uploads" test "$(requests "\"game\": \"$tile\"")" -eq 1
check "the summary says it did not upload" grep -q "| Moon Lander | pass, not uploaded |  |" "$tmp/runner/summary.md"

echo "A build that is missing fails the job, and the other game still runs"
start
rm -rf "$tmp/repo/games/moon/dist"
run
check "the job fails" test "$CODE" -eq 1
check "it names the game" grep -q "dyno could not check Moon Lander (games/moon/dist): exit code 64" <<<"$OUTPUT"
check "Tile Pop still uploads" test "$(requests "\"game\": \"$tile\"")" -eq 1

echo "Bad settings stop it before it asks for anything"
start
repo
run VERSION=../../etc
check "a version that is not a sha fails" test "$CODE" -eq 1
run REPORT_ONLY=yes
check "report-only that is not true or false fails" test "$CODE" -eq 1
rm "$tmp/repo/dyno.toml"
run
check "no dyno.toml fails" test "$CODE" -eq 1
check "nothing was asked" test ! -e "$tmp/state/requests.log"

if ((failures)); then
	echo "$failures checks failed"
	exit 1
fi
echo "every check passed"
