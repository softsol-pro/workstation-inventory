#!/usr/bin/env bash
# check-linux.sh — проверка достоверности linux/inventory.sh на этом ПК.
# Запускает инвентаризацию в режимах «компании», «личный», без терминала и через stdin (как curl | bash)
# и сверяет результат с независимыми источниками (/proc, uname, stat, /sys/block, /etc/os-release).
# В системе ничего не меняет, временные файлы удаляет. Нужен jq или python3.
#
#   sudo bash tests/check-linux.sh            # полная проверка (с root видны модули памяти, SMART, sudoers)
#   sudo bash tests/check-linux.sh --strict   # дополнительно: под root не должно быть неполных проверок

SCRIPT="$(dirname "$0")/../linux/inventory.sh"
STRICT=0
for a in "$@"; do case $a in --strict) STRICT=1 ;; *) SCRIPT=$a ;; esac; done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0

have() { command -v "$1" >/dev/null 2>&1; }
chk() {  # chk "название" "подробности при ошибке" команда...
    local name=$1 detail=$2; shift 2
    if "$@"; then printf '  \e[32mOK\e[0m    %s\n' "$name"
    else printf '  \e[31mFAIL\e[0m  %s — %s\n' "$name" "$detail"; FAILS=$((FAILS + 1)); fi
}
near() { awk -v a="$1" -v b="$2" -v d="$3" 'BEGIN { x = a - b; if (x < 0) x = -x; exit !(x <= d) }'; }
if have jq; then
    jtop() { jq -r --arg k "$2" '.[$k] | if type == "array" then length else tostring end' "$1"; }
    jsum() { jq -r --arg k "$2" '.summary[$k]' "$1"; }
    jcnt() { jq -r --arg s "$2" --arg p "$3" '[.details[] | select(.Section == $s and (.Name | startswith($p)))] | length' "$1"; }
elif have python3 && python3 -c '' 2>/dev/null; then
    jtop() { python3 -c 'import json,sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print(len(v) if isinstance(v, list) else str(v).lower() if isinstance(v, bool) else v)' "$1" "$2"; }
    jsum() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"][sys.argv[2]])' "$1" "$2"; }
    jcnt() { python3 -c 'import json,sys; print(sum(1 for d in json.load(open(sys.argv[1]))["details"] if d["Section"] == sys.argv[2] and d["Name"].startswith(sys.argv[3])))' "$1" "$2" "$3"; }
else
    echo 'Нужен jq или python3'; exit 2
fi

printf '\n\e[36mПроверка %s\e[0m\n' "$SCRIPT"

# ---------- компьютер компании: сверка с независимыми источниками ----------
printf '\nРежим «компании»\n'
C=$TMP/company.json
bash "$SCRIPT" --owner company --skip-updates --json "$C" --csv "$TMP/company.csv" >/dev/null 2>&1
chk 'JSON-отчёт записан' 'файла нет' test -s "$C"
if [ -s "$C" ]; then
    v=$(jtop "$C" owner); chk 'owner = company' "owner = $v" [ "$v" = company ]
    v=$(jsum "$C" 'ПК'); h=$(hostname); chk 'имя ПК' "в отчёте «$v», hostname «$h»" [ "$v" = "$h" ]

    e=$(awk -F: '/^model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo | tr -s ' ')
    v=$(jsum "$C" CPU)
    if [ -n "$e" ]; then chk 'процессор совпадает с /proc/cpuinfo' "в отчёте «$v», cpuinfo «$e»" [ "$v" = "$e" ]; fi

    e=$(awk '/^MemTotal:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo); v=$(jsum "$C" 'ОЗУ ГБ')
    chk 'объём ОЗУ близок к MemTotal' "в отчёте $v ГБ, MemTotal $e ГБ" awk -v a="$v" -v b="$e" 'BEGIN { exit !(a >= int(b) && a <= b + 2.5) }'

    e=$(uname -r); v=$(jsum "$C" 'Сборка'); chk 'ядро совпадает с uname -r' "в отчёте «$v», uname «$e»" [ "$v" = "$e" ]
    # shellcheck disable=SC1091
    e=$(. /etc/os-release && echo "$PRETTY_NAME"); v=$(jsum "$C" 'Windows'); chk 'дистрибутив совпадает с os-release' "«$v» vs «$e»" [ "$v" = "$e" ]

    e=$(stat -f -c '%a %S' / | awk '{ printf "%.1f", $1 * $2 / 1073741824 }'); v=$(jsum "$C" 'C: свободно ГБ')
    chk 'свободно на / (stat -f)' "в отчёте $v ГБ, stat $e ГБ" near "$v" "$e" 1

    e=0
    for d in /sys/block/*; do
        case ${d##*/} in loop*|ram*|zram*|sr*|fd*|dm-*|md*|nbd*) continue ;; esac
        [ -e "$d/device" ] && e=$((e + 1))
    done
    v=$(jcnt "$C" 'Диски' 'Диск '); chk 'число дисков совпадает с /sys/block' "в отчёте $v, /sys/block $e" [ "$v" = "$e" ]

    v=$(jtop "$C" details); chk 'в отчёте больше 20 строк' "строк: $v" [ "$v" -gt 20 ]
    if [ "$(id -u)" = 0 ] && have dmidecode && dmidecode -t 17 2>/dev/null | grep -qE '^[[:space:]]Size: [0-9]+ [MGT]B'; then
        v=$(jsum "$C" 'ОЗУ распаяно/слоты'); chk 'модули памяти разобраны (dmidecode)' 'пусто' [ -n "$v" ]
    fi
    v=$(jtop "$C" incomplete)
    if [ "$STRICT" = 1 ] && [ "$(id -u)" = 0 ]; then chk 'под root нет неполных проверок' "неполных: $v" [ "$v" = 0 ]
    else printf '        root: %s; неполных проверок: %s\n' "$([ "$(id -u)" = 0 ] && echo да || echo нет)" "$v"; fi
fi

# ---------- личный ПК: ничего идентифицирующего ----------
printf '\nРежим «личный»\n'
P=$TMP/personal.json
bash "$SCRIPT" --owner personal --skip-updates --json "$P" --csv "$TMP/personal.csv" > "$TMP/personal.out" 2>&1
chk 'JSON и CSV записаны' 'файлов нет' test -s "$P" -a -s "$TMP/personal.csv"
if [ -s "$P" ]; then
    v=$(jtop "$P" owner); chk 'owner = personal' "owner = $v" [ "$v" = personal ]
    v=$(jsum "$P" 'ПК'); chk 'имя ПК в сводке скрыто' "ПК = $v" [ "${v#скрыто}" != "$v" ]
    cat "$TMP/personal.out" "$P" "$TMP/personal.csv" > "$TMP/all.txt"
    secrets=("$(hostname)" "${SUDO_USER:-$(id -un)}")
    [ -r /sys/class/dmi/id/product_serial ] && secrets+=("$(tr -d '\0' < /sys/class/dmi/id/product_serial | xargs)")
    have realm && secrets+=("$(realm list --name-only 2>/dev/null | head -1)")
    for x in "${secrets[@]}"; do
        [ "${#x}" -ge 4 ] || continue
        case $x in root|0*|'To be filled'*|'Default string'|'System Serial Number'|None|'Not Specified') continue ;; esac
        chk "нигде нет «$x»" 'найдено в выводе, CSV или JSON' bash -c '! grep -qiwF -- "$1" "$2"' _ "$x" "$TMP/all.txt"
    done
fi

# ---------- без терминала и без --owner ----------
printf '\nБез терминала и без --owner\n'
if have setsid; then
    N=$TMP/notty.json
    setsid -w bash "$SCRIPT" --skip-updates --json "$N" < /dev/null >/dev/null 2>&1
    v=$( [ -s "$N" ] && jtop "$N" owner ); chk 'считается личным ПК' "owner = ${v:-нет отчёта}" [ "$v" = personal ]
else
    printf '        пропущено: нет setsid\n'
fi

# ---------- запуск через stdin, как curl | bash ----------
printf '\nЗапуск через stdin (как curl | bash)\n'
S=$TMP/stdin.json
bash -s -- --owner company --skip-updates --json "$S" < "$SCRIPT" >/dev/null 2>&1
chk 'отчёт записан' 'JSON не записан' test -s "$S"

if [ "$FAILS" -gt 0 ]; then printf '\n\e[31mНе пройдено проверок: %d\e[0m\n' "$FAILS"; exit 1; fi
printf '\n\e[32mВсе проверки пройдены\e[0m\n'
