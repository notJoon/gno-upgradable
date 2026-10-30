#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
work_dir="$tmp_dir/work"
key_home="$tmp_dir/keys"
node_log="$tmp_dir/gnodev.log"
node_pid=

cleanup() {
	if [[ -n "$node_pid" ]]; then
		kill "$node_pid" 2>/dev/null || true
		wait "$node_pid" 2>/dev/null || true
	fi
	rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

fail() {
	cat "$node_log" >&2
	exit 1
}

# Public test account used by gnodev and the in-memory integration tests.
seed="source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast"
password="ci-password"
printf '%s\n%s\n%s\n' "$seed" "$password" "$password" |
	gnokey -home "$key_home" -insecure-password-stdin=true add -recover test1 >/dev/null

mkdir -p "$work_dir"
cp -R "$repo_dir/src" "$work_dir/"
touch "$work_dir/gnowork.toml"
rm -rf "$work_dir/src/r/upgrade/vault/v2"
vault="$work_dir/src/r/upgrade/vault/vault.gno"
grep -q '^const UpgradeDelay = ' "$vault" || fail
perl -pi -e 's/^const UpgradeDelay = .*/const UpgradeDelay = 2/' "$vault"

gnodev local -C "$work_dir" -empty-blocks -no-web \
	-paths gno.land/r/upgrade/vault,gno.land/r/upgrade/vault/v1 >"$node_log" 2>&1 &
node_pid=$!

ready=false
for _ in $(seq 1 60); do
	if gnokey query vm/qeval --data 'gno.land/r/upgrade/vault.Approved()' \
		-remote 127.0.0.1:26657 >/dev/null 2>&1; then
		ready=true
		break
	fi
	if ! kill -0 "$node_pid" 2>/dev/null; then
		fail
	fi
	sleep 0.25
done
[[ "$ready" == true ]] || fail

tx() {
	printf '%s\n' "$password" | gnokey -home "$key_home" -insecure-password-stdin=true \
		-remote 127.0.0.1:26657 "$@"
}

tx maketx call -pkgpath gno.land/r/upgrade/vault -func Approve \
	-args gno.land/r/upgrade/vault/v1 -gas-fee 1000000ugnot \
	-gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null
tx maketx call -pkgpath gno.land/r/upgrade/vault/v1 -func Upgrade \
	-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null
tx maketx call -pkgpath gno.land/r/upgrade/vault -func Call -args Deposit -args '' \
	-send 1000ugnot -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null

tx maketx addpkg -pkgdir "$repo_dir/src/r/upgrade/vault/v2" \
	-pkgpath gno.land/r/upgrade/vault/v2 -gas-fee 1000000ugnot \
	-gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null
tx maketx call -pkgpath gno.land/r/upgrade/vault -func Approve \
	-args gno.land/r/upgrade/vault/v2 -gas-fee 1000000ugnot \
	-gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null
tx maketx call -pkgpath gno.land/r/upgrade/vault/v2 -func Upgrade \
	-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null
tx maketx send -send 1ugnot -to g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 \
	-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null
tx maketx call -pkgpath gno.land/r/upgrade/vault/v2 -func Upgrade \
	-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast -chainid dev test1 >/dev/null

gnokey query vm/qeval --data 'gno.land/r/upgrade/vault.ImplPath()' \
	-remote 127.0.0.1:26657 | grep -q 'gno.land/r/upgrade/vault/v2' || fail
gnokey query vm/qeval \
	--data 'gno.land/r/upgrade/vault.Query("BalanceOf", "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")' \
	-remote 127.0.0.1:26657 | grep -q '"1000"' || fail

echo "gnodev integration passed"
