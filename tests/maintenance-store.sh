#!/bin/sh
# Run directly; all records are created under a disposable plugin data directory.
set -eu
root=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-store-test.XXXXXXXX")
trap 'rm -rf "$root"' EXIT
trap 'exit 1' HUP INT TERM
helper=$(dirname "$0")/../maintenance-store.sh
store() { /bin/sh "$helper" "$root" test-scope "$@"; }

# An old login that happens to match a new ID cannot supply the new draft.
mkdir -p "$root/maintenance-v1/test-scope"
legacy=$root/maintenance-v1/test-scope/draft.json
printf '%s' '{"title":"old account"}' > "$legacy"
[ "$(store draft read)" = null ]
printf '%s' '{"title":"current account"}' | store draft create >/dev/null
[ "$(store draft read)" = '{"title":"current account"}' ]
[ "$(cat "$legacy")" = '{"title":"old account"}' ]

# A successful check can advance freshness without replacing the snapshot.
first=$(printf '%s' '{"checkedEpoch":10}' | store snapshot mirror-write 0)
snapshot=$root/maintenance-mirror-v1/test-scope/snapshot.json
ln "$snapshot" "$root/original"
store snapshot mirror-stamp 0 "$first" 100 10
[ "$root/original" -ef "$snapshot" ]
[ "$(store snapshot mirror-probe)" = "$(printf 'true\n0\n%s 100 10 0' "$first")" ]

# A late callback for the first snapshot must not refresh its replacement.
second=$(printf '%s' '{"checkedEpoch":120}' | store snapshot mirror-write 0)
[ "$first" != "$second" ]
store snapshot mirror-stamp 0 "$second" 125 120
ret=0; store snapshot mirror-stamp 0 "$first" 140 10 || ret=$?
[ "$ret" = 4 ]
[ "$(store snapshot mirror-probe)" = "$(printf 'true\n0\n%s 125 120 0' "$second")" ]

# A receipt invalidates the disk cache before it can be read, across fresh
# processes. Scans that captured the previous revision cannot publish freshness.
printf '%s' '{"kind":"receipt","issue":{"number":1}}' | store submit-result-1 create >/dev/null
revision=$(store snapshot mirror-revision)
[ "$revision" = r1 ]
[ "$(store snapshot mirror-probe)" = "$(printf 'true\n%s\n%s 125 120 0' "$revision" "$second")" ]
ret=0; store snapshot mirror-stamp 0 "$second" 140 120 || ret=$?
[ "$ret" = 5 ]
ret=0; printf '%s' '{"checkedEpoch":140}' | store snapshot mirror-write 0 || ret=$?
[ "$ret" = 5 ]
store snapshot mirror-stamp "$revision" "$second" 150 120
[ "$(store snapshot mirror-probe)" = "$(printf 'true\n%s\n%s 150 120 %s' "$revision" "$second" "$revision")" ]
# Hold both attempts in the store pipeline before releasing their input.
mkfifo "$root/first.in" "$root/second.in"
store submit-result-2 create < "$root/first.in" > "$root/first.out" 2>/dev/null & first_pid=$!
store submit-result-2 create < "$root/second.in" > "$root/second.out" 2>/dev/null & second_pid=$!
exec 3>"$root/first.in" 4>"$root/second.in"
printf '%s' '{"kind":"receipt","issue":{"number":2}}' >&3
printf '%s' '{"kind":"receipt","issue":{"number":2}}' >&4
exec 3>&- 4>&-
first_status=0; wait "$first_pid" || first_status=$?
second_status=0; wait "$second_pid" || second_status=$?
case $first_status:$second_status in 0:3|3:0) ;; *) exit 1 ;; esac
[ "$(store snapshot mirror-revision)" = r2 ]
store snapshot mirror-stamp r2 "$second" 160 120
[ "$(store snapshot mirror-probe)" = "$(printf 'true\nr2\n%s 160 120 r2' "$second")" ]
[ "$(/bin/sh "$helper" "$root" other-scope snapshot mirror-revision)" = 0 ]

# Both editors saw the same prior value; only one may replace it.
printf '%s' '{"title":"shared"}' | store submit-draft-3 create >/dev/null
printf '%s' '{"expected":{"title":"shared"},"replacement":{"title":"A"}}' | store submit-draft-3 draft-save > "$root/a" &
first_pid=$!
printf '%s' '{"expected":{"title":"shared"},"replacement":{"title":"B"}}' | store submit-draft-3 draft-save > "$root/b" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
case "$(store submit-draft-3 read)" in
    '{"title":"A"}') [ "$(cat "$root/a")" = '{"status":"saved"}' ] && [ "$(cat "$root/b")" = '{"status":"conflict","draft":{"title":"A"}}' ] ;;
    '{"title":"B"}') [ "$(cat "$root/b")" = '{"status":"saved"}' ] && [ "$(cat "$root/a")" = '{"status":"conflict","draft":{"title":"B"}}' ] ;;
    *) exit 1 ;;
esac
winning_draft=$(store submit-draft-3 read)
for lock in '{"kind":"discard"}' '{"kind":"external","issue":{"number":3}}'; do
    status=$(printf '{"expected":{"title":"shared"},"replacement":%s}' "$lock" | store submit-lock-3 draft-settle)
    [ "$status" = '{"status":"conflict","draft":null}' ]
    [ "$(store submit-lock-3 read)" = null ]
    [ "$(store submit-draft-3 read)" = "$winning_draft" ]
    [ "$(store snapshot mirror-revision)" = r2 ]
done
status=$(printf '{"expected":%s,"replacement":{"kind":"external","issue":{"number":3}}}' "$winning_draft" |
    store submit-lock-3 draft-settle)
[ "$status" = '{"status":"settled"}' ]
[ "$(store snapshot mirror-revision)" = r3 ]
ret=0; store snapshot mirror-stamp r2 "$second" 170 120 || ret=$?
[ "$ret" = 5 ]
ret=0; printf '%s' '{"kind":"external","issue":{"number":4}}' | store submit-lock-3 create || ret=$?
[ "$ret" = 3 ] && [ "$(store snapshot mirror-revision)" = r3 ]
store submit-draft-3 remove >/dev/null
[ "$(printf '%s' '{"replacement":{"title":"resurrected"}}' | store submit-draft-3 draft-save)" = '{"status":"locked"}' ]
[ "$(store submit-draft-3 read)" = null ]
printf '%s' '{"kind":"discard"}' | store submit-lock-4 create >/dev/null
printf '%s' '{"kind":"attempt"}' | store submit-lock-5 create >/dev/null
[ "$(store snapshot mirror-revision)" = r3 ]
printf '%s\n' 'Maintenance record isolation, freshness and durable receipt fencing passed.'
