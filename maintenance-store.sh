#!/bin/sh
set -eu
umask 077
root=$1 scope=$2 key=$3 mode=$4
case $scope in ''|*[!a-zA-Z0-9_-]*) exit 2;; esac
case $key in ''|*[!a-zA-Z0-9_-]*) exit 2;; esac
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
