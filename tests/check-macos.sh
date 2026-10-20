#!/bin/bash
# check-macos.sh — проверка достоверности macos/inventory.sh на этом Mac.
# Запускает инвентаризацию системным /bin/bash 3.2 в режимах «компании», «личный», без терминала
# и через stdin (как curl | bash) и сверяет результат с независимыми источниками
# (system_profiler, sysctl, SystemVersion.plist, diskutil). В системе ничего не меняет.
#
#   bash tests/check-macos.sh
#   sudo bash tests/check-macos.sh

SCRIPT="$(dirname "$0")/../macos/inventory.sh"
[ -n "${1:-}" ] && SCRIPT=$1
SH=/bin/bash
TMP=$(mktemp -d -t inv-check); trap 'rm -rf "$TMP"' EXIT
FAILS=0

have() { command -v "$1" >/dev/null 2>&1; }
chk() {  # chk "название" "подробности при ошибке" команда...
    local name=$1 detail=$2; shift 2
    if "$@"; then printf '  \033[32mOK\033[0m    %s\n' "$name"
    else printf '  \033[31mFAIL\033[0m  %s — %s\n' "$name" "$detail"; FAILS=$((FAILS + 1)); fi
}
near() { awk -v a="$1" -v b="$2" -v d="$3" 'BEGIN { x = a - b; if (x < 0) x = -x; exit !(x <= d) }'; }
field() { awk -v k="$1" '{ l = $0; sub(/^[ \t]+/, "", l); n = index(l, ":"); if (n && substr(l, 1, n - 1) == k) { v = substr(l, n + 1); sub(/^[ \t]+/, "", v); if (v != "") { print v; exit } } }'; }
# чтение JSON-отчёта: jq, иначе JavaScript через osascript (есть в любой macOS).
# plutil не подходит: в отчёте есть null, а у plist такого типа нет.
JXA_READ='ObjC.import("Foundation"); function load(p) { return JSON.parse($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null).js) }'
if have jq && jq -n 1 >/dev/null 2>&1; then
    jvalid() { jq empty "$1" 2>/dev/null; }
    jtop() { jq -r --arg k "$2" '.[$k] | if type == "array" then length else tostring end' "$1"; }
    jsum() { jq -r --arg k "$2" '.summary[$k]' "$1"; }
    jdet() { jq -r --arg n "$2" '[.details[] | select(.Name == $n) | .Value][0] // ""' "$1"; }
else
    jvalid() { osascript -l JavaScript -e "$JXA_READ"'; function run(a) { load(a[0]); return "ok" }' "$1" >/dev/null 2>&1; }
    jtop() { osascript -l JavaScript -e "$JXA_READ"'; function run(a) { var v = load(a[0])[a[1]]; return Array.isArray(v) ? v.length : String(v) }' "$1" "$2" 2>/dev/null; }
    jsum() { osascript -l JavaScript -e "$JXA_READ"'; function run(a) { return String(load(a[0]).summary[a[1]]) }' "$1" "$2" 2>/dev/null; }
    jdet() { osascript -l JavaScript -e "$JXA_READ"'; function run(a) { var d = load(a[0]).details.filter(function (x) { return x.Name == a[1] }); return d.length ? d[0].Value : "" }' "$1" "$2" 2>/dev/null; }
fi

printf '\n\033[36mПроверка %s (через %s, %s)\033[0m\n' "$SCRIPT" "$SH" "$($SH -c 'echo $BASH_VERSION')"

# ---------- компьютер компании: сверка с независимыми источниками ----------
printf '\nРежим «компании»\n'
C=$TMP/company.json
$SH "$SCRIPT" --owner company --skip-updates --json "$C" --csv "$TMP/company.csv" > "$TMP/company.out" 2>&1
chk 'JSON-отчёт записан' "файла нет; вывод: $(tail -3 "$TMP/company.out" | tr '\n' ' ')" test -s "$C"
if [ -s "$C" ]; then
    chk 'JSON корректный' 'файл не разбирается как JSON' jvalid "$C"
    v=$(jtop "$C" owner); chk 'owner = company' "owner = $v" [ "$v" = company ]
    e=$(scutil --get ComputerName 2>/dev/null || hostname); v=$(jsum "$C" 'ПК')
    chk 'имя компьютера' "в отчёте «$v», scutil «$e»" [ "$v" = "$e" ]

    hw=$(system_profiler SPHardwareDataType 2>/dev/null)
    if [ "$(uname -m)" = arm64 ]; then
        e=$(field 'Chip' <<< "$hw"); v=$(jsum "$C" CPU)
        chk 'процессор совпадает с system_profiler' "в отчёте «$v», system_profiler «$e»" [ "$v" = "$e" ]
    fi
    e=$(field 'Memory' <<< "$hw"); e=${e%% *}; v=$(jsum "$C" 'ОЗУ ГБ')
    [ -n "$e" ] && chk 'объём ОЗУ совпадает с system_profiler' "в отчёте $v ГБ, system_profiler $e ГБ" [ "$v" = "$e" ]

    e=$(sysctl -n kern.osversion); v=$(jsum "$C" 'Сборка'); chk 'сборка совпадает с kern.osversion' "«$v» vs «$e»" [ "$v" = "$e" ]
    e=$(defaults read /System/Library/CoreServices/SystemVersion ProductVersion 2>/dev/null); v=$(jsum "$C" 'Windows')
    chk 'версия совпадает с SystemVersion.plist' "«$v» не содержит «$e»" [ "${v%"$e"}" != "$v" ]

    e=$(diskutil info / 2>/dev/null | field 'Container Free Space' | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p')
    v=$(jsum "$C" 'C: свободно ГБ')
    if [ -n "$e" ]; then e=$(awk -v b="$e" 'BEGIN { printf "%.1f", b / 1073741824 }'); chk 'свободно на системном томе (diskutil)' "в отчёте $v ГБ, diskutil $e ГБ" near "$v" "$e" 2; fi

    e=$(diskutil list physical 2>/dev/null | grep -c '^/dev/disk'); v=$(jsum "$C" 'Диски')
    chk "диски найдены" "в отчёте «$v», diskutil физических: $e" [ -n "$v" -o "$e" = 0 ]
    # время без перезагрузки — по выводу uptime («up 3 days, 4:05» или «up 4:05»)
    e=$(uptime | sed -nE 's/.* up ([0-9]+) day.*/\1/p'); e=${e:-0}
    v=$(jdet "$C" 'Без перезагрузки'); v=${v%% *}
    chk 'дней без перезагрузки совпадает с uptime' "в отчёте «$v», uptime $e" near "${v:--999}" "$e" 1

    # тип учётки — по AuthenticationAuthority (у мобильных учёток AD там LocalCachedUser)
    u=${SUDO_USER:-$(id -un)}
    if dscl . -read "/Users/$u" AuthenticationAuthority 2>/dev/null | grep -q LocalCachedUser; then e='доменная'; else e='локальная'; fi
    v=$(jdet "$C" 'Учётка пользователя'); chk 'тип учётки пользователя' "в отчёте «$v», ожидалось «$e»" [ "${v#"$e"}" != "$v" ]

    v=$(jdet "$C" 'Клавиатура'); chk 'строка про клавиатуру есть' 'нет строки' [ -n "$v" ]
    # если ioreg видит HID-клавиатуру (Usage Page 1, Usage 6), отчёт не должен говорить «не найдена»
    e=$(ioreg -r -c IOHIDDevice -l -w0 -d 1 2>/dev/null | grep -c '"PrimaryUsage" = 6$')
    [ "${e:-0}" -gt 0 ] && chk 'клавиатура из ioreg попала в отчёт' "клавиатур в ioreg: $e, в отчёте «$v»" [ "$v" != 'не найдена' ]
    v=$(jdet "$C" 'Мышь / тачпад'); chk 'строка про мышь есть' 'нет строки' [ -n "$v" ]
    have jq && jq -n 1 >/dev/null 2>&1 && jq -r '.details[] | select(.Name == "Клавиатура" or .Name == "Мышь / тачпад" or (.Name | startswith("Монитор")) or (.Name | startswith("Диск "))) | "        \(.Name): \(.Value)"' "$C"
    v=$(jtop "$C" details); chk 'в отчёте больше 20 строк' "строк: $v" [ "$v" -gt 20 ]
    printf '        sudo: %s; неполных проверок: %s; замечаний: %s\n' "$([ "$(id -u)" = 0 ] && echo да || echo нет)" "$(jtop "$C" incomplete)" "$(jtop "$C" issues)"
fi

# ---------- личный ПК: ничего идентифицирующего ----------
printf '\nРежим «личный»\n'
P=$TMP/personal.json
$SH "$SCRIPT" --owner personal --skip-updates --json "$P" --csv "$TMP/personal.csv" > "$TMP/personal.out" 2>&1
chk 'JSON и CSV записаны' 'файлов нет' test -s "$P" -a -s "$TMP/personal.csv"
if [ -s "$P" ]; then
    v=$(jtop "$P" owner); chk 'owner = personal' "owner = $v" [ "$v" = personal ]
    v=$(jsum "$P" 'ПК'); chk 'имя ПК в сводке скрыто' "ПК = $v" [ "${v#скрыто}" != "$v" ]
    cat "$TMP/personal.out" "$P" "$TMP/personal.csv" > "$TMP/all.txt"
    u=${SUDO_USER:-$(id -un)}
    secrets=("$(scutil --get ComputerName 2>/dev/null)" "$(scutil --get LocalHostName 2>/dev/null)" "$(hostname -s)" "$u" "$(id -F "$u" 2>/dev/null)"
        "$(field 'Serial Number (system)' <<< "$(system_profiler SPHardwareDataType 2>/dev/null)")"
        "$(dsconfigad -show 2>/dev/null | awk -F' = ' '/Active Directory Domain/ { print $2; exit }')"
        "$(field 'Serial Number' <<< "$(system_profiler SPPowerDataType 2>/dev/null)")")
    while IFS= read -r x; do secrets+=("$x"); done < <(system_profiler SPNVMeDataType SPSerialATADataType 2>/dev/null | awk -F': ' '/Serial Number:/ { print $2 }')
    for x in "${secrets[@]}"; do
        [ "${#x}" -ge 4 ] || continue
        case $x in root|admin|0*|"Not Available") continue ;; esac
        chk "нигде нет «$x»" 'найдено в выводе, CSV или JSON' /bin/bash -c '! grep -qiwF -- "$1" "$2"' _ "$x" "$TMP/all.txt"
    done
fi

# ---------- CSV от старой версии: строка должна уйти в -v2.csv ----------
printf '\nCSV с колонками от старой версии\n'
printf '\xEF\xBB\xBF"Дата";"ПК"\r\n"x";"y"\r\n' > "$TMP/old.csv"
$SH "$SCRIPT" --owner company --skip-updates --csv "$TMP/old.csv" >/dev/null 2>&1
v=$(wc -l < "$TMP/old.csv" | tr -d ' '); chk 'старый файл не тронут' "строк: $v" [ "$v" = 2 ]
chk 'строка записана в old-v2.csv с новыми колонками' 'old-v2.csv нет или заголовок другой' grep -q '"Клавиатура и мышь"' "$TMP/old-v2.csv"
$SH "$SCRIPT" --owner company --skip-updates --csv "$TMP/old.csv" >/dev/null 2>&1
v=$(wc -l < "$TMP/old-v2.csv" 2>/dev/null | tr -d ' '); chk 'повторный запуск дописывает в тот же old-v2.csv' "строк в old-v2: $v" [ "$v" = 3 -a ! -e "$TMP/old-v3.csv" ]

# ---------- без терминала и без --owner ----------
printf '\nБез терминала и без --owner\n'
N=$TMP/notty.json
# новый сеанс без управляющего терминала (в macOS нет setsid — делаем через perl)
perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' "$SH" "$SCRIPT" --skip-updates --json "$N" < /dev/null >/dev/null 2>&1
v=$( [ -s "$N" ] && jtop "$N" owner ); chk 'считается личным ПК' "owner = ${v:-нет отчёта}" [ "$v" = personal ]

# ---------- запуск через stdin, как curl | bash ----------
printf '\nЗапуск через stdin (как curl | bash)\n'
S=$TMP/stdin.json
$SH -s -- --owner company --skip-updates --json "$S" < "$SCRIPT" >/dev/null 2>&1
chk 'отчёт записан' 'JSON не записан' test -s "$S"

if [ "$FAILS" -gt 0 ]; then printf '\n\033[31mНе пройдено проверок: %d\033[0m\n' "$FAILS"; exit 1; fi
printf '\n\033[32mВсе проверки пройдены\033[0m\n'
