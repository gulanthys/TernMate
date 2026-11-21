#!/bin/sh
set -eu
umask 077
root=$1 scope=$2 key=$3 mode=$4
case $scope in ''|*[!a-zA-Z0-9_-]*) exit 2;; esac
case $key in ''|*[!a-zA-Z0-9_-]*) exit 2;; esac

records=$root/maintenance-v2/$scope
revision() {
    # Immutable results and external receipts settle their slot. An attempt
    # or discard lock alone is not a receipt and does not invalidate the list.
    latest=0
    if [ -e "$records" ] || [ -L "$records" ]; then
        [ -d "$records" ] && [ -r "$records" ] && [ -x "$records" ] || return 2
        for result in "$records"/submit-result-*.json; do
            [ -f "$result" ] || continue
            slot=${result##*/submit-result-}
            slot=${slot%.json}
            case $slot in ''|0*|*[!0-9]*) continue ;; esac
            if [ "$slot" -gt "$latest" ]; then latest=$slot; fi
        done
        for lock in "$records"/submit-lock-*.json; do
            [ -f "$lock" ] || continue
            slot=${lock##*/submit-lock-}
            slot=${slot%.json}
            case $slot in ''|0*|*[!0-9]*) continue ;; esac
            [ "$slot" -gt "$latest" ] || continue
            if grep -q '"kind"[[:space:]]*:[[:space:]]*"external"' "$lock"; then
                latest=$slot
            else
                [ "$?" -eq 1 ] || return 2
            fi
        done
    fi
    if [ "$latest" -eq 0 ]; then printf '0\n'; else printf 'r%s\n' "$latest"; fi
}

check_revision() {
    current_revision=$(revision) || exit 2
    [ "$current_revision" = "$expected_revision" ] || exit 5
}

if [ "$mode" = mirror-revision ]; then revision; exit; fi
case $mode in
    mirror-probe|mirror-write|mirror-stamp|mirror-remove)
        base=$root/maintenance-mirror-v1
        dir=$base/$scope
        path=$dir/$key.json
        checked=$dir/$key.checked
        for parent in "$base" "$dir"; do
            if [ -L "$parent" ]; then exit 2; fi
            if [ ! -e "$parent" ]; then
                case $mode in
                    mirror-probe) printf 'false\n'; exit 0 ;;
                    mirror-remove) exit 0 ;;
                    mirror-stamp) exit 4 ;;
                esac
                mkdir -p "$parent"
            fi
            [ -d "$parent" ] && [ -O "$parent" ] || exit 2
            chmod 700 "$parent"
        done
        case $mode in
            mirror-write|mirror-stamp)
                expected_revision=$5
                check_revision ;;
        esac
        if [ -L "$path" ]; then exit 2; fi
        if [ -e "$path" ]; then
            [ -f "$path" ] && [ -O "$path" ] || exit 2
            chmod 600 "$path"
        fi
        if [ "$mode" = mirror-probe ] || [ "$mode" = mirror-stamp ]; then
            if [ -L "$checked" ]; then exit 2; fi
            if [ -e "$checked" ]; then
                [ -f "$checked" ] && [ -O "$checked" ] || exit 2
                chmod 600 "$checked"
            fi
        fi
        case $mode in
            mirror-probe)
                if [ -f "$path" ]; then
                    printf 'true\n'
                    revision
                    if [ -f "$checked" ]; then head -c 256 "$checked"; fi
                else
                    printf 'false\n'
                fi ;;
            mirror-remove)
                rm -f "$path" "$checked" ;;
            mirror-write)
                tmp=$(mktemp "$dir/.snapshot.XXXXXXXXXXXX")
                trap 'rm -f "$tmp"' EXIT
                generation=$$-${tmp##*.}
                {
                    printf '{"generation":"%s","snapshot":\n' "$generation"
                    cat
                    printf '\n}\n'
                } > "$tmp"
                check_revision
                mv -f "$tmp" "$path"
                check_revision
                printf '%s\n' "$generation" ;;
            mirror-stamp)
                generation=$6 checked_epoch=$7 reconciled_epoch=$8
                case $generation in ''|*[!a-zA-Z0-9-]*) exit 2;; esac
                case $checked_epoch in ''|*[!0-9]*) exit 2;; esac
                case $reconciled_epoch in ''|*[!0-9]*) exit 2;; esac
                [ -f "$path" ] || exit 4
                # Read only the generation header, not the whole mirror.
                expected=$(printf '{"generation":"%s","snapshot":' "$generation")
                current=$(head -c "${#expected}" "$path")
                [ "$current" = "$expected" ] || exit 4
                tmp=$(mktemp "$dir/.checked.XXXXXXXX")
                trap 'rm -f "$tmp"' EXIT
                printf '%s %s %s %s\n' "$generation" "$checked_epoch" "$reconciled_epoch" "$expected_revision" > "$tmp"
                check_revision
                mv -f "$tmp" "$checked"
                check_revision ;;
        esac
        exit 0 ;;
esac
mkdir -p "$records"
path=$records/$key.json
# Share a per-slot file lock between compare-and-save, seeding, and locking
# the slot for submission, discard or external attachment. Never unlink it.
case $mode:$key in
    draft-save:submit-draft-*|draft-settle:submit-lock-*|create:submit-draft-*|create:submit-lock-*)
        part=${key#submit-}; slot=${part#*-}; part=${part%%-*}
        exec /usr/bin/env -u RUBYOPT -u RUBYLIB -u BUNDLE_GEMFILE -u GEM_HOME -u GEM_PATH \
            /usr/bin/ruby --disable-gems "$(dirname "$0")/draft-store.rb" "$path" "$part" "$slot" "$mode" ;;
esac
case $mode in
    read) if [ -f "$path" ]; then cat "$path"; else printf 'null\n'; fi ;;
    remove) [ ! -e "$path" ] || rm -f "$path"; printf 'true\n' ;;
    write|create|append)
        tmp=$(mktemp "$records/.record.XXXXXXXX")
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp"
        case $mode in
            create) ln "$tmp" "$path" || exit 3 ;;
            append) ln "$tmp" "$records/$key-entry-${tmp##*.}.json" || exit 3 ;;
            write) mv -f "$tmp" "$path" ;;
        esac
        printf 'true\n' ;;
    list)
        printf '['
        comma=
        for item in "$records/$key-entry-"*.json; do
            [ -f "$item" ] || continue
            printf '%s' "$comma"
            cat "$item"
            comma=,
        done
        printf ']\n' ;;
    *) exit 2 ;;
esac
