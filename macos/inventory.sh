#!/bin/bash
# inventory.sh — инвентаризация рабочего места (macOS)
# Железо, периферия, macOS и обновления, защита, антивирус, администраторы, домен / VPN.
# Скрипт только читает: в системе ничего не меняет (softwareupdate -l только показывает список).
#
# Запуск (лучше через sudo — тогда видны VPN-профили других пользователей):
#   sudo bash inventory.sh
#   sudo bash inventory.sh --skip-updates
#   sudo bash inventory.sh --owner company --config /Volumes/share/config.json --csv /Volumes/share/inventory.csv
#   sudo bash inventory.sh --json ./report.json
# Запуск одной строкой с GitHub — см. README.md
#
# Работает на системном bash 3.2 и стандартных утилитах macOS, внешних зависимостей нет.
# В начале скрипт спрашивает, чей это компьютер. Для личного ПК имя ПК, пользователь, серийники,
# учётки, имя домена, VPN-ключи и IP-адреса не собираются.

VERSION='1.1.0'

# ================= поддержка macOS =================
# ОБНОВЛЯТЬ РАЗ В ГОД — осенью, когда выходит новая macOS: дописать её номер в конец списка.
# Apple сроков официально не публикует; на практике обновления безопасности получают три последние версии.
MACOS_VERSIONS=(11 12 13 14 15 26 27)

# ================= вывод =================
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_HEAD=$'\033[36m'; C_DIM=$'\033[90m'; C_TITLE=$'\033[1;37m'; C_0=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_BAD=''; C_HEAD=''; C_DIM=''; C_TITLE=''; C_0=''
fi

ISSUES=(); INCOMPLETE=()
D_SEC=(); D_NAME=(); D_VAL=(); D_ST=()
SECTION=''
REPORT_KEYS=('Дата' 'ПК' 'Пользователь' 'Модель' 'Серийник' 'Тип' 'CPU' 'ОЗУ ГБ' 'ОЗУ распаяно/слоты' 'Диски' 'C: свободно ГБ'
    'Мониторы' 'Принтеры' 'ИБП/батарея' 'Windows' 'Сборка' 'Поддержка до' 'Последнее обновление' 'Ожидают обновлений'
    'Антивирус' 'Польз. админ' 'Домен/VPN' 'OpenVPN' 'Замечания')
REPORT_VALS=()

rset() { local i; for i in "${!REPORT_KEYS[@]}"; do if [ "${REPORT_KEYS[i]}" = "$1" ]; then REPORT_VALS[i]=$2; return; fi; done; }
section() { SECTION=$1; printf '\n%s=== %s ===%s\n' "$C_HEAD" "$1" "$C_0"; }
line() {
    local name=$1 value=$2 state=${3:-} issue=${4:-} color='' w
    D_SEC+=("$SECTION"); D_NAME+=("$name"); D_VAL+=("$value"); D_ST+=("$state")
    case $state in ok) color=$C_OK ;; warn) color=$C_WARN ;; bad) color=$C_BAD ;; esac
    if [ "${#name}" -gt 27 ]; then name="${name:0:26}…"; fi
    w=$((28 - ${#name})); [ "$w" -lt 1 ] && w=1
    printf '  %s%*s%s%s%s\n' "$name" "$w" '' "$color" "$value" "$C_0"
    if [ -n "$issue" ]; then ISSUES+=("$issue"); fi
}
note() { printf '%s%s%s\n' "$C_DIM" "$1" "$C_0"; }
warn_msg() { printf '%s%s%s\n' "$C_WARN" "$1" "$C_0"; }
err_msg() { printf '%s%s%s\n' "$C_BAD" "$1" "$C_0"; }
incomplete() { local x; for x in "${INCOMPLETE[@]}"; do [ "$x" = "$1" ] && return; done; INCOMPLETE+=("$1"); }

have() { command -v "$1" >/dev/null 2>&1; }
hide() { if [ "${PERSONAL:-0}" = 1 ]; then printf '%s' 'скрыто (личный ПК)'; else printf '%s' "$1"; fi; }
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
gb() { awk -v b="${1:-0}" 'BEGIN { printf "%.0f", b / 1073741824 }'; }
gb1() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'; }
pct() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b > 0) printf "%d", a / b * 100 + 0.5; else print 0 }'; }
now() { date +%s; }
iso_epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }   # 2026-10-14T07:00:00Z
fmt_epoch() { date -r "$1" +%d.%m.%Y 2>/dev/null; }
ymd_of() { date -r "$1" +%Y-%m-%d 2>/dev/null; }
join_by() { local sep=$1 out='' x; shift; for x in "$@"; do out="$out${out:+$sep}$x"; done; printf '%s' "$out"; }
ver_lt() {
    local -a a b; local i
    IFS=. read -ra a <<< "$1"; IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        if [ "${a[i]:-0}" -lt "${b[i]:-0}" ]; then return 0; fi
        if [ "${a[i]:-0}" -gt "${b[i]:-0}" ]; then return 1; fi
    done
    return 1
}
# значение поля «Ключ: значение» из текста system_profiler / diskutil (отступы и выравнивание пробелами не важны)
field() {
    awk -v k="$1" '{ l = $0; sub(/^[ \t]+/, "", l); n = index(l, ":"); if (n && substr(l, 1, n - 1) == k) { v = substr(l, n + 1); sub(/^[ \t]+/, "", v); if (v != "") { print v; exit } } }'
}
plist_get() { defaults read "$1" "$2" 2>/dev/null; }   # plist_get /путь/без/.plist Ключ
tcp_ok() { nc -z -G 1 -w 1 "$1" "$2" >/dev/null 2>&1; }
# run_to секунды файл команда... — запуск с таймаутом (в macOS нет timeout)
run_to() {
    local t=$1 out=$2 pid w rc; shift 2
    "$@" > "$out" 2>/dev/null &
    pid=$!
    ( sleep "$t"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    w=$!
    wait "$pid"; rc=$?
    kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    return $rc
}

usage() {
    cat <<'EOF'
Использование: inventory.sh [--owner company|personal] [--config путь|https-URL] [--csv файл] [--json файл] [--skip-updates]
  --owner         чей компьютер: company или personal; если не указан, скрипт спросит (без терминала — считает личным)
  --config        конфиг организации (JSON); без него домен/VPN/антивирус только показываются, без сравнения
  --csv           дописать строку по этому ПК в общую таблицу (разделитель ";", UTF-8 с BOM)
  --json          сохранить полный отчёт в JSON
  --skip-updates  не проверять доступные обновления (быстрее, softwareupdate -l идёт до пары минут)
EOF
}

# ================= конфиг =================
# Разбор JSON: jq (есть в macOS 15+), иначе plutil (есть всегда). python3 не трогаем:
# без Command Line Tools системный python3 открывает окно установки.
CFG_FILE=''; CFG_TOOL=''
load_config() {
    local src=$1 raw
    case $src in
        https://*) raw=$(curl -fsSL --max-time 15 "$src" 2>/dev/null) || { err_msg "Не удалось скачать конфиг $src"; return 1; } ;;
        *://*) err_msg "Конфиг: поддерживается только https:// ($src)"; return 1 ;;
        *) raw=$(cat -- "$src" 2>/dev/null) || { err_msg "Не удалось прочитать конфиг $src"; return 1; } ;;
    esac
    raw=${raw#$'\xEF\xBB\xBF'}
    CFG_FILE=$(mktemp -t inventory-cfg) || return 1
    printf '%s' "$raw" > "$CFG_FILE"
    if have jq && jq -e 'type == "object"' "$CFG_FILE" >/dev/null 2>&1; then CFG_TOOL=jq
    elif plutil -lint "$CFG_FILE" >/dev/null 2>&1 && [ "$(plutil -type . "$CFG_FILE" 2>/dev/null)" = dictionary ]; then CFG_TOOL=plutil
    elif plutil -lint "$CFG_FILE" >/dev/null 2>&1; then CFG_TOOL=plutil
    else err_msg "Конфиг $src — не JSON-объект"; return 1; fi
}
cfg_get() {  # значение поля; массив — по элементу в строке
    local i=0 v
    case $CFG_TOOL in
        jq) jq -r --arg k "$1" '.[$k] // empty | if type == "array" then .[] else . end | tostring' "$CFG_FILE" 2>/dev/null ;;
        plutil)
            if v=$(plutil -extract "$1" raw -o - "$CFG_FILE" 2>/dev/null); then printf '%s\n' "$v"; return; fi
            while v=$(plutil -extract "$1.$i" raw -o - "$CFG_FILE" 2>/dev/null); do printf '%s\n' "$v"; i=$((i + 1)); done ;;
    esac
}

# ================= CSV / JSON =================
csv_q() { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }
write_csv() {
    local f=$1 hdr='' row='' i
    for i in "${!REPORT_KEYS[@]}"; do hdr="$hdr$(csv_q "${REPORT_KEYS[i]}");"; row="$row$(csv_q "${REPORT_VALS[i]:-}");"; done
    hdr=${hdr%;}; row=${row%;}
    {
        if [ ! -s "$f" ]; then printf '\xEF\xBB\xBF%s\r\n' "$hdr"; fi
        printf '%s\r\n' "$row"
    } >> "$f"
}
json_s() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}
json_n() { if [ -n "$1" ]; then json_s "$1"; else printf 'null'; fi; }
json_arr() { local out='' x; for x in "$@"; do out="$out${out:+, }$(json_s "$x")"; done; printf '[%s]' "$out"; }
write_json() {
    local f=$1 i sum='' det='' adm=false cfg=false nl=$'\n'
    [ "$IS_ROOT" = 1 ] && adm=true
    [ -n "$CFG_TOOL" ] && cfg=true
    for i in "${!REPORT_KEYS[@]}"; do sum="$sum${sum:+,$nl}    $(json_s "${REPORT_KEYS[i]}"): $(json_s "${REPORT_VALS[i]:-}")"; done
    for i in "${!D_NAME[@]}"; do
        det="$det${det:+,$nl}    {\"Section\": $(json_s "${D_SEC[i]}"), \"Name\": $(json_s "${D_NAME[i]}"), \"Value\": $(json_s "${D_VAL[i]}"), \"State\": $(json_n "${D_ST[i]}")}"
    done
    {
        printf '{\n'
        printf '  "version": %s,\n  "os": "macos",\n  "owner": %s,\n  "generated": %s,\n' "$(json_s "$VERSION")" "$(json_s "$OWNER")" "$(json_s "$(date +%Y-%m-%dT%H:%M:%S)")"
        printf '  "isAdmin": %s,\n  "configUsed": %s,\n' "$adm" "$cfg"
        printf '  "summary": {\n%s\n  },\n' "$sum"
        printf '  "issues": %s,\n' "$(json_arr "${ISSUES[@]}")"
        printf '  "incomplete": %s,\n' "$(json_arr "${INCOMPLETE[@]}")"
        printf '  "details": [\n%s\n  ]\n}\n' "$det"
    } > "$f"
}

# ================= память: распайка или слот =================
# Те же правила, что в Windows / Linux; для Mac сначала смотрим, что говорит сама Apple (Upgradeable Memory).
CHIP_PN='^(K4[A-Z0-9]|H5[A-Z]|H9[A-Z]|HKN|MT(40|41|46|52|53|60|61|62)[A-Z]|NT5|NT6|CXDB)'
MODULE_PN='^(M3[79][0-9]|M47[0-9]|HMA|HMT|HMCG|HMAA|MTA|MTC|KVR|KF[0-9]|KCP|KHX|KTD|KTH|KTL|ACR[0-9]|CT[0-9]|BL[0-9]|F[345]-|CM[A-Z]|AD[45]|AX[45]|HX[45]|TF[0-9]|TED|SP0|RMSA|RMUA|99U5)'
mem_verdict() {  # тип part_number серийник повтор(0/1) → MV_TEXT, MV_KIND, MV_SURE
    local pn sn=$3
    pn=$(trim "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')")
    case $sn in 'Not Specified'|Unknown|None|'[Empty]'|-) sn='' ;; esac
    MV_SURE=1
    if [[ $1 == LPDDR* ]]; then MV_TEXT='распайка (LPDDR)'; MV_KIND=sold
    elif [[ $pn =~ $CHIP_PN ]]; then MV_TEXT='распайка (номер микросхемы)'; MV_KIND=sold
    elif [[ $pn =~ $MODULE_PN ]]; then MV_TEXT='съёмная плашка (номер модуля)'; MV_KIND=slot
    else
        MV_SURE=0
        if [[ $sn =~ ^0*$ ]] || [ "$4" = 1 ]; then MV_TEXT='скорее распайка (серийник пустой / повторяется)'; MV_KIND=sold
        else MV_TEXT='не определить'; MV_KIND=unknown; fi
    fi
}
hex_ascii() {  # 0x484D41... → HMA...
    local h=${1#0x} out='' i
    [[ $1 == 0x* ]] && [[ $h =~ ^[0-9A-Fa-f]+$ ]] && [ $(( ${#h} % 2 )) = 0 ] || { printf '%s' "$1"; return; }
    for ((i = 0; i < ${#h}; i += 2)); do out="$out\\x${h:i:2}"; done
    printf '%b' "$out" | tr -d '\000' | tr -cd '[:print:]'
}
jedec() { case $1 in 0x80AD|0x00AD) echo 'SK Hynix' ;; 0x80CE|0x00CE) echo Samsung ;; 0x802C|0x002C) echo Micron ;; 0x0198|0x8198) echo Kingston ;; *) echo "$1" ;; esac; }

main() {
    exec 0</dev/null   # при запуске через curl | bash не даём командам читать остаток скрипта из stdin
    if locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then export LC_ALL=en_US.UTF-8; fi

    local l
    OWNER=''; CONFIG=''; CSV=''; JSON=''; SKIP_UPD=0
    while [ $# -gt 0 ]; do
        case $1 in
            --owner)        OWNER=${2:-}; shift; [ $# -gt 0 ] && shift ;;
            --owner=*)      OWNER=${1#*=}; shift ;;
            --config)       CONFIG=${2:-}; shift; [ $# -gt 0 ] && shift ;;
            --config=*)     CONFIG=${1#*=}; shift ;;
            --csv)          CSV=${2:-}; shift; [ $# -gt 0 ] && shift ;;
            --csv=*)        CSV=${1#*=}; shift ;;
            --json)         JSON=${2:-}; shift; [ $# -gt 0 ] && shift ;;
            --json=*)       JSON=${1#*=}; shift ;;
            --skip-updates) SKIP_UPD=1; shift ;;
            -h|--help)      usage; return 0 ;;
            *)              err_msg "Неизвестный параметр: $1"; usage; return 2 ;;
        esac
    done

    CORP_DOMAIN=''; DCS=(); VPN_PREFIX=''; EXTRA_ROUTE=''; MIN_OVPN='2.6.0'; KEY_PATTERN=''; EXPECTED_AV=''
    CFG_LOADED=0
    if [ -n "$CONFIG" ] && load_config "$CONFIG"; then
        CFG_LOADED=1
        CORP_DOMAIN=$(cfg_get domain)
        while IFS= read -r l; do [ -n "$l" ] && DCS+=("$l"); done < <(cfg_get dcs)
        VPN_PREFIX=$(cfg_get vpnTunnelPrefix)
        EXTRA_ROUTE=$(cfg_get vpnExtraRouteIp)
        l=$(cfg_get minOpenVpn); [[ $l =~ ^[0-9]+(\.[0-9]+)*$ ]] && MIN_OVPN=$l
        KEY_PATTERN=$(cfg_get corpVpnKeyPattern)
        EXPECTED_AV=$(cfg_get expectedAv)
        if [ -n "$KEY_PATTERN" ]; then
            [[ x =~ $KEY_PATTERN ]]
            if [ $? -eq 2 ]; then err_msg 'corpVpnKeyPattern в конфиге — неверный регэксп, проверка чужих ключей отключена'; KEY_PATTERN=''; fi
        fi
    fi
    [ -n "$CFG_FILE" ] && rm -f "$CFG_FILE"

    IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
    RUSER=${SUDO_USER:-}
    [ -z "$RUSER" ] && RUSER=$(stat -f %Su /dev/console 2>/dev/null)
    { [ -z "$RUSER" ] || [ "$RUSER" = root ]; } && RUSER=$(id -un)
    HOST=$(scutil --get ComputerName 2>/dev/null || hostname)

    # ================= чей компьютер =================
    # Личный ПК: железо, ОС, обновления и защита — собираем; имя ПК, пользователь, серийники, учётки,
    # имя домена, VPN-ключи и IP-адреса — нет (в консоли, CSV и JSON вместо них «скрыто»)
    local owner_note=''
    case $(lower "$OWNER") in
        company|компании|1) OWNER=company ;;
        personal|личный|2) OWNER=personal ;;
        '') ;;
        *) err_msg "Неизвестное значение --owner '$OWNER' (нужно company или personal)"; OWNER='' ;;
    esac
    if [ -z "$OWNER" ]; then
        # stdin при curl | bash занят самим скриптом, поэтому спрашиваем через терминал
        if { : < /dev/tty; } 2>/dev/null; then
            for _ in 1 2 3; do
                printf '\nЭто компьютер компании или личный? 1 — компании, 2 — личный: ' > /dev/tty
                IFS= read -r l < /dev/tty || break
                case $(lower "$l") in
                    1|к|компании|company) OWNER=company; break ;;
                    2|л|личный|personal) OWNER=personal; break ;;
                esac
            done
        fi
        if [ -z "$OWNER" ]; then
            OWNER=personal
            owner_note='Не удалось спросить, чей это ПК, — считаю личным. Для учёта ПК компании запустите с --owner company'
        fi
    fi
    PERSONAL=0; [ "$OWNER" = personal ] && PERSONAL=1

    rset 'Дата' "$(date '+%Y-%m-%d %H:%M')"
    rset 'ПК' "$(hide "$HOST")"

    printf '\n%sИнвентаризация %s — %s (macos/inventory.sh %s)%s\n' "$C_TITLE" "$([ "$PERSONAL" = 1 ] && echo 'личного ПК' || echo "$HOST")" "$(date '+%d.%m.%Y %H:%M')" "$VERSION" "$C_0"
    [ -n "$owner_note" ] && warn_msg "$owner_note"
    if [ "$PERSONAL" = 1 ]; then note 'Личный ПК: имя ПК, пользователь, серийники, учётки, домен, VPN-ключи и IP-адреса не собираются'
    else note 'Компьютер компании: собирается полный отчёт'; fi
    [ "$IS_ROOT" = 1 ] || warn_msg 'Запущено без sudo — VPN-профили других пользователей не видны'
    if [ "$CFG_LOADED" = 1 ]; then note "Конфиг: $([ "$PERSONAL" = 1 ] && echo 'загружен' || echo "$CONFIG") (разобран через $CFG_TOOL)"
    elif [ -n "$CONFIG" ]; then warn_msg 'Конфиг не загружен — домен, VPN и антивирус проверяются без сравнения с ожидаемыми значениями'
    else note 'Без конфига — домен, VPN и антивирус проверяются без сравнения с ожидаемыми значениями'; fi

    # ================= общее =================
    local hw arch model mid serial is_laptop=0 boot up up_d up_h st
    hw=$(system_profiler SPHardwareDataType 2>/dev/null)
    arch=$(uname -m)
    model=$(field 'Model Name' <<< "$hw"); mid=$(field 'Model Identifier' <<< "$hw")
    serial=$(field 'Serial Number (system)' <<< "$hw")
    [ -z "$model" ] && model=$(sysctl -n hw.model 2>/dev/null)
    [ -z "$mid" ] && mid=$(sysctl -n hw.model 2>/dev/null)
    [[ $model == *MacBook* ]] && is_laptop=1
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/')
    up=$(( $(now) - ${boot:-$(now)} )); up_d=$((up / 86400)); up_h=$(((up % 86400) / 3600))

    section 'Общее'
    line 'Чей компьютер' "$([ "$PERSONAL" = 1 ] && echo личный || echo компании)"
    line 'Компьютер' "$(hide "$HOST")"
    line 'Пользователь' "$(hide "$RUSER")"
    line 'Производитель' 'Apple'
    line 'Модель' "${model:-нет данных}${mid:+ ($mid)}"
    line 'Серийный номер' "$(hide "${serial:-нет данных}")"
    line 'Тип' "$([ "$is_laptop" = 1 ] && echo Ноутбук || echo 'Настольный / прочее')"
    if [ "$up_d" -ge 14 ]; then st=warn; else st=ok; fi
    line 'Без перезагрузки' "$up_d дн. $up_h ч." "$st" "$([ "$st" = warn ] && echo 'Не перезагружался больше 2 недель')"
    rset 'Пользователь' "$(hide "$RUSER")"
    rset 'Модель' "Apple ${model}${mid:+ ($mid)}"
    rset 'Серийник' "$(hide "$serial")"
    rset 'Тип' "$([ "$is_laptop" = 1 ] && echo Ноутбук || echo ПК), $([ "$PERSONAL" = 1 ] && echo личный || echo компании)"

    # ================= процессор =================
    section 'Процессор'
    local cpu pc ec cores threads
    cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    [ -z "$cpu" ] && cpu=$(field 'Chip' <<< "$hw")
    cpu=$(trim "$(tr -s ' ' <<< "$cpu")")
    cores=$(sysctl -n hw.physicalcpu 2>/dev/null); threads=$(sysctl -n hw.logicalcpu 2>/dev/null)
    pc=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null); ec=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null)
    line 'Модель' "${cpu:-нет данных}$([ "$arch" = arm64 ] && echo ' (Apple Silicon)')"
    line 'Ядер / потоков' "${cores:-?}$([ -n "$pc" ] && [ -n "$ec" ] && echo " ($pc производительных + $ec энергоэффективных)") / ${threads:-?}"
    rset 'CPU' "$cpu"

    # ================= память =================
    section 'Оперативная память'
    local membytes total_gb vm ps pfree pinact pspec avail used_pct free_gb memtxt upg
    membytes=$(sysctl -n hw.memsize 2>/dev/null)
    total_gb=$(gb "$membytes")
    vm=$(vm_stat 2>/dev/null)
    ps=$(sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p' <<< "$vm"); ps=${ps:-4096}
    pfree=$(awk '/^Pages free/ { gsub(/\./, "", $3); print $3 }' <<< "$vm")
    pinact=$(awk '/^Pages inactive/ { gsub(/\./, "", $3); print $3 }' <<< "$vm")
    pspec=$(awk '/^Pages speculative/ { gsub(/\./, "", $3); print $3 }' <<< "$vm")
    avail=$(( (${pfree:-0} + ${pinact:-0} + ${pspec:-0}) * ps ))
    used_pct=$(pct $((membytes - avail)) "$membytes"); free_gb=$(gb1 "$avail")
    if [ "$total_gb" -lt 8 ]; then st=bad; elif [ "$total_gb" -lt 16 ]; then st=warn; else st=ok; fi
    line 'Всего' "$total_gb ГБ (занято $used_pct%, свободно $free_gb ГБ)" "$st" "$([ "$total_gb" -lt 8 ] && echo "Мало ОЗУ: $total_gb ГБ")"
    memtxt=$(system_profiler SPMemoryDataType 2>/dev/null)
    upg=$(field 'Upgradeable Memory' <<< "$memtxt")
    local sold=0 slot=0 unk=0 guess=0 mtype mmfr mpn msn msize mspeed bank sns='' v
    if [ "$arch" = arm64 ]; then
        # Apple Silicon: память в одном корпусе с процессором — всегда распайка
        mtype=$(field 'Type' <<< "$memtxt"); mmfr=$(field 'Manufacturer' <<< "$memtxt")
        line 'Встроенная' "$total_gb ГБ ${mtype:-?} | ${mmfr:-?} | распайка (Apple Silicon, память в корпусе процессора)"
        sold=$total_gb
    else
        while IFS=$'\t' read -r bank msize mtype mspeed mmfr mpn msn; do
            [ -n "$bank" ] || continue
            case $msize in *GB) msize=${msize%% *} ;; *MB) msize=$(( ${msize%% *} / 1024 )) ;; *) continue ;; esac
            mpn=$(hex_ascii "$mpn"); mmfr=$(jedec "$mmfr")
            if [ "$upg" = No ]; then MV_TEXT='распайка (Apple: память не расширяется)'; MV_KIND=sold; MV_SURE=1
            elif [ "$upg" = Yes ]; then MV_TEXT='съёмная плашка (Apple: память расширяется)'; MV_KIND=slot; MV_SURE=1
            else
                v=0; [ -n "$msn" ] && [[ $sns == *"|$msn|"* ]] && v=1
                mem_verdict "$mtype" "$mpn" "$msn" "$v"
            fi
            sns="$sns|$msn|"
            case $MV_KIND in sold) sold=$((sold + msize)) ;; slot) slot=$((slot + msize)) ;; *) unk=$((unk + msize)) ;; esac
            [ "$MV_SURE" = 1 ] || guess=1
            line "$bank" "$msize ГБ $mtype-${mspeed%% *} | $mmfr $mpn | $MV_TEXT"
        done < <(awk '
            function out() { if (b != "") print b "\t" r["Size"] "\t" r["Type"] "\t" r["Speed"] "\t" r["Manufacturer"] "\t" r["Part Number"] "\t" r["Serial Number"] }
            /^ +(BANK|DIMM|ChannelA|ChannelB).*:$/ || /^ +[^:]*DIMM[^:]*:$/ { out(); b = $0; sub(/^ +/, "", b); sub(/:$/, "", b); split("", r); next }
            b != "" { l = $0; sub(/^[ \t]+/, "", l); n = index(l, ": "); if (n) r[substr(l, 1, n - 1)] = substr(l, n + 2) }
            END { out() }' <<< "$memtxt")
        [ $((sold + slot + unk)) = 0 ] && line 'Модули' 'нет данных (system_profiler не вернул модули)'
    fi
    v="распаяно $sold ГБ, в слотах $slot ГБ"
    [ "$unk" -gt 0 ] && v="$v, не определено $unk ГБ"
    [ "$guess" = 1 ] && v="$v (часть — оценка)"
    [ -n "$upg" ] && v="$v | Apple: память расширяется — $([ "$upg" = Yes ] && echo да || echo нет)"
    line 'Итого' "$v"
    rset 'ОЗУ ГБ' "$total_gb"
    rset 'ОЗУ распаяно/слоты' "$sold/$slot$([ "$unk" -gt 0 ] && echo "/?$unk")$([ "$guess" = 1 ] && echo ' (оценка)')"

    # ================= диски =================
    section 'Диски'
    local dk di dname ssd dbytes proto loc smart dtype hs dlist=() dcount=0
    while IFS= read -r dk; do
        di=$(diskutil info "$dk" 2>/dev/null)
        dname=$(field 'Device / Media Name' <<< "$di"); ssd=$(field 'Solid State' <<< "$di")
        dbytes=$(field 'Disk Size' <<< "$di" | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p')
        proto=$(field 'Protocol' <<< "$di"); loc=$(field 'Device Location' <<< "$di"); smart=$(field 'SMART Status' <<< "$di")
        if [ "$ssd" = Yes ]; then
            case $proto in *PCI*|*Fabric*|*NVMe*) dtype='SSD NVMe' ;; *) dtype=SSD ;; esac
        elif [ "$ssd" = No ]; then dtype=HDD; else dtype='?'; fi
        case $smart in Verified) hs=ok ;; Failing) hs=bad ;; *) hs=''; smart="SMART: ${smart:-нет данных}" ;; esac
        dcount=$((dcount + 1))
        line "Диск ${dk#/dev/}" "${dname:-?} | $dtype | $(gb "$dbytes") ГБ | ${proto:-?} | ${loc:-?} | $smart" "$hs" "$([ "$hs" = bad ] && echo "Диск ${dname:-$dk}: SMART $smart")"
        [ "$proto" = USB ] || dlist+=("$dtype $(gb "$dbytes") ГБ")
    done < <(diskutil list physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ { print $1 }')
    [ "$dcount" = 0 ] && line 'Диски' 'не определены'
    local mp dsize davail f s fp
    mp=/System/Volumes/Data; [ -d "$mp" ] || mp=/
    read -r dsize davail <<< "$(df -k "$mp" 2>/dev/null | awk 'NR == 2 { print $2 * 1024, $4 * 1024 }')"
    if [ -n "$dsize" ]; then
        f=$(gb1 "$davail"); s=$(gb "$dsize"); fp=$(pct "$davail" "$dsize")
        if awk -v f="$f" -v p="$fp" 'BEGIN { exit !(f < 10 || p < 10) }'; then st=bad
        elif awk -v f="$f" -v p="$fp" 'BEGIN { exit !(f < 25 || p < 20) }'; then st=warn
        else st=ok; fi
        line 'Том Macintosh HD (система)' "свободно $f из $s ГБ ($fp%)" "$st" "$([ "$st" = bad ] && echo "Мало места на системном томе: $f ГБ")"
        rset 'C: свободно ГБ' "$f"
    fi
    rset 'Диски' "$(join_by ' + ' "${dlist[@]}")"

    # ================= периферия =================
    section 'Мониторы и периферия'
    local mname msn mconn mdt mons=() i=0
    while IFS='|' read -r mname msn mconn mdt; do
        [ -n "$mname" ] || continue
        i=$((i + 1))
        if [ "$mconn" = Internal ] || [[ $mdt == *Built-in* ]]; then mconn='встроенный'; else mconn='внешний'; fi
        line "Монитор $i" "$mname | S/N $(hide "${msn:-?}") | $mconn"
        mons+=("$mname")
    done < <(system_profiler SPDisplaysDataType 2>/dev/null | awk '
        function out() { if (name != "") print name "|" sn "|" conn "|" dt; name = ""; sn = ""; conn = ""; dt = "" }
        { i = match($0, /[^ ]/) }
        /^ *Displays:$/ { out(); ind = i; d = 1; next }
        d && i > 0 && i <= ind { out(); d = 0 }
        d && i == ind + 2 && /:$/ { out(); name = substr($0, i); sub(/:$/, "", name); next }
        d && i > ind + 2 { l = substr($0, i); n = index(l, ": "); k = substr(l, 1, n - 1); v = substr(l, n + 2)
            if (k == "Display Serial Number") sn = v; else if (k == "Connection Type") conn = v; else if (k == "Display Type") dt = v }
        END { out() }')
    [ "$i" = 0 ] && line 'Мониторы' 'не определены'
    rset 'Мониторы' "$(join_by ', ' "${mons[@]}")"

    local skip='PDF|XPS|Fax|Факс|Send To|AnyDesk|Snagit' pdef pn uri how prns=()
    if have lpstat; then
        pdef=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
        while IFS=$'\t' read -r pn uri; do
            [ -n "$pn" ] || continue
            [[ $pn =~ $skip ]] && continue
            case $uri in
                usb:*) how=USB ;;
                dnssd:*|mdns:*) how='по сети (Bonjour)' ;;
                ipp:*|ipps:*|http:*|https:*|socket:*|lpd:*|smb:*)
                    if [ "$PERSONAL" = 1 ]; then how="по сети (${uri%%:*})"; else how="по сети (${uri%%:*} ${uri#*://})"; fi ;;
                *) if [ "$PERSONAL" = 1 ]; then how='другое подключение'; else how=$uri; fi ;;
            esac
            line 'Принтер / МФУ' "$pn | $how$([ "$pn" = "$pdef" ] && echo ' | по умолчанию')"
            prns+=("$pn")
        done < <(lpstat -v 2>/dev/null | awk '/^device for / { sub(/^device for /, ""); n = index($0, ": "); print substr($0, 1, n - 1) "\t" substr($0, n + 2) }')
    fi
    [ "${#prns[@]}" -eq 0 ] && line 'Принтер / МФУ' 'нет'
    rset 'Принтеры' "$(join_by ', ' "${prns[@]}")"

    local pw bcharge bmax bcyc bcond braw bdes wst ups=''
    ups=$(pmset -g ps 2>/dev/null | awk '/^ -/ && !/InternalBattery/ { sub(/^ -/, ""); sub(/ \(id=.*/, ""); print; exit }')
    if [ "$is_laptop" = 1 ]; then
        pw=$(system_profiler SPPowerDataType 2>/dev/null)
        bcharge=$(pmset -g batt 2>/dev/null | sed -n 's/.*[[:space:]]\([0-9]*\)%;.*/\1/p' | head -1)
        bmax=$(field 'Maximum Capacity' <<< "$pw"); bmax=${bmax%\%}
        bcyc=$(field 'Cycle Count' <<< "$pw"); bcond=$(field 'Condition' <<< "$pw")
        if [ -z "$bmax" ]; then
            braw=$(ioreg -rn AppleSmartBattery 2>/dev/null | awk -F' = ' '/"AppleRawMaxCapacity"/ { print $2; exit }')
            bdes=$(ioreg -rn AppleSmartBattery 2>/dev/null | awk -F' = ' '/"DesignCapacity"/ { print $2; exit }')
            [ -n "$braw" ] && [ "${bdes:-0}" -gt 0 ] && bmax=$(pct "$braw" "$bdes")
        fi
        if [ -n "$bcharge$bmax" ]; then
            if { [ -n "$bmax" ] && [ "$bmax" -lt 60 ]; } || [[ $bcond == *Service* ]]; then wst=warn; else wst=ok; fi
            line 'Батарея' "заряд ${bcharge:-?}%${bmax:+, ёмкость $bmax% от заводской}${bcyc:+, циклов $bcyc}${bcond:+, состояние: $bcond}" "$wst"
            rset 'ИБП/батарея' "$([ -n "$bmax" ] && echo "батарея $bmax%" || echo батарея)"
        else
            line 'Батарея' 'нет данных'
        fi
        [ -n "$ups" ] && line 'ИБП' "$ups" ok
    else
        if [ -n "$ups" ]; then line 'ИБП' "$ups" ok; rset 'ИБП/батарея' "$ups"
        else line 'ИБП' 'не обнаружен (или подключён без USB-кабеля)' warn; rset 'ИБП/батарея' 'нет'; fi
    fi

    # ================= macOS и обновления =================
    section 'macOS и обновления'
    local pname pver pbuild major idx=-1 n k
    pname=$(sw_vers -productName 2>/dev/null); pver=$(sw_vers -productVersion 2>/dev/null); pbuild=$(sw_vers -buildVersion 2>/dev/null)
    major=${pver%%.*}
    line 'Версия' "$pname $pver"
    line 'Сборка' "$pbuild (ядро Darwin $(uname -r))"
    rset 'Windows' "$pname $pver"
    rset 'Сборка' "$pbuild"
    n=${#MACOS_VERSIONS[@]}
    for k in "${!MACOS_VERSIONS[@]}"; do [ "${MACOS_VERSIONS[k]}" = "$major" ] && idx=$k; done
    if [ "$idx" -ge 0 ] && [ "$idx" -ge $((n - 3)) ]; then
        if [ "$idx" = $((n - 3)) ]; then
            line 'Поддержка Apple' 'старшая из трёх поддерживаемых — обновления безопасности примерно до осени следующего года, пора планировать переход' warn
            rset 'Поддержка до' 'до выхода следующей macOS'
        else
            line 'Поддержка Apple' 'версия актуальна (одна из трёх последних)' ok
            rset 'Поддержка до' 'актуальна'
        fi
    elif [ "$idx" -ge 0 ] || { [ -n "$major" ] && [ "$major" -lt "${MACOS_VERSIONS[0]}" ]; }; then
        line 'Поддержка Apple' 'ЗАКОНЧИЛАСЬ — версия старше трёх последних, обновления безопасности не выходят' bad "macOS $pver без обновлений безопасности"
        rset 'Поддержка до' 'закончилась'
    elif [ -n "$major" ]; then
        line 'Поддержка Apple' 'версия новее таблицы в скрипте — скорее всего, актуальная' ok
        rset 'Поддержка до' 'актуальна'
    else
        line 'Поддержка Apple' 'нет данных'
    fi

    # защита
    local fv sip gk fw sec
    fv=$(fdesetup status 2>/dev/null | head -1)
    case $fv in
        *'FileVault is On'*) line 'FileVault (шифрование)' 'включён' ok ;;
        *'FileVault is Off'*) line 'FileVault (шифрование)' 'ВЫКЛЮЧЕН' warn 'FileVault выключен — диск не зашифрован' ;;
        *) line 'FileVault (шифрование)' "нет данных${fv:+ ($fv)}" ;;
    esac
    sip=$(csrutil status 2>/dev/null)
    case $sip in
        *'status: enabled'*) line 'SIP (защита системы)' 'включена' ok ;;
        *'status: disabled'*) line 'SIP (защита системы)' 'ВЫКЛЮЧЕНА' bad 'System Integrity Protection выключена' ;;
        *) line 'SIP (защита системы)' 'нет данных' ;;
    esac
    gk=$(spctl --status 2>&1)
    case $gk in
        *'assessments enabled'*) line 'Gatekeeper' 'включён' ok ;;
        *'assessments disabled'*) line 'Gatekeeper' 'ВЫКЛЮЧЕН' warn 'Gatekeeper выключен — можно запускать неподписанные программы' ;;
        *) line 'Gatekeeper' 'нет данных' ;;
    esac
    fw=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
    case $fw in
        *enabled*) line 'Брандмауэр' 'включён' ok ;;
        *disabled*) line 'Брандмауэр' 'выключен' warn ;;
        *) line 'Брандмауэр' 'нет данных' ;;
    esac
    if [ "$arch" = arm64 ]; then line 'Защитный чип' 'Secure Enclave (Apple Silicon)' ok
    else
        sec=$(system_profiler SPiBridgeDataType 2>/dev/null | field 'Model Name')
        if [ -n "$sec" ]; then line 'Защитный чип' "$sec" ok; else line 'Защитный чип' 'нет (Mac без T2)' warn; fi
    fi

    # последнее обновление — история установок macOS (без обновлений баз XProtect и служебных данных)
    local hist last='' last_what='' le ld xp_last=''
    hist=$(plutil -convert xml1 -o - /Library/Receipts/InstallHistory.plist 2>/dev/null | awk '
        /<dict>/ { d = ""; nm = ""; pr = "" }
        /<key>/ { k = $0; gsub(/.*<key>|<\/key>.*/, "", k); next }
        /<date>/ && k == "date" { d = $0; gsub(/.*<date>|<\/date>.*/, "", d) }
        /<string>/ && k == "displayName" { nm = $0; gsub(/.*<string>|<\/string>.*/, "", nm) }
        /<string>/ && k == "processName" { pr = $0; gsub(/.*<string>|<\/string>.*/, "", pr) }
        /<\/dict>/ { if (d != "") print d "\t" pr "\t" nm; d = "" }')
    l=$(awk -F'\t' '($2 ~ /softwareupdate|Software Update|macOS Installer/) && $3 !~ /XProtect|MRT|Gatekeeper|Background|Data|Compatibility|Rosetta|Configuration/' <<< "$hist" | sort | tail -1)
    if [ -n "$l" ]; then last=${l%%$'\t'*}; last_what=${l##*$'\t'}; fi
    xp_last=$(awk -F'\t' '$3 ~ /XProtect/ { print $1 }' <<< "$hist" | sort | tail -1)
    if [ -n "$last" ] && le=$(iso_epoch "$last"); then
        ld=$(( ($(now) - le) / 86400 ))
        if [ "$ld" -gt 70 ]; then st=bad; elif [ "$ld" -gt 40 ]; then st=warn; else st=ok; fi
        line 'Последнее обновление' "$(fmt_epoch "$le") ($ld дн. назад)" "$st" "$([ "$st" = bad ] && echo "Обновления не ставились $ld дн.")"
        [ -n "$last_what" ] && line '' "$last_what"
        rset 'Последнее обновление' "$(ymd_of "$le")"
    else
        line 'Последнее обновление' 'не удалось определить' warn
    fi

    # доступные обновления — softwareupdate -l только показывает список, ничего не ставит
    local sutmp su labels=() t mac=0
    if [ "$SKIP_UPD" = 1 ]; then
        rset 'Ожидают обновлений' 'не проверялось'
    else
        note '  ...спрашиваю softwareupdate, это до 1–2 минут'
        sutmp=$(mktemp -t inventory-su)
        if run_to 150 "$sutmp" softwareupdate -l; then su=$(cat "$sutmp"); else su=$(cat "$sutmp"); [ -z "$su" ] && su='__fail__'; fi
        rm -f "$sutmp"
        if [ "$su" = '__fail__' ]; then
            line 'Доступные обновления' 'softwareupdate не ответил (нет сети?)' warn
            rset 'Ожидают обновлений' '?'
        else
            while IFS= read -r t; do [ -n "$t" ] && labels+=("$t"); done < <(sed -n 's/^.*Title: \([^,]*\),.*/\1/p' <<< "$su")
            if [ "${#labels[@]}" -eq 0 ]; then
                line 'Доступные обновления' 'нет — система актуальна' ok
            else
                for t in "${labels[@]}"; do [[ $t == *macOS* || $t == *Security* ]] && mac=1; done
                if [ "$mac" = 1 ]; then st=bad; else st=warn; fi
                line 'Доступные обновления' "можно обновить: ${#labels[@]} шт.$([ "$mac" = 1 ] && echo ', есть обновление macOS')" "$st" \
                    "$([ "$mac" = 1 ] && echo 'Не установлено обновление macOS')"
                for t in "${labels[@]:0:6}"; do line '' "• $t"; done
                grep -q 'Action: restart' <<< "$su" && line 'Перезагрузка' 'понадобится для установки обновлений'
            fi
            rset 'Ожидают обновлений' "${#labels[@]}"
        fi
    fi

    # ================= антивирус =================
    section 'Антивирус'
    local xp app aname avs=() avrx='Kaspersky|ESET|Sophos|Bitdefender|Norton|Avast|AVG|Malwarebytes|Intego|Trend Micro|Webroot|F-Secure|Dr\.Web|CrowdStrike|Falcon|SentinelOne|Defender|Jamf Protect|Avira|McAfee'
    xp=$(plist_get /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info CFBundleShortVersionString)
    [ -z "$xp" ] && xp=$(plist_get /System/Library/CoreServices/XProtect.bundle/Contents/Info CFBundleShortVersionString)
    if [ -n "$xp" ]; then
        if [ -n "$xp_last" ] && le=$(iso_epoch "$xp_last"); then
            ld=$(( ($(now) - le) / 86400 ))
            line 'XProtect (встроенный)' "версия $xp, базы от $(fmt_epoch "$le") ($ld дн.)" "$([ "$ld" -gt 30 ] && echo warn || echo ok)"
        else
            line 'XProtect (встроенный)' "версия $xp" ok
        fi
    else
        line 'XProtect (встроенный)' 'нет данных' warn
    fi
    for app in /Applications/*.app "/Applications/Utilities"/*.app; do
        [ -d "$app" ] || continue
        aname=${app##*/}; aname=${aname%.app}
        [[ $aname =~ $avrx ]] || continue
        if pgrep -if "$aname" >/dev/null 2>&1; then line "$aname" 'установлен, запущен' ok
        else line "$aname" 'установлен, не запущен' warn "$aname установлен, но не запущен"; fi
        avs+=("$aname")
    done
    if [ -n "$EXPECTED_AV" ]; then
        if printf '%s\n' "${avs[@]}" | grep -qiF -- "$EXPECTED_AV"; then
            rset 'Антивирус' "$(join_by ', ' "${avs[@]}")"
        else
            line "$EXPECTED_AV" 'не найден' bad "$EXPECTED_AV не установлен"
            rset 'Антивирус' "$EXPECTED_AV нет; найден: $(join_by ', ' XProtect "${avs[@]}")"
        fi
    else
        [ "${#avs[@]}" -eq 0 ] && line 'Сторонний антивирус' 'не найден (работает только встроенный XProtect)'
        rset 'Антивирус' "$(join_by ', ' XProtect "${avs[@]}")"
    fi

    # ================= администраторы =================
    section 'Администраторы'
    local adm uadm='' rootaa prl='' cnt
    adm=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/^GroupMembership: *//')
    local -a admv=()
    read -ra admv <<< "$adm"
    if [ "$PERSONAL" = 1 ]; then cnt=${#admv[@]}; line 'Группа admin' "учёток: $cnt (имена скрыты)"
    else line 'Группа admin' "$(join_by ', ' "${admv[@]}")"; fi
    if [ "$RUSER" = root ]; then
        line 'Пользователь — админ?' 'запущено от root, обычный пользователь не определён'
    else
        if dseditgroup -o checkmember -m "$RUSER" admin >/dev/null 2>&1; then uadm=1; else uadm=0; fi
        l=$RUSER; [ "$PERSONAL" = 1 ] && l='текущий пользователь'
        if [ "$uadm" = 1 ]; then line 'Пользователь — админ?' "ДА, $l (dseditgroup, с учётом вложенных групп)" bad "Пользователь $l — администратор"
        else line 'Пользователь — админ?' 'нет (dseditgroup, с учётом вложенных групп)' ok; fi
    fi
    case $uadm in 1) rset 'Польз. админ' 'ДА' ;; 0) rset 'Польз. админ' 'нет' ;; *) rset 'Польз. админ' '?' ;; esac
    rootaa=$(dscl . -read /Users/root AuthenticationAuthority 2>/dev/null)
    if [[ $rootaa == *ShadowHash* ]]; then line 'Учётка root' 'включена (вход по паролю возможен)' warn
    else line 'Учётка root' 'отключена' ok; fi
    if tcp_ok 127.0.0.1 22; then
        prl=$(cat /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config 2>/dev/null | awk 'tolower($1) == "permitrootlogin" { print tolower($2); exit }')
        line 'Удалённый вход (SSH)' 'включён' warn
        case ${prl:-prohibit-password} in
            yes) line 'Вход root по SSH' 'РАЗРЕШЁН (в том числе по паролю)' bad 'SSH: разрешён вход root по паролю' ;;
            prohibit-password|without-password|forced-commands-only) line 'Вход root по SSH' 'только по ключу' ok ;;
            *) line 'Вход root по SSH' 'запрещён' ok ;;
        esac
    else
        line 'Удалённый вход (SSH)' 'выключен' ok
    fi

    # ================= домен и VPN =================
    section 'Домен и VPN'
    local dom dnode dcok=() dc in_corp=0
    dom=$(dsconfigad -show 2>/dev/null | awk -F' = ' '/Active Directory Domain/ { print $2; exit }')
    dom=$(trim "$dom")
    for dc in "${DCS[@]}"; do tcp_ok "$dc" 389 && dcok+=("$dc"); done
    if [ -n "$CORP_DOMAIN" ]; then [ -n "$dom" ] && [ "$(lower "$dom")" = "$(lower "$CORP_DOMAIN")" ] && in_corp=1
    else [ -n "$dom" ] && in_corp=1; fi
    if [ "$in_corp" = 1 ]; then
        line 'Домен' "в домене $(hide "$dom") (Active Directory)" "$([ -n "$CORP_DOMAIN" ] && echo ok)"
        dnode=$(odutil show nodenames 2>/dev/null | awk '/Active Directory/ && /All Domains/ { print $NF; exit }')
        if [ "${#DCS[@]}" -eq 0 ]; then line 'Связь с доменом' "${dnode:-нет данных} (контроллеры в конфиге не заданы)"
        elif [ "${#dcok[@]}" -eq 0 ]; then line 'Связь с доменом' 'не проверено — DC недоступны'
        else
            case $dnode in
                Online) line 'Связь с доменом' 'в порядке' ok ;;
                Offline) line 'Связь с доменом' 'НАРУШЕНА — DC доступны, а узел AD офлайн' bad 'Нарушена связь с доменом' ;;
                *) line 'Связь с доменом' 'нет данных' ;;
            esac
        fi
    elif [ -n "$dom" ]; then line 'Домен' "в ДРУГОМ домене: $(hide "$dom")" warn 'Компьютер в чужом домене'
    else line 'Домен' 'не в домене' "$([ -n "$CORP_DOMAIN" ] && echo warn)"; fi
    if [ "$RUSER" != root ] && dscl . -read "/Users/$RUSER" OriginalNodeName >/dev/null 2>&1; then line 'Учётка пользователя' 'доменная (мобильная учётка AD)'
    else line 'Учётка пользователя' 'локальная'; fi

    local ovbin ovv='' tb tbv tbo cn vpn_app=0 ver_shown=0
    ovbin=$(command -v openvpn 2>/dev/null)
    for l in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn; do [ -z "$ovbin" ] && [ -x "$l" ] && ovbin=$l; done
    if [ -n "$ovbin" ]; then
        vpn_app=1
        [[ $("$ovbin" --version 2>/dev/null | head -1) =~ OpenVPN\ ([0-9]+\.[0-9]+\.[0-9]+) ]] && ovv=${BASH_REMATCH[1]}
    fi
    tb=/Applications/Tunnelblick.app
    if [ -d "$tb" ]; then
        vpn_app=1
        tbv=$(plist_get "$tb/Contents/Info" CFBundleShortVersionString)
        # Tunnelblick несёт свои сборки OpenVPN: берём самую новую
        tbo=$(find "$tb/Contents/Resources/openvpn" -maxdepth 1 -type d -name 'openvpn-*' 2>/dev/null | sed -n 's/.*openvpn-\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
        line 'Tunnelblick' "установлен, версия ${tbv:-?}${tbo:+ (OpenVPN $tbo)}"
        [ -z "$ovv" ] && ovv=$tbo
    fi
    cn=''
    for l in "/Applications/OpenVPN Connect/OpenVPN Connect.app" "/Applications/OpenVPN Connect.app"; do [ -d "$l" ] && cn=$l; done
    if [ -n "$cn" ]; then vpn_app=1; line 'OpenVPN Connect' "установлен, версия $(plist_get "$cn/Contents/Info" CFBundleShortVersionString)"; fi
    if [ -n "$ovv" ]; then
        if ver_lt "$ovv" "$MIN_OVPN"; then st=warn; else st=ok; fi
        line 'OpenVPN' "версия $ovv" "$st" "$([ "$st" = warn ] && echo "Старый OpenVPN $ovv — обновить до $MIN_OVPN+")"
        ver_shown=1
    fi
    if [ "$vpn_app" = 0 ]; then line 'OpenVPN' 'не установлен'; rset 'OpenVPN' 'нет'
    elif [ "$ver_shown" = 1 ]; then rset 'OpenVPN' "$ovv"
    else rset 'OpenVPN' "$([ -n "$cn" ] && echo Connect || echo '?')"; fi

    # профили: Tunnelblick (.tblk), OpenVPN Connect, /etc/openvpn и Homebrew; «Документы» и «Загрузки» не трогаем (запрос доступа TCC)
    local p cfgf txt remotes owner foreign has_route kuser name nprof=0
    [ "$IS_ROOT" = 1 ] || incomplete 'VPN-профили других пользователей'
    for p in /Users/*/Library/Application\ Support/Tunnelblick/Configurations/*.tblk \
             /Library/Application\ Support/Tunnelblick/Shared/*.tblk \
             /Users/*/Library/Application\ Support/OpenVPN\ Connect/profiles/*.ovpn \
             /etc/openvpn/*.conf /etc/openvpn/*.ovpn /opt/homebrew/etc/openvpn/*.conf /usr/local/etc/openvpn/*.conf; do
        [ -e "$p" ] || continue
        cfgf=$p
        if [ -d "$p" ]; then cfgf=$(find "$p" -name '*.ovpn' -o -name '*.conf' 2>/dev/null | head -1); fi
        txt=$(cat -- "$cfgf" 2>/dev/null)
        remotes=$(awk '$1 == "remote" { print $2 }' <<< "$txt" | paste -sd, - | sed 's/,/, /g')
        has_route=''
        [ -n "$EXTRA_ROUTE" ] && grep -qF -- "$EXTRA_ROUTE" <<< "$txt" && has_route=" | маршрут до $EXTRA_ROUTE есть"
        case $p in /Users/*) owner=${p#/Users/}; owner=${owner%%/*} ;; *) owner='общий' ;; esac
        name=${p##*/}; name=${name%.*}
        foreign=''
        if [ -n "$KEY_PATTERN" ] && [ "$owner" != 'общий' ] && [[ $name =~ $KEY_PATTERN ]] && [ -n "${BASH_REMATCH[1]:-}" ]; then
            kuser=$(trim "${BASH_REMATCH[1]}")
            if [[ $(lower "$owner") != "$(lower "$kuser")"* ]] && [[ $(lower "$kuser") != "$(lower "$owner")"* ]]; then foreign=$kuser; fi
        fi
        nprof=$((nprof + 1))
        if [ "$PERSONAL" = 1 ]; then
            line 'Ключ VPN' "$([ "$owner" = 'общий' ] && echo общий || echo 'в профиле пользователя') (имя и сервер скрыты)$has_route${foreign:+ | ЧУЖОЙ КЛЮЧ}" \
                "$([ -n "$foreign" ] && echo warn)" "$([ -n "$foreign" ] && echo 'Чужой VPN-ключ в профиле пользователя')"
        else
            line "Ключ ($owner)" "${p##*/} → ${remotes:-?}$has_route${foreign:+ | ЧУЖОЙ КЛЮЧ ($foreign)}" "$([ -n "$foreign" ] && echo warn)" \
                "$([ -n "$foreign" ] && echo "Чужой VPN-ключ у $owner: ${p##*/}")"
        fi
    done
    # встроенные VPN macOS (Системные настройки → VPN)
    local ns nn nsys=0
    while IFS= read -r l; do
        ns=$(sed -n 's/^[* ]*(\([^)]*\)).*/\1/p' <<< "$l"); nn=$(sed -n 's/.*"\(.*\)".*/\1/p' <<< "$l")
        [ -n "$nn" ] || continue
        nsys=$((nsys + 1))
        line 'VPN в настройках macOS' "$([ "$PERSONAL" = 1 ] && echo '(имя скрыто)' || echo "$nn") | $([ "$ns" = Connected ] && echo подключён || echo 'не подключён')"
    done < <(scutil --nc list 2>/dev/null | grep '"')
    if [ "$nprof" = 0 ] && [ "$vpn_app" = 1 ]; then line 'Профили VPN' 'не найдены' warn; fi

    local addrs ifc ip tun='' nst=0
    addrs=$(ifconfig 2>/dev/null | awk '/^[a-z]/ { i = $1; sub(/:$/, "", i) } /^[ \t]+inet / { print i, $2 }')
    if [ -n "$VPN_PREFIX" ]; then
        while read -r ifc ip; do [[ $ip == "$VPN_PREFIX"* ]] && { tun="$ifc $ip"; break; }; done <<< "$addrs"
        if [ -n "$tun" ]; then line 'VPN-туннель сейчас' "поднят, адрес $(hide "${tun#* }") (${tun%% *})" ok
        else line 'VPN-туннель сейчас' 'не поднят'; fi
    else
        while read -r ifc ip; do
            case $ifc in utun*|tun*|tap*|ppp*|ipsec*) line 'VPN-интерфейс поднят' "$ifc: $(hide "$ip")"; nst=1 ;; esac
        done <<< "$addrs"
        [ "$nst" = 0 ] && line 'VPN-туннель сейчас' 'не поднят (интерфейсов utun/tun/ppp с IPv4 нет)'
    fi
    if [ "${#DCS[@]}" -gt 0 ]; then
        if [ "${#dcok[@]}" -gt 0 ]; then line 'Контроллеры домена' "доступны: $(join_by ', ' "${dcok[@]}")" ok
        else line 'Контроллеры домена' 'недоступны (порт 389)' warn; fi
    fi

    local has_vpn=0 mode ms='' mi=''
    { [ "$vpn_app" = 1 ] && [ "$nprof" -gt 0 ]; } || [ "$nsys" -gt 0 ] && has_vpn=1
    if [ "$in_corp" = 1 ] && [ "$has_vpn" = 1 ]; then mode='в домене + VPN'; ms=ok
    elif [ "$in_corp" = 1 ]; then mode='в домене, без VPN (офис)'; ms=ok
    elif [ "$has_vpn" = 1 ]; then mode='НЕ в домене, только VPN'; ms=warn; mi='Не введён в домен, работает только по VPN'
    else mode='ни домена, ни VPN'; ms=bad; mi='Не в домене и без VPN'; fi
    # без конфига ожидаемого режима нет — просто показываем факт
    if [ -n "$CORP_DOMAIN" ]; then line 'Итог' "$mode" "$ms" "$mi"; else line 'Итог' "$mode"; fi
    rset 'Домен/VPN' "$mode"

    # ================= итог =================
    section 'Итог'
    if [ "${#ISSUES[@]}" -gt 0 ]; then
        printf '%s  Замечаний: %d%s\n' "$C_WARN" "${#ISSUES[@]}" "$C_0"
        for l in "${ISSUES[@]}"; do printf '%s  - %s%s\n' "$C_WARN" "$l" "$C_0"; done
    else
        printf '%s  Замечаний нет%s\n' "$C_OK" "$C_0"
    fi
    [ "${#INCOMPLETE[@]}" -gt 0 ] && warn_msg "  Неполные проверки (без sudo): $(join_by ', ' "${INCOMPLETE[@]}")"
    rset 'Замечания' "$(join_by '; ' "${ISSUES[@]}")"

    if [ -n "$CSV" ]; then
        if write_csv "$CSV" 2>/dev/null; then note "
  Строка добавлена в $([ "$PERSONAL" = 1 ] && echo "${CSV##*/}" || echo "$CSV")"; else err_msg "
  Не удалось записать CSV: $CSV"; fi
    fi
    if [ -n "$JSON" ]; then
        if write_json "$JSON" 2>/dev/null; then note "  Отчёт сохранён в $([ "$PERSONAL" = 1 ] && echo "${JSON##*/}" || echo "$JSON")"; else err_msg "  Не удалось записать JSON: $JSON"; fi
    fi
    echo
}

main "$@"
