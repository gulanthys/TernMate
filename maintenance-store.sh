#!/bin/sh
set -eu
umask 077
root=$1 scope=$2 key=$3 mode=$4
case $scope in ''|*[!a-zA-Z0-9_-]*) exit 2;; esac
case $key in ''|*[!a-zA-Z0-9_-]*) exit 2;; esac
case $mode in
    mirror-probe|mirror-write|mirror-remove)
        base=$root/maintenance-mirror-v1
        dir=$base/$scope
        path=$dir/$key.json
        for parent in "$base" "$dir"; do
            if [ -L "$parent" ]; then exit 2; fi
            if [ ! -e "$parent" ]; then
                if [ "$mode" != mirror-write ]; then printf 'false\n'; exit 0; fi
                mkdir -p "$parent"
            fi
            [ -d "$parent" ] && [ -O "$parent" ] || exit 2
            chmod 700 "$parent"
        done
        if [ -L "$path" ]; then exit 2; fi
        if [ -e "$path" ]; then
            [ -f "$path" ] && [ -O "$path" ] || exit 2
            chmod 600 "$path"
        fi
        case $mode in
            mirror-probe)
                if [ -f "$path" ]; then printf 'true\n'; else printf 'false\n'; fi ;;
            mirror-remove)
                rm -f "$path" ;;
            mirror-write)
                tmp=$(mktemp "$dir/.snapshot.XXXXXXXX")
                trap 'rm -f "$tmp"' EXIT
                cat > "$tmp"
                mv -f "$tmp" "$path" ;;
        esac
        exit 0 ;;
esac
dir=$root/maintenance-v1/$scope
mkdir -p "$dir"
path=$dir/$key.json
case $mode in
    read) if [ -f "$path" ]; then cat "$path"; else printf 'null\n'; fi ;;
    remove) [ ! -e "$path" ] || rm -f "$path"; printf 'true\n' ;;
    write|create|append)
        tmp=$(mktemp "$dir/.record.XXXXXXXX")
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp"
        case $mode in
            create) ln "$tmp" "$path" || exit 3 ;;
            append) ln "$tmp" "$dir/$key-entry-${tmp##*.}.json" || exit 3 ;;
            write) mv -f "$tmp" "$path" ;;
        esac
        printf 'true\n' ;;
    list)
        printf '['
        comma=
        for item in "$dir/$key-entry-"*.json; do
            [ -f "$item" ] || continue
            printf '%s' "$comma"
            cat "$item"
            comma=,
        done
        printf ']\n' ;;
    *) exit 2 ;;
esac
