#!/usr/bin/env bash
# The dyno Action's work (action.yml). It asks GitHub for a fresh OIDC token for each call to
# dynoapp.io, because a token lasts only minutes: one to download dyno, then one per upload. For
# each game in dyno.toml it runs `dyno check <build> --browser`, then `dyno upload` of the result,
# so an upload that fails is never hidden behind a game's status.
#
# Settings, from action.yml: GAMES (ids or names, empty for all), REPORT_ONLY (true or false) and
# VERSION (latest or a commit's full sha). DYNO_API_URL names another site, for tests.
set -euo pipefail

api="${DYNO_API_URL:-https://dynoapp.io}"
api="${api%/}"
target=x86_64-unknown-linux-gnu
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
GAMES="${GAMES:-}"
REPORT_ONLY="${REPORT_ONLY:-true}"
VERSION="${VERSION:-latest}"

fail() {
	echo "::error title=dyno::$1"
	exit 1
}

if [[ "$REPORT_ONLY" != true && "$REPORT_ONLY" != false ]]; then
	fail "report-only is true or false, not $REPORT_ONLY"
fi
if [[ "$VERSION" != latest && ! "$VERSION" =~ ^[0-9a-f]{40}$ ]]; then
	fail "version is latest or a commit's full sha, not $VERSION"
fi

# GitHub gives a run an OIDC token only when the job has `permissions: id-token: write`, and never
# to a pull request from a fork.
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
	echo "::notice title=dyno skipped::This run has no GitHub OIDC token, so dyno did not run. A pull request from a fork has none. Otherwise, give the job permissions: id-token: write."
	echo "dyno did not run: this run has no GitHub OIDC token." >>"$summary"
	exit 0
fi

# A text field of the JSON object on stdin, or nothing.
field() {
	python3 -c 'import json, sys
value = json.load(sys.stdin).get(sys.argv[1])
print(value if isinstance(value, str) else "")' "$1" 2>/dev/null || true
}

# Sets TOKEN to a fresh OIDC token for dynoapp.io, and hides it in the log.
fresh_token() {
	TOKEN="$(curl --fail --silent --show-error --retry 3 \
		--header "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
		"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https%3A%2F%2Fdynoapp.io" | field value)"
	[[ -n "$TOKEN" ]] || fail "GitHub did not give an OIDC token"
	echo "::add-mask::$TOKEN"
}

[[ -f dyno.toml ]] || fail "there is no dyno.toml in $PWD: pick the games in dynoapp.io, Settings, GitHub"
# One line per game to check: its id, its build and its name, with tabs between them.
games="$(
	python3 - "$GAMES" <<'PY'
import re, sys, tomllib

with open("dyno.toml", "rb") as file:
    games = tomllib.load(file).get("game", [])
asked = [word.strip() for word in re.split(r"[,\n]", sys.argv[1]) if word.strip()]
chosen = []
for word in asked:
    found = [g for g in games if word.lower() in (g["id"].lower(), str(g.get("name") or "").lower())]
    if not found:
        sys.exit(f"dyno.toml has no game {word}")
    chosen += [g for g in found if g not in chosen]
for game in chosen if asked else games:
    print(game["id"], game["build"], game.get("name") or game["id"], sep="\t")
PY
)" || fail "could not read the games in dyno.toml"
[[ -n "$games" ]] || fail "dyno.toml names no game"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dyno.XXXXXX")"
fresh_token
dist="$(curl --fail-with-body --silent --show-error --retry 3 \
	--header "Authorization: Bearer $TOKEN" "$api/api/dist/$VERSION/$target")" ||
	fail "dynoapp.io did not give dyno: $(field error <<<"$dist")"
url="$(field url <<<"$dist")"
sha256="$(field sha256 <<<"$dist")"
[[ -n "$url" && "$sha256" =~ ^[0-9a-f]{64}$ ]] || fail "dynoapp.io's answer has no link or SHA-256"
curl --fail --silent --show-error --location --retry 3 --output "$work/dyno.tar.gz" "$url" ||
	fail "could not download dyno"
echo "$sha256  $work/dyno.tar.gz" | sha256sum --check --strict --quiet ||
	fail "the dyno archive does not match the SHA-256 that dynoapp.io gave"
tar -xzf "$work/dyno.tar.gz" -C "$work"
dyno="$work/dyno-$target/dyno"
echo "dyno from commit $(field version <<<"$dist")"

# Ubuntu 24.04 lets only a program with an AppArmor profile make the user namespaces that
# Chromium's sandbox needs. dyno keeps the sandbox on, so on GitHub's own runners the job allows
# them.
if [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted &&
	"$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" == 1 ]]; then
	sudo sysctl -q -w kernel.apparmor_restrict_unprivileged_userns=0
fi

results="$work/results"
mkdir -p "$results"
echo "results=$results" >>"${GITHUB_OUTPUT:-/dev/null}"
broken=0
unpassed=0
printf '### dyno\n\n| Game | Status | Report |\n| --- | --- | --- |\n' >>"$summary"
while IFS=$'\t' read -r id build name; do
	out="$results/$id.json"
	echo "::group::$name ($build)"
	code=0
	"$dyno" check "$build" --browser --out "$out" </dev/null || code=$?
	status=error
	link=""
	if ((code <= 3)) && [[ -s "$out" ]]; then
		status="$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["deterministic"]["status"])' "$out" 2>/dev/null || echo unknown)"
		((code == 0)) || unpassed=1
		fresh_token
		if uploaded="$(DYNO_TOKEN="$TOKEN" "$dyno" upload "$out" </dev/null 2>&1)"; then
			echo "$uploaded"
			link="$(grep -o 'https\?://[^ ]*' <<<"$uploaded" | tail -n 1 || true)"
		else
			echo "$uploaded"
			echo "::error title=dyno::the result of $name did not upload"
			status="$status, not uploaded"
			broken=1
		fi
	else
		echo "::error title=dyno::dyno could not check $name ($build): exit code $code"
		broken=1
	fi
	echo "::endgroup::"
	echo "| ${name//|/\\|} | $status | ${link:+[Open]($link)} |" >>"$summary"
done <<<"$games"

((broken == 0)) || fail "dyno could not check or upload every game: see the log"
if ((unpassed)) && [[ "$REPORT_ONLY" == false ]]; then
	fail "a game did not pass, and report-only is false"
fi
