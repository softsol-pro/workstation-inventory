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

# ---------- разбор вывода kesl-control на примере (работает и без Kaspersky) ----------
# Пример составлен по документации KESL 12 (tests/fixtures/kesl-app-info.txt); на живом KESL формат стоит сверить.
printf '\nРазбор kesl-control --app-info (tests/fixtures)\n'
sed -n '1,/^main() {/p' "$SCRIPT" | sed '$d' > "$TMP/lib.sh"
# shellcheck disable=SC1091
. "$TMP/lib.sh"
IFS=$'\x1f' read -r kv kfp kdb kup <<< "$(kesl_parse < "$(dirname "$0")/fixtures/kesl-app-info.txt")"
chk 'версия' "«$kv»" [ "$kv" = 12.1.0.1297 ]
chk 'постоянная защита файлов' "«$kfp»" [ "$kfp" = Running ]
chk 'дата выпуска баз' "«$kdb» → «$(first_date "$kdb")»" [ "$(first_date "$kdb")" = '2026-10-19 21:04:00' ]
chk 'последний запуск обновления' "«$kup»" [ "$(first_date "$kup")" = '2026-10-20 06:00:12' ]
IFS=$'\x1f' read -r kv kfp kdb kup <<< "$(printf 'File Threat Protection: Stopped\n' | kesl_parse)"
chk 'выключенная защита распознаётся' "«$kfp»" [ "$kfp" = Stopped ]

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

    # серийники дисков — сверка с /sys/block/*/device/serial (у NVMe и части SCSI), независимо от lsblk
    have jq && for d in /sys/block/*; do
        [ -r "$d/device/serial" ] || continue
        e=$(tr -d '\0' < "$d/device/serial" | xargs | sed -E 's/^(SN|S\/N|Serial)[: ]+//')
        [ "${#e}" -ge 4 ] || continue
        [[ $e =~ ^0+$ ]] && continue   # заглушка (так отдают виртуальные диски Azure)
        v=$(jq -r --arg n "Диск ${d##*/}" '[.details[] | select(.Name == $n) | .Value][0] // ""' "$C" 2>/dev/null)
        chk "серийник диска ${d##*/} совпадает с /sys" "в отчёте «$v», /sys «$e»" [ "${v#*"$e"}" != "$v" ]
    done
    v=$(jcnt "$C" 'Мониторы и периферия' 'Клавиатура'); chk 'строка про клавиатуру есть' "строк: $v" [ "$v" -ge 1 ]
    # если ядро видит настоящую клавиатуру (USB / Bluetooth / PS/2), отчёт не должен говорить «не найдена»
    e=$(awk '/^I:/ { b = $2 } /^N: Name=/ { n = tolower($0) } /^H: Handlers=/ { if ($0 ~ / kbd / && n ~ /keyboard/ && b ~ /Bus=(0003|0005|0011)/) c++ } END { print c + 0 }' /proc/bus/input/devices 2>/dev/null)
    if [ "${e:-0}" -gt 0 ] && have jq; then
        v=$(jq -r '[.details[] | select(.Name == "Клавиатура") | .Value][0] // ""' "$C")
        chk 'клавиатура из /proc/bus/input/devices попала в отчёт' "клавиатур в /proc: $e, в отчёте «$v»" [ "$v" != 'не найдена' ]
    fi
    v=$(jcnt "$C" 'Мониторы и периферия' 'Мышь'); chk 'строка про мышь есть' "строк: $v" [ "$v" -ge 1 ]
    have jq && jq -r '.details[] | select(.Name == "Клавиатура" or .Name == "Мышь / тачпад" or (.Name | startswith("Монитор"))) | "        \(.Name): \(.Value)"' "$C"
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
    [ -r /sys/class/dmi/id/board_serial ] && secrets+=("$(tr -d '\0' < /sys/class/dmi/id/board_serial | xargs)")
    while IFS= read -r x; do secrets+=("$x"); done < <(lsblk -dno SERIAL 2>/dev/null | xargs -n1 2>/dev/null)
    for x in /sys/class/power_supply/BAT*/serial_number; do [ -r "$x" ] && secrets+=("$(xargs < "$x")"); done
    for x in "${secrets[@]}"; do
        [ "${#x}" -ge 4 ] || continue
        case $x in root|0*|'To be filled'*|'Default string'|'System Serial Number'|None|'Not Specified') continue ;; esac
        chk "нигде нет «$x»" 'найдено в выводе, CSV или JSON' bash -c '! grep -qiwF -- "$1" "$2"' _ "$x" "$TMP/all.txt"
    done
fi

# ---------- CSV от старой версии: строка должна уйти в -v2.csv ----------
printf '\nCSV с колонками от старой версии\n'
printf '\xEF\xBB\xBF"Дата";"ПК"\r\n"x";"y"\r\n' > "$TMP/old.csv"
bash "$SCRIPT" --owner company --skip-updates --csv "$TMP/old.csv" >/dev/null 2>&1
v=$(wc -l < "$TMP/old.csv"); chk 'старый файл не тронут' "строк: $v" [ "$v" = 2 ]
chk 'строка записана в old-v2.csv с новыми колонками' 'old-v2.csv нет или заголовок другой' grep -q '"Клавиатура и мышь"' "$TMP/old-v2.csv"
bash "$SCRIPT" --owner company --skip-updates --csv "$TMP/old.csv" >/dev/null 2>&1
v=$(wc -l < "$TMP/old-v2.csv" 2>/dev/null); chk 'повторный запуск дописывает в тот же old-v2.csv' "строк в old-v2: $v" [ "$v" = 3 -a ! -e "$TMP/old-v3.csv" ]

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
