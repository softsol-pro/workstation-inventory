#!/usr/bin/env bash
# inventory.sh — инвентаризация рабочего места (Linux)
# Железо, периферия, ОС и обновления, антивирус, администраторы, домен / OpenVPN.
# Скрипт только читает: в системе ничего не меняет (списки пакетов не обновляет — берёт из кэша).
#
# Запуск (лучше от root — тогда видно серийник, модули памяти, SMART, sudoers, чужие профили VPN):
#   sudo bash inventory.sh
#   sudo bash inventory.sh --skip-updates
#   sudo bash inventory.sh --config /mnt/share/config.json --csv /mnt/share/inventory.csv
#   sudo bash inventory.sh --json ./report.json
# Запуск одной строкой с GitHub — см. README.md
#
# Нужен bash 4+. Всё необязательное (dmidecode, smartctl, edid-decode, jq/python3, lpstat, upsc,
# nmcli, realm, ...) проверяется на наличие; если чего-то нет — в выводе будет «нет данных».

VERSION='1.0.1'

# ================= сроки поддержки дистрибутивов =================
# ОБНОВЛЯТЬ РАЗ В ГОД — когда выходит новая LTS Ubuntu / новый Debian.
# Ubuntu — конец стандартной поддержки (без Ubuntu Pro / ESM): https://ubuntu.com/about/release-cycle
# Debian — конец LTS: https://wiki.debian.org/LTS
# Где официально указан только месяц, стоит последний день этого месяца.
declare -A EOL=(
    [ubuntu:20.04]=2025-05-31
    [ubuntu:22.04]=2027-06-30
    [ubuntu:24.04]=2029-05-31
    [ubuntu:25.04]=2026-01-31
    [ubuntu:25.10]=2026-07-31
    [ubuntu:26.04]=2031-05-31
    [debian:10]=2024-06-30
    [debian:11]=2026-08-31
    [debian:12]=2028-06-30
    [debian:13]=2030-06-30
)

# ================= вывод =================
if [ -t 1 ]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_HEAD=$'\e[36m'; C_DIM=$'\e[90m'; C_TITLE=$'\e[1;37m'; C_0=$'\e[0m'
else
    C_OK=''; C_WARN=''; C_BAD=''; C_HEAD=''; C_DIM=''; C_TITLE=''; C_0=''
fi

ISSUES=(); INCOMPLETE=()
D_SEC=(); D_NAME=(); D_VAL=(); D_ST=()
SECTION=''
REPORT_KEYS=('Дата' 'ПК' 'Пользователь' 'Модель' 'Серийник' 'Тип' 'CPU' 'ОЗУ ГБ' 'ОЗУ распаяно/слоты' 'Диски' 'C: свободно ГБ'
    'Мониторы' 'Принтеры' 'ИБП/батарея' 'Windows' 'Сборка' 'Поддержка до' 'Последнее обновление' 'Ожидают обновлений'
    'Антивирус' 'Польз. админ' 'Домен/VPN' 'OpenVPN' 'Замечания')
declare -A REPORT=()

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
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
readf() { [ -r "$1" ] && trim "$(tr -d '\0' < "$1" 2>/dev/null)"; }
dmi() { readf "/sys/class/dmi/id/$1"; }
gb() { awk -v b="${1:-0}" -v p="${2:-0}" 'BEGIN { printf "%.*f", p, b / 1073741824 }'; }
pct() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b > 0) printf "%d", a / b * 100 + 0.5; else print 0 }'; }
days_since() { local t; t=$(date -d "$1" +%s 2>/dev/null) || return 1; echo $(( ($(date +%s) - t) / 86400 )); }
fmt_date() { date -d "$1" +%d.%m.%Y 2>/dev/null; }
join_by() { local sep=$1 out='' x; shift; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }
# сравнение версий a.b.c без sort -V: ver_lt 2.4.6 2.6.0 → истина
ver_lt() {
    local -a a b; local i
    IFS=. read -ra a <<< "$1"; IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        if [ "${a[i]:-0}" -lt "${b[i]:-0}" ]; then return 0; fi
        if [ "${a[i]:-0}" -gt "${b[i]:-0}" ]; then return 1; fi
    done
    return 1
}
tcp_ok() { timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" >/dev/null 2>&1; }
svc_state() {  # active / inactive / failed / ? (нет systemd)
    if have systemctl && [ -d /run/systemd/system ]; then systemctl is-active "$1" 2>/dev/null | head -1; else echo '?'; fi
}

usage() {
    cat <<'EOF'
Использование: inventory.sh [--config путь|https-URL] [--csv файл] [--json файл] [--skip-updates]
  --config        конфиг организации (JSON); без него домен/VPN/антивирус только показываются, без сравнения
  --csv           дописать строку по этому ПК в общую таблицу (разделитель ";", UTF-8 с BOM)
  --json          сохранить полный отчёт в JSON
  --skip-updates  не проверять доступные обновления (быстрее)
EOF
}

# ================= конфиг =================
CFG_RAW=''; CFG_TOOL=''
load_config() {
    local src=$1
    case $src in
        https://*)
            if have curl; then CFG_RAW=$(curl -fsSL --max-time 15 "$src" 2>/dev/null) || { err_msg "Не удалось скачать конфиг $src"; return 1; }
            elif have wget; then CFG_RAW=$(wget -qO- -T 15 "$src" 2>/dev/null) || { err_msg "Не удалось скачать конфиг $src"; return 1; }
            else err_msg 'Для https-конфига нужен curl или wget'; return 1; fi ;;
        *://*) err_msg "Конфиг: поддерживается только https:// ($src)"; return 1 ;;
        *) CFG_RAW=$(cat -- "$src" 2>/dev/null) || { err_msg "Не удалось прочитать конфиг $src"; return 1; } ;;
    esac
    CFG_RAW=${CFG_RAW#$'\xEF\xBB\xBF'}
    if have jq; then CFG_TOOL=jq
    elif have python3 && python3 -c '' >/dev/null 2>&1; then CFG_TOOL=python3
    else warn_msg 'Нет ни jq, ни python3 — конфиг не разобрать, работаю без него'; return 1; fi
    if ! cfg_valid; then err_msg "Конфиг $src — не JSON-объект"; CFG_TOOL=''; return 1; fi
}
cfg_valid() {
    case $CFG_TOOL in
        jq) printf '%s' "$CFG_RAW" | jq -e 'type == "object"' >/dev/null 2>&1 ;;
        python3) printf '%s' "$CFG_RAW" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), dict) else 1)' 2>/dev/null ;;
    esac
}
cfg_get() {  # значение поля; массив — по элементу в строке
    case $CFG_TOOL in
        jq) printf '%s' "$CFG_RAW" | jq -r --arg k "$1" '.[$k] // empty | if type == "array" then .[] else . end | tostring' 2>/dev/null ;;
        python3) printf '%s' "$CFG_RAW" | python3 -c '
import json, sys
v = json.load(sys.stdin).get(sys.argv[1])
for x in ([] if v is None else v if isinstance(v, list) else [v]):
    print(x)' "$1" 2>/dev/null ;;
    esac
}

# ================= CSV / JSON =================
csv_q() { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }
write_csv() {
    local f=$1 hdr='' row='' k
    for k in "${REPORT_KEYS[@]}"; do hdr+="$(csv_q "$k");"; row+="$(csv_q "${REPORT[$k]}");"; done
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
json_arr() { local out='' x; for x in "$@"; do out+="${out:+, }$(json_s "$x")"; done; printf '[%s]' "$out"; }
write_json() {
    local f=$1 k i sum='' det='' adm=false cfg=false
    [ "$IS_ROOT" = 1 ] && adm=true
    [ -n "$CFG_TOOL" ] && cfg=true
    for k in "${REPORT_KEYS[@]}"; do sum+="${sum:+,$'\n'}    $(json_s "$k"): $(json_s "${REPORT[$k]}")"; done
    for i in "${!D_NAME[@]}"; do
        det+="${det:+,$'\n'}    {\"Section\": $(json_s "${D_SEC[i]}"), \"Name\": $(json_s "${D_NAME[i]}"), \"Value\": $(json_s "${D_VAL[i]}"), \"State\": $(json_n "${D_ST[i]}")}"
    done
    {
        printf '{\n'
        printf '  "version": %s,\n  "os": "linux",\n  "generated": %s,\n' "$(json_s "$VERSION")" "$(json_s "$(date +%Y-%m-%dT%H:%M:%S)")"
        printf '  "isAdmin": %s,\n  "configUsed": %s,\n' "$adm" "$cfg"
        printf '  "summary": {\n%s\n  },\n' "$sum"
        printf '  "issues": %s,\n' "$(json_arr "${ISSUES[@]}")"
        printf '  "incomplete": %s,\n' "$(json_arr "${INCOMPLETE[@]}")"
        printf '  "details": [\n%s\n  ]\n}\n' "$det"
    } > "$f"
}

# ================= память: распайка или слот =================
# Поля «распаяно» в SMBIOS нет, поэтому решаем по признакам — первый сработавший решает.
# Part Number с номером микросхемы DRAM (а не модуля) — память распаяна на плате
CHIP_PN='^(K4[A-Z0-9]|H5[A-Z]|H9[A-Z]|HKN|MT(40|41|46|52|53|60|61|62)[A-Z]|NT5|NT6|CXDB)'
# Part Number готового модуля (Samsung, SK Hynix, Micron, Kingston, Crucial, G.Skill, Corsair, ADATA, HyperX, Team, Silicon Power, Ramaxel)
MODULE_PN='^(M3[79][0-9]|M47[0-9]|HMA|HMT|HMCG|HMAA|MTA|MTC|KVR|KF[0-9]|KCP|KHX|KTD|KTH|KTL|ACR[0-9]|CT[0-9]|BL[0-9]|F[345]-|CM[A-Z]|AD[45]|AX[45]|HX[45]|TF[0-9]|TED|SP0|RMSA|RMUA|99U5)'
# mem_verdict тип part_number серийник серийник_повторяется(0/1) форм-фактор настольный(0/1) → MV_TEXT, MV_KIND (sold/slot/unknown), MV_SURE (0/1)
mem_verdict() {
    local pn sn=$3
    pn=$(trim "${2^^}")
    case $sn in 'Not Specified'|Unknown|None|'[Empty]') sn='' ;; esac
    MV_SURE=1
    if [[ $1 == LPDDR* ]]; then MV_TEXT='распайка (LPDDR)'; MV_KIND=sold
    elif [[ $pn =~ $CHIP_PN ]]; then MV_TEXT='распайка (номер микросхемы)'; MV_KIND=sold
    elif [[ $pn =~ $MODULE_PN ]]; then MV_TEXT='съёмная плашка (номер модуля)'; MV_KIND=slot
    elif [ "$6" = 1 ]; then MV_TEXT='съёмная плашка (настольный ПК)'; MV_KIND=slot
    else
        MV_SURE=0
        if [[ $sn =~ ^0*$ ]] || [ "$4" = 1 ]; then MV_TEXT='скорее распайка (серийник пустой / повторяется)'; MV_KIND=sold
        elif [ "$5" = DIMM ] || [ "$5" = SODIMM ]; then MV_TEXT='скорее съёмная (форм-фактор DIMM / SODIMM)'; MV_KIND=slot
        else MV_TEXT='не определить'; MV_KIND=unknown; fi
    fi
}

# ================= EDID =================
# печатает: производитель|имя|серийник|год
edid_info() {
    local f=$1 hex v c ch mfr='' name='' sn='' year off i s tag
    local -a b
    hex=$(od -An -v -tx1 "$f" 2>/dev/null | tr -s ' \n' '  ')
    read -ra b <<< "$hex"
    [ "${#b[@]}" -ge 128 ] || return 1
    v=$(( 16#${b[8]}${b[9]} ))
    for c in $(( (v >> 10) & 31 )) $(( (v >> 5) & 31 )) $(( v & 31 )); do
        printf -v ch '%b' "\\x$(printf '%02x' $((c + 64)))"; mfr+=$ch
    done
    year=$(( 16#${b[17]} + 1990 ))
    for off in 54 72 90 108; do
        [ "${b[off]}${b[off+1]}${b[off+2]}" = '000000' ] || continue
        tag=${b[off+3]}; s=''
        for ((i = off + 5; i < off + 18; i++)); do [ "${b[i]}" = '0a' ] && break; s+="\\x${b[i]}"; done
        printf -v s '%b' "$s"; s=$(trim "$s")
        case $tag in fc) name=$s ;; ff) sn=$s ;; esac
    done
    if [ -z "$sn" ]; then
        v=$(( 16#${b[15]}${b[14]}${b[13]}${b[12]} ))
        [ "$v" -gt 0 ] && sn=$v
    fi
    if have edid-decode; then
        s=$(edid-decode "$f" 2>/dev/null | sed -n "s/.*Display Product Name: *//p" | head -1 | tr -d "'\"")
        [ -n "$s" ] && name=$(trim "$s")
    fi
    printf '%s|%s|%s|%s' "$mfr" "$name" "$sn" "$year"
}

main() {
    exec 0</dev/null   # при запуске через curl | bash не даём командам читать остаток скрипта из stdin

    local l
    for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if locale -a 2>/dev/null | grep -qix "$l"; then export LC_ALL=$l; break; fi
    done

    CONFIG=''; CSV=''; JSON=''; SKIP_UPD=0
    while [ $# -gt 0 ]; do
        case $1 in
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
        mapfile -t DCS < <(cfg_get dcs | grep -v '^$')
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

    IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
    RUSER=${SUDO_USER:-}
    [ -z "$RUSER" ] && RUSER=$(logname 2>/dev/null)
    [ -z "$RUSER" ] && RUSER=$(id -un)
    if [ "$RUSER" = root ]; then
        l=$(who 2>/dev/null | awk '$1 != "root" { print $1; exit }')
        [ -n "$l" ] && RUSER=$l
    fi
    HOST=$(hostname 2>/dev/null || readf /proc/sys/kernel/hostname)

    REPORT['Дата']=$(date '+%Y-%m-%d %H:%M')
    REPORT['ПК']=$HOST

    printf '\n%sИнвентаризация %s — %s (inventory.sh %s)%s\n' "$C_TITLE" "$HOST" "$(date '+%d.%m.%Y %H:%M')" "$VERSION" "$C_0"
    [ "$IS_ROOT" = 1 ] || warn_msg 'Запущено без root — часть проверок будет неполной'
    if [ "$CFG_LOADED" = 1 ]; then note "Конфиг: $CONFIG (разобран через $CFG_TOOL)"
    elif [ -n "$CONFIG" ]; then warn_msg 'Конфиг не загружен — домен, VPN и антивирус проверяются без сравнения с ожидаемыми значениями'
    else note 'Без конфига — домен, VPN и антивирус проверяются без сравнения с ожидаемыми значениями'; fi

    # ================= общее =================
    local vendor pname pver serial chassis model is_laptop=0 is_desktop=0 up up_d up_h st
    vendor=$(dmi sys_vendor); pname=$(dmi product_name); pver=$(dmi product_version)
    chassis=$(dmi chassis_type)
    if [[ " 8 9 10 11 12 14 18 21 30 31 32 " == *" ${chassis:-x} "* ]]; then is_laptop=1; fi
    if [[ " 3 4 5 6 7 15 16 17 23 24 " == *" ${chassis:-x} "* ]]; then is_desktop=1; fi
    model=$pname
    if [[ ${vendor^^} == *LENOVO* ]] && [ -n "$pver" ]; then model="$pver ($pname)"; fi
    if [ -r /sys/class/dmi/id/product_serial ]; then serial=$(dmi product_serial)
    elif [ -e /sys/class/dmi/id/product_serial ]; then serial='нет данных (нужен root)'; incomplete 'серийный номер'
    else serial='нет данных'; fi
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null); up=${up:-0}
    up_d=$((up / 86400)); up_h=$(((up % 86400) / 3600))

    section 'Общее'
    line 'Компьютер' "$HOST"
    line 'Пользователь' "$RUSER"
    line 'Производитель' "${vendor:-нет данных}"
    line 'Модель' "${model:-нет данных}"
    line 'Серийный номер' "${serial:-нет данных}"
    if [ -z "$chassis" ]; then line 'Тип' 'нет данных'
    elif [ "$is_laptop" = 1 ]; then line 'Тип' 'Ноутбук'
    else line 'Тип' 'Настольный / прочее'; fi
    if [ "$up_d" -ge 14 ]; then st=warn; else st=ok; fi
    line 'Без перезагрузки' "$up_d дн. $up_h ч." "$st" "$([ "$st" = warn ] && echo 'Не перезагружался больше 2 недель')"
    REPORT['Пользователь']=$RUSER
    REPORT['Модель']=$(trim "$vendor $model")
    REPORT['Серийник']=$serial
    if [ "$is_laptop" = 1 ]; then REPORT['Тип']='Ноутбук'; else REPORT['Тип']='ПК'; fi

    # ================= процессор =================
    section 'Процессор'
    local cpu cores threads
    if have lscpu; then
        cpu=$(lscpu 2>/dev/null | awk -F: '/^Model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }')
        cores=$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)
    fi
    [ -z "$cpu" ] && cpu=$(awk -F: '/^model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)
    cpu=$(trim "$(tr -s ' ' <<< "$cpu")")
    threads=$(nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    line 'Модель' "${cpu:-нет данных}"
    line 'Ядер / потоков' "${cores:-?} / ${threads:-?}"
    REPORT['CPU']=$cpu

    # ================= память =================
    section 'Оперативная память'
    local mt_kb ma_kb total_gb used_pct free_gb mods=() sns=() dupsn
    mt_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo); ma_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    # старые ядра без MemAvailable: свободная + кэш
    [ -z "$ma_kb" ] && ma_kb=$(awk '/^(MemFree|Buffers|Cached):/ { s += $2 } END { print s + 0 }' /proc/meminfo)
    used_pct=$(pct $((mt_kb - ma_kb)) "$mt_kb")
    free_gb=$(awk -v k="$ma_kb" 'BEGIN { printf "%.1f", k / 1048576 }')
    if [ "$IS_ROOT" = 1 ] && have dmidecode; then
        mapfile -t mods < <(dmidecode -t 17 2>/dev/null | awk -F': ' '
            function out() { if (n) print r["Size"] "\t" r["Type"] "\t" spd() "\t" r["Manufacturer"] "\t" r["Part Number"] "\t" r["Serial Number"] "\t" r["Form Factor"] "\t" r["Bank Locator"] "\t" r["Locator"] }
            function spd() { return ("Configured Memory Speed" in r) ? r["Configured Memory Speed"] : r["Configured Clock Speed"] }
            /^Memory Device/ { out(); n = 1; split("", r); next }
            /^Handle/ { out(); n = 0; next }
            n && /^\t[^\t]/ { k = $1; sub(/^\t/, "", k); v = $2; sub(/[ \t]+$/, "", v); r[k] = v }
            END { out() }')
    fi
    local m size unit gbm mtype speed mfr part sn ff bank loc v sold=0 slot=0 unk=0 guess=0 sum_gb=0 slots_bios='' max_bios=''
    local -a good=()
    for m in "${mods[@]}"; do
        IFS=$'\t' read -r size mtype speed mfr part sn ff bank loc <<< "$m"
        unit=${size##* }; gbm=${size%% *}
        [[ $gbm =~ ^[0-9]+$ ]] || continue
        case $unit in MB) gbm=$((gbm / 1024)) ;; TB) gbm=$((gbm * 1024)) ;; esac
        good+=("$gbm"$'\t'"$mtype"$'\t'"$speed"$'\t'"$mfr"$'\t'"$part"$'\t'"$sn"$'\t'"$ff"$'\t'"$bank"$'\t'"$loc")
        sns+=("$sn")
    done
    if [ "${#good[@]}" -gt 0 ]; then
        for m in "${good[@]}"; do IFS=$'\t' read -r gbm _ <<< "$m"; sum_gb=$((sum_gb + gbm)); done
        total_gb=$sum_gb
    else
        total_gb=$(( (mt_kb + 524288) / 1048576 ))
    fi
    if [ "$total_gb" -lt 8 ]; then st=bad; elif [ "$total_gb" -lt 16 ]; then st=warn; else st=ok; fi
    line 'Всего' "$total_gb ГБ (занято $used_pct%, свободно $free_gb ГБ)" "$st" "$([ "$total_gb" -lt 8 ] && echo "Мало ОЗУ: $total_gb ГБ")"
    dupsn=$(printf '%s\n' "${sns[@]}" | sort | uniq -d)
    for m in "${good[@]}"; do
        IFS=$'\t' read -r gbm mtype speed mfr part sn ff bank loc <<< "$m"
        v=0; [ -n "$dupsn" ] && grep -qxF -- "$sn" <<< "$dupsn" && v=1
        mem_verdict "$mtype" "$part" "$sn" "$v" "$ff" "$is_desktop"
        case $MV_KIND in sold) sold=$((sold + gbm)) ;; slot) slot=$((slot + gbm)) ;; *) unk=$((unk + gbm)) ;; esac
        [ "$MV_SURE" = 1 ] || guess=1
        line "$(trim "$bank $loc")" "$gbm ГБ $mtype-${speed%% *} | $mfr $part | $MV_TEXT"
    done
    if [ "${#good[@]}" -gt 0 ]; then
        slots_bios=$(dmidecode -t 16 2>/dev/null | awk -F': ' '/Number Of Devices/ { s += $2 } END { print s }')
        max_bios=$(dmidecode -t 16 2>/dev/null | awk -F': ' '/Maximum Capacity/ { print $2; exit }')
        v="распаяно $sold ГБ, в слотах $slot ГБ"
        [ "$unk" -gt 0 ] && v+=", не определено $unk ГБ"
        [ "$guess" = 1 ] && v+=' (часть — оценка)'
        line 'Итого' "$v | слотов по BIOS: ${slots_bios:-?}, макс. ${max_bios:-?}"
        REPORT['ОЗУ распаяно/слоты']="$sold/$slot$([ "$unk" -gt 0 ] && echo "/?$unk")$([ "$guess" = 1 ] && echo ' (оценка)')"
    elif [ "$IS_ROOT" != 1 ]; then
        line 'Модули' 'нет данных (нужен root для dmidecode)'; incomplete 'модули памяти'
    elif ! have dmidecode; then
        line 'Модули' 'нет данных (dmidecode не установлен)'
    else
        line 'Модули' 'нет данных (DMI недоступен — виртуалка / контейнер?)'
    fi
    REPORT['ОЗУ ГБ']=$total_gb

    # ================= диски =================
    section 'Диски'
    local re name rota tran bytes dmodel dtype hs health dlist=() smart_note=0
    re='^NAME="([^"]*)" TYPE="([^"]*)" ROTA="([^"]*)" TRAN="([^"]*)" SIZE="([^"]*)" MODEL="(.*)"$'
    if have lsblk; then
        while IFS= read -r l; do
            [[ $l =~ $re ]] || continue
            name=${BASH_REMATCH[1]}; rota=${BASH_REMATCH[3]}; tran=${BASH_REMATCH[4]}; bytes=${BASH_REMATCH[5]}; dmodel=$(trim "${BASH_REMATCH[6]}")
            [ "${BASH_REMATCH[2]}" = disk ] || continue
            case $name in loop*|ram*|zram*|sr*|fd*) continue ;; esac
            if [ "$tran" = nvme ] || [[ $name == nvme* ]]; then dtype='SSD NVMe'; tran=nvme
            elif [ "$rota" = 0 ]; then dtype=SSD
            elif [ "$rota" = 1 ]; then dtype=HDD
            else dtype='?'; fi
            size=$(gb "$bytes")
            health=''; hs=''
            if have smartctl && [ "$IS_ROOT" = 1 ]; then
                health=$(smartctl -H "/dev/$name" 2>/dev/null | sed -n 's/.*\(test result\|Health Status\): *//p' | head -1)
                case $health in PASSED|OK) hs=ok ;; '') health='SMART: нет данных' ;; *) hs=bad ;; esac
            elif have smartctl; then health='SMART: нужен root'; incomplete 'SMART'
            else health='SMART: нет данных'; smart_note=1; fi
            line "Диск $name" "${dmodel:-?} | $dtype | $size ГБ | ${tran^^} | $health" "$hs" "$([ "$hs" = bad ] && echo "Диск ${dmodel:-$name}: SMART $health")"
            [ "$tran" = usb ] || dlist+=("$dtype $size ГБ")
        done < <(lsblk -d -b -P -o NAME,TYPE,ROTA,TRAN,SIZE,MODEL 2>/dev/null)
        [ "${#dlist[@]}" -eq 0 ] && line 'Диски' 'не определены'
    else
        line 'Диски' 'нет данных (lsblk не установлен)'
    fi
    [ "$smart_note" = 1 ] && note '  (для проверки SMART установите smartmontools)'
    local mp dev fsz favail fp root_dev=''
    for mp in / /home; do
        read -r dev fsz favail <<< "$(df -P -B1 "$mp" 2>/dev/null | awk 'NR == 2 { print $1, $2, $4 }')"
        [ -n "$dev" ] || continue
        if [ "$mp" = / ]; then root_dev=$dev; elif [ "$dev" = "$root_dev" ]; then continue; fi
        local f s
        f=$(gb "$favail" 1); s=$(gb "$fsz"); fp=$(pct "$favail" "$fsz")
        if awk -v f="$f" -v p="$fp" 'BEGIN { exit !(f < 10 || p < 10) }'; then st=bad
        elif awk -v f="$f" -v p="$fp" 'BEGIN { exit !(f < 25 || p < 20) }'; then st=warn
        else st=ok; fi
        if [ "$mp" = / ]; then
            line 'Том / (система)' "свободно $f из $s ГБ ($fp%)" "$st" "$([ "$st" = bad ] && echo "Мало места на /: $f ГБ")"
            REPORT['C: свободно ГБ']=$f
        else
            line "Том $mp" "свободно $f из $s ГБ ($fp%)" "$st"
        fi
    done
    REPORT['Диски']=$(join_by ' + ' "${dlist[@]}")

    # ================= периферия =================
    section 'Мониторы и периферия'
    local e info mname msn myear disp mons=() i=0 conn
    for e in /sys/class/drm/*/edid; do
        [ -s "$e" ] || continue
        info=$(edid_info "$e") || continue
        i=$((i + 1))
        IFS='|' read -r mfr mname msn myear <<< "$info"
        conn=${e%/edid}; conn=${conn##*/}; conn=${conn#card[0-9]-}
        [ -z "$mname" ] && mname='(встроенный / без имени)'
        if [ -n "$mfr" ] && [[ $mname == "$mfr"* ]]; then disp=$mname; else disp=$(trim "$mfr $mname"); fi
        line "Монитор $i" "$disp | S/N ${msn:-?} | $myear г. | $conn"
        mons+=("$disp")
    done
    [ "$i" = 0 ] && line 'Мониторы' 'не определены'
    REPORT['Мониторы']=$(join_by ', ' "${mons[@]}")

    local skip='PDF|XPS|Fax|Факс|Send To|AnyDesk|Snagit' pdef pn uri how prns=()
    if have lpstat; then
        pdef=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
        while IFS=$'\t' read -r pn uri; do
            [ -n "$pn" ] || continue
            [[ $pn =~ $skip ]] && continue
            case $uri in
                usb:*) how=USB ;;
                implicitclass:*|dnssd:*) how='по сети (автообнаружение)' ;;
                ipp:*|ipps:*|http:*|https:*|socket:*|lpd:*|smb:*) how="по сети (${uri%%:*} ${uri#*://})" ;;
                *) how=$uri ;;
            esac
            line 'Принтер / МФУ' "$pn | $how$([ "$pn" = "$pdef" ] && echo ' | по умолчанию')"
            prns+=("$pn")
        done < <(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\): \(.*\)$/\1\t\2/p')
        [ "${#prns[@]}" -eq 0 ] && line 'Принтер / МФУ' 'нет'
    else
        line 'Принтер / МФУ' 'нет (CUPS не установлен)'
    fi
    REPORT['Принтеры']=$(join_by ', ' "${prns[@]}")

    local bat='' bcap bfull bdes wear='' wst ups='' u uc
    for e in /sys/class/power_supply/BAT*; do [ -d "$e" ] && { bat=$e; break; }; done
    if have upsc; then
        u=$(upsc -l 2>/dev/null | head -1)
        if [ -n "$u" ]; then
            ups=$(upsc "$u" ups.model 2>/dev/null); uc=$(upsc "$u" battery.charge 2>/dev/null)
            ups="${ups:-$u}${uc:+ | заряд $uc%}"
        fi
    fi
    if [ -z "$ups" ] && have lsusb; then
        ups=$(lsusb 2>/dev/null | grep -iE 'UPS|APC|Ippon|Powercom|Eaton|CyberPower' | head -1 | sed 's/^.*ID [0-9a-f:]* //')
        [ -n "$ups" ] && ups="$ups (USB, без NUT)"
    fi
    if [ "$is_laptop" = 1 ]; then
        if [ -n "$bat" ]; then
            bcap=$(readf "$bat/capacity")
            bfull=$(readf "$bat/energy_full"); bdes=$(readf "$bat/energy_full_design")
            [ -z "$bfull" ] && { bfull=$(readf "$bat/charge_full"); bdes=$(readf "$bat/charge_full_design"); }
            [ -n "$bfull" ] && [ "${bdes:-0}" -gt 0 ] && wear=$(pct "$bfull" "$bdes")
            if [ -n "$wear" ] && [ "$wear" -lt 60 ]; then wst=warn; else wst=ok; fi
            line 'Батарея' "заряд ${bcap:-?}%${wear:+, ёмкость $wear% от заводской}" "$wst"
            if [ -n "$wear" ]; then REPORT['ИБП/батарея']="батарея $wear%"; else REPORT['ИБП/батарея']='батарея'; fi
        else
            line 'Батарея' 'нет данных'
        fi
        [ -n "$ups" ] && line 'ИБП' "$ups" ok
    else
        if [ -n "$ups" ]; then line 'ИБП' "$ups" ok; REPORT['ИБП/батарея']=$ups
        else line 'ИБП' 'не обнаружен (или подключён без USB-кабеля)' warn; REPORT['ИБП/батарея']='нет'; fi
    fi

    # ================= ОС и обновления =================
    section 'ОС и обновления'
    local os_id='' os_ver='' os_pretty='' kern pm=''
    # shellcheck disable=SC1091
    if [ -r /etc/os-release ]; then
        os_id=$(. /etc/os-release && echo "${ID:-}")
        os_ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
        os_pretty=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
    fi
    kern=$(uname -r)
    line 'Дистрибутив' "${os_pretty:-нет данных}"
    line 'Ядро' "$kern"
    REPORT['Windows']=$os_pretty
    REPORT['Сборка']=$kern

    local key end left eid emax=''
    key="$os_id:$os_ver"
    if [ -n "${EOL[$key]:-}" ]; then
        end=${EOL[$key]}; left=$(( -$(days_since "$end") ))
        REPORT['Поддержка до']=$end
        if [ "$left" -lt 0 ]; then
            line 'Поддержка' "ЗАКОНЧИЛАСЬ $(fmt_date "$end") — нужен переход на новую версию" bad "$os_pretty без поддержки с $(fmt_date "$end")"
        elif [ "$left" -lt 120 ]; then
            line 'Поддержка' "до $(fmt_date "$end") (осталось $left дн.) — пора планировать обновление" warn
        else
            line 'Поддержка' "до $(fmt_date "$end") — версия актуальна" ok
        fi
    elif [ "$os_id" = ubuntu ] || [ "$os_id" = debian ]; then
        for eid in "${!EOL[@]}"; do
            [ "${eid%%:*}" = "$os_id" ] || continue
            if [ -z "$emax" ] || ver_lt "$emax" "${eid#*:}"; then emax=${eid#*:}; fi
        done
        if [ -z "$os_ver" ]; then line 'Поддержка' 'нет данных (testing / sid?)'
        elif [ -n "$emax" ] && ver_lt "$emax" "$os_ver"; then line 'Поддержка' 'версия новее таблицы в скрипте — скорее всего, актуальная' ok
        else line 'Поддержка' 'промежуточная или старая версия — нет в таблице, скорее всего не поддерживается' bad "Устаревший $os_pretty"; fi
    else
        line 'Поддержка' "нет данных (таблица сроков — только для Ubuntu и Debian)"
    fi

    local tpmv sbf sbv
    if [ -d /sys/class/tpm/tpm0 ]; then
        tpmv=$(readf /sys/class/tpm/tpm0/tpm_version_major)
        line 'TPM' "есть${tpmv:+, версия $tpmv}" "$([ "${tpmv:-2}" = 2 ] && echo ok || echo warn)"
    else
        line 'TPM' 'не найден' warn
    fi
    if [ -d /sys/firmware/efi ]; then
        sbv=''
        for sbf in /sys/firmware/efi/efivars/SecureBoot-*; do
            [ -r "$sbf" ] && sbv=$(od -An -tu1 -j4 -N1 "$sbf" 2>/dev/null | tr -d ' ')
            break
        done
        case $sbv in 1) line 'Secure Boot' 'включён' ok ;; 0) line 'Secure Boot' 'выключен' warn ;; *) line 'Secure Boot' 'нет данных' warn ;; esac
    else
        line 'Secure Boot' 'нет данных / Legacy BIOS' warn
    fi

    if have apt-get; then pm=apt; elif have dnf; then pm=dnf; elif have yum; then pm=yum
    elif have zypper; then pm=zypper; elif have pacman; then pm=pacman; fi
    line 'Пакетный менеджер' "${pm:-не определён}"

    # последнее обновление пакетов
    local last='' last_what='' ld
    case $pm in
        apt)
            l=$(zcat -f /var/log/dpkg.log* 2>/dev/null | awk '$3 == "upgrade" { print $1 " " $2 " " $4 }' | sort | tail -1)
            [ -n "$l" ] && { last="${l%% *} $(cut -d' ' -f2 <<< "$l")"; last_what=${l##* }; } ;;
        dnf|yum|zypper)
            l=$(rpm -qa --qf '%{INSTALLTIME} %{NAME}\n' 2>/dev/null | sort -n | tail -1)
            [ -n "$l" ] && { last="@${l%% *}"; last_what=${l#* }; } ;;
        pacman)
            l=$(grep '\[ALPM\] upgraded' /var/log/pacman.log 2>/dev/null | tail -1)
            [ -n "$l" ] && { last=$(sed 's/^\[\([^]]*\)\].*/\1/' <<< "$l"); last_what=$(awk '{ print $4 }' <<< "$l"); } ;;
    esac
    if [ -n "$last" ] && ld=$(days_since "$last"); then
        if [ "$ld" -gt 70 ]; then st=bad; elif [ "$ld" -gt 40 ]; then st=warn; else st=ok; fi
        line 'Последнее обновление' "$(fmt_date "$last") ($ld дн. назад)" "$st" "$([ "$st" = bad ] && echo "Обновления не ставились $ld дн.")"
        [ -n "$last_what" ] && line '' "пакет $last_what"
        REPORT['Последнее обновление']=$(date -d "$last" +%Y-%m-%d)
    else
        line 'Последнее обновление' 'не удалось определить' warn
    fi

    # доступные обновления — только из кэша пакетного менеджера, без обновления списков
    local upd=() sec=0 rc cache_t cache_note=''
    if [ "$SKIP_UPD" = 1 ]; then
        REPORT['Ожидают обновлений']='не проверялось'
    else
        rc=0
        case $pm in
            apt)
                cache_t=$(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
                if [ -z "$cache_t" ]; then
                    rc=1
                else
                    cache_t=${cache_t%.*}
                    [ $(( ($(date +%s) - cache_t) / 86400 )) -gt 7 ] && cache_note=" (кэш пакетов от $(fmt_date "@$cache_t"), apt update давно не запускался)"
                    mapfile -t upd < <(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk '/^Inst / { print $2 (tolower($0) ~ /security/ ? " [security]" : "") }')
                fi ;;
            dnf|yum)
                l=$("$pm" -C -q check-update 2>/dev/null); rc=$?; [ "$rc" = 100 ] && rc=0
                mapfile -t upd < <(awk 'NF == 3 && $1 !~ /^(Obsoleting|Security)/ { print $1 }' <<< "$l")
                sec=$("$pm" -C -q updateinfo list --security 2>/dev/null | grep -c . ) ;;
            zypper)
                l=$(zypper --non-interactive --no-refresh -q list-updates 2>/dev/null); rc=$?
                mapfile -t upd < <(awk -F'|' '/^v / { gsub(/ /, "", $3); print $3 }' <<< "$l")
                sec=$(zypper --non-interactive --no-refresh -q list-patches --category security 2>/dev/null | grep -c '| needed') ;;
            pacman)
                if have checkupdates; then mapfile -t upd < <(checkupdates 2>/dev/null | awk '{ print $1 }')
                else mapfile -t upd < <(pacman -Qu 2>/dev/null | awk '{ print $1 }'); fi ;;
            *) rc=1 ;;
        esac
        [ "$pm" = apt ] && sec=$(printf '%s\n' "${upd[@]}" | grep -c '\[security\]')
        if [ "$rc" != 0 ]; then
            line 'Доступные обновления' 'нет данных (кэш пакетного менеджера пуст или недоступен)' warn
            REPORT['Ожидают обновлений']='?'
        elif [ "${#upd[@]}" -eq 0 ]; then
            line 'Доступные обновления' "нет — система актуальна$cache_note" "$([ -n "$cache_note" ] && echo warn || echo ok)"
            REPORT['Ожидают обновлений']=0
        else
            if [ "${sec:-0}" -gt 0 ]; then st=bad; else st=warn; fi
            line 'Доступные обновления' "можно обновить: ${#upd[@]} шт.$([ "${sec:-0}" -gt 0 ] && echo ", из них безопасности: $sec")$cache_note" "$st" \
                "$([ "${sec:-0}" -gt 0 ] && echo 'Не установлены обновления безопасности')"
            for l in "${upd[@]:0:6}"; do line '' "• $l"; done
            REPORT['Ожидают обновлений']=${#upd[@]}
        fi
    fi

    if [ -e /var/run/reboot-required ]; then
        line 'Перезагрузка' "ТРЕБУЕТСЯ для завершения обновлений$( [ -r /var/run/reboot-required.pkgs ] && printf ' (%s)' "$(sort -u /var/run/reboot-required.pkgs | head -3 | paste -sd, -)")" warn 'Ждёт перезагрузки после обновлений'
    elif have needs-restarting; then
        needs-restarting -r >/dev/null 2>&1
        [ $? -eq 1 ] && line 'Перезагрузка' 'ТРЕБУЕТСЯ для завершения обновлений' warn 'Ждёт перезагрузки после обновлений'
    fi

    # ================= антивирус =================
    section 'Антивирус'
    local avs=() kesl='' ks kinfo cv cdb cdays cs_
    kesl=$(command -v kesl-control 2>/dev/null)
    [ -z "$kesl" ] && [ -x /opt/kaspersky/kesl/bin/kesl-control ] && kesl=/opt/kaspersky/kesl/bin/kesl-control
    if [ -n "$kesl" ]; then
        ks=$(svc_state kesl)
        case $ks in active) st=ok; ks='работает' ;; '?') st=''; ks='статус службы: нет данных' ;; *) st=bad; ks="служба kesl: ${ks:-не запущена}" ;; esac
        line 'Kaspersky Endpoint Security' "установлен, $ks" "$st" "$([ "$st" = bad ] && echo 'Kaspersky Endpoint Security установлен, но служба не работает')"
        if [ "$IS_ROOT" = 1 ]; then
            kinfo=$("$kesl" --app-info 2>/dev/null | grep -iE 'version|верси|database|баз' | head -3)
            while IFS= read -r l; do [ -n "$l" ] && line '' "$(trim "$l")"; done <<< "$kinfo"
        else
            incomplete 'сведения KESL'
        fi
        avs+=('Kaspersky Endpoint Security for Linux')
    fi
    if have clamscan || have clamdscan || have clamd; then
        cv=$( (clamscan --version || clamdscan --version) 2>/dev/null | head -1)
        cdb=''; cdays=''
        if [[ $cv == */*/* ]]; then cdb=${cv##*/}; cdays=$(days_since "$cdb"); fi
        if [ -n "$cdays" ] && [ "$cdays" -gt 7 ]; then st=warn; else st=ok; fi
        line 'ClamAV' "${cv%%/*}${cdays:+, базы от $(fmt_date "$cdb") ($cdays дн.)}" "$st" "$([ "$st" = warn ] && echo "ClamAV: базы устарели ($cdays дн.)")"
        for l in clamav-daemon clamd@scan clamav-freshclam; do
            cs_=$(svc_state "$l")
            case $cs_ in active) line "Служба $l" 'работает' ok ;; inactive|failed) line "Служба $l" "$cs_" ;; esac
        done
        avs+=('ClamAV')
    fi
    [ "${#avs[@]}" -eq 0 ] && line 'Антивирус' 'не найден' warn
    if [ -n "$EXPECTED_AV" ]; then
        if printf '%s\n' "${avs[@]}" | grep -qiF -- "$EXPECTED_AV"; then
            REPORT['Антивирус']="$(join_by ', ' "${avs[@]}")"
        else
            line "$EXPECTED_AV" 'не найден' bad "$EXPECTED_AV не установлен"
            REPORT['Антивирус']="$EXPECTED_AV нет; найден: $(join_by ', ' "${avs[@]}")"
        fi
    else
        if [ "${#avs[@]}" -gt 0 ]; then REPORT['Антивирус']="найден: $(join_by ', ' "${avs[@]}")"; else REPORT['Антивирус']='не найден'; fi
    fi

    # ================= администраторы =================
    section 'Администраторы'
    local g gm uadm='' method rl prl='' pst
    for g in sudo wheel admin; do
        l=$(getent group "$g" 2>/dev/null) || continue
        gm=$(cut -d: -f4 <<< "$l")
        line "Группа $g" "${gm:-пусто}"
    done
    if [ "$RUSER" = root ]; then
        line 'Пользователь — админ?' 'запущено от root, обычный пользователь не определён'
    else
        if [ "$IS_ROOT" = 1 ] && have sudo; then
            rl=$(sudo -n -l -U "$RUSER" 2>/dev/null)
            if grep -qE '\(ALL(:ALL)?\)[[:space:]]+(NOPASSWD:[[:space:]]*)?ALL' <<< "$rl"; then uadm=1; else uadm=0; fi
            method='по sudo -l, с учётом sudoers и вложенных групп'
        else
            if id -nG "$RUSER" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then uadm=1; else uadm=0; fi
            method='по группам sudo/wheel/admin, sudoers не проверен'
            incomplete 'права sudo (sudoers)'
        fi
        if [ "$uadm" = 1 ]; then line 'Пользователь — админ?' "ДА, $RUSER ($method)" bad "Пользователь $RUSER — администратор (sudo)"
        else line 'Пользователь — админ?' "нет ($method)" ok; fi
    fi
    case $uadm in 1) REPORT['Польз. админ']='ДА' ;; 0) REPORT['Польз. админ']='нет' ;; *) REPORT['Польз. админ']='?' ;; esac

    if [ "$IS_ROOT" = 1 ] && have passwd; then
        pst=$(passwd -S root 2>/dev/null | awk '{ print $2 }')
        case $pst in
            P|PS) line 'Пароль root' 'задан (вход по паролю возможен)' warn ;;
            L|LK|NP) line 'Пароль root' 'заблокирован / не задан' ok ;;
        esac
    fi
    if have sshd || [ -x /usr/sbin/sshd ]; then
        [ "$IS_ROOT" = 1 ] && prl=$( (sshd -T || /usr/sbin/sshd -T) 2>/dev/null | awk '$1 == "permitrootlogin" { print $2; exit }')
        if [ -z "$prl" ]; then
            prl=$(cat /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config 2>/dev/null | awk 'tolower($1) == "permitrootlogin" { print tolower($2); exit }')
            prl=${prl:-prohibit-password}
        fi
        case $prl in
            yes) line 'Вход root по SSH' 'РАЗРЕШЁН (в том числе по паролю)' bad 'SSH: разрешён вход root по паролю' ;;
            prohibit-password|without-password) line 'Вход root по SSH' 'только по ключу' ok ;;
            forced-commands-only) line 'Вход root по SSH' 'только forced-commands' ok ;;
            *) line 'Вход root по SSH' 'запрещён' ok ;;
        esac
    else
        line 'Вход root по SSH' 'SSH-сервер не установлен' ok
    fi

    # ================= домен и VPN =================
    section 'Домен и VPN'
    local dom="" dom_how="" dcok=() dc in_corp=0 trust
    if have realm; then dom=$(realm list --name-only 2>/dev/null | head -1); [ -n "$dom" ] && dom_how='realmd/sssd'; fi
    if [ -z "$dom" ] && [ -e /etc/sssd/sssd.conf ]; then
        if [ -r /etc/sssd/sssd.conf ]; then
            dom=$(awk -F= '/^[ \t]*domains[ \t]*=/ { gsub(/[ \t]/, "", $2); split($2, a, ","); print a[1]; exit }' /etc/sssd/sssd.conf)
            [ -n "$dom" ] && dom_how=sssd
        else
            incomplete 'домен (sssd.conf)'
        fi
    fi
    if [ -z "$dom" ] && have wbinfo; then
        [ "$IS_ROOT" = 1 ] && have net && dom=$(net ads info 2>/dev/null | sed -n 's/^Realm: //p')
        [ -z "$dom" ] && dom=$(wbinfo --own-domain 2>/dev/null)
        [ -n "$dom" ] && dom_how=winbind
    fi
    for dc in "${DCS[@]}"; do tcp_ok "$dc" 389 && dcok+=("$dc"); done
    if [ -n "$CORP_DOMAIN" ]; then [ -n "$dom" ] && [ "${dom,,}" = "${CORP_DOMAIN,,}" ] && in_corp=1
    else [ -n "$dom" ] && in_corp=1; fi

    if [ "$in_corp" = 1 ]; then
        line 'Домен' "в домене $dom ($dom_how)" "$([ -n "$CORP_DOMAIN" ] && echo ok)"
        if [ "${#DCS[@]}" -eq 0 ]; then line 'Доверие с доменом' 'не проверено — в конфиге не заданы контроллеры (dcs)'
        elif [ "${#dcok[@]}" -eq 0 ]; then line 'Доверие с доменом' 'не проверено — DC недоступны'
        elif [ "$IS_ROOT" != 1 ]; then line 'Доверие с доменом' 'не проверено (нужен root)'; incomplete 'доверие с доменом'
        else
            trust=""
            if [ "$dom_how" = winbind ] && have wbinfo; then wbinfo -t >/dev/null 2>&1 && trust=1 || trust=0
            elif have adcli; then adcli testjoin -D "$dom" >/dev/null 2>&1 && trust=1 || trust=0; fi
            case $trust in
                1) line 'Доверие с доменом' 'в порядке' ok ;;
                0) line 'Доверие с доменом' 'НАРУШЕНО' bad 'Нарушены доверительные отношения с доменом' ;;
                *) line 'Доверие с доменом' 'не проверено (нет adcli / wbinfo)' ;;
            esac
        fi
    elif [ -n "$dom" ]; then line 'Домен' "в ДРУГОМ домене: $dom" warn 'Компьютер в чужом домене'
    else line 'Домен' 'не в домене' "$([ -n "$CORP_DOMAIN" ] && echo warn)"; fi

    if [ "$RUSER" = root ] || grep -q "^${RUSER}:" /etc/passwd 2>/dev/null; then line 'Учётка пользователя' 'локальная'
    elif getent passwd "$RUSER" >/dev/null 2>&1; then line 'Учётка пользователя' 'доменная'
    else line 'Учётка пользователя' '—'; fi

    local ovl ovv='' ovpn=0 files=() fpath txt remotes owner foreign has_route kuser nm_vpn=() nl nt nname nst
    if have openvpn; then
        ovpn=1
        ovl=$(openvpn --version 2>/dev/null | head -1)
        [[ $ovl =~ OpenVPN\ ([0-9]+\.[0-9]+\.[0-9]+) ]] && ovv=${BASH_REMATCH[1]}
        if [ -n "$ovv" ] && ver_lt "$ovv" "$MIN_OVPN"; then st=warn; else st=ok; fi
        line 'OpenVPN' "установлен, версия ${ovv:-?}" "$st" "$([ "$st" = warn ] && echo "Старый OpenVPN $ovv — обновить до $MIN_OVPN+")"
        REPORT['OpenVPN']=$ovv
    else
        line 'OpenVPN' 'не установлен'
        REPORT['OpenVPN']='нет'
    fi

    mapfile -t files < <(find /etc/openvpn /home /root -maxdepth 4 -type f \
        \( -name '*.ovpn' -o \( -path '/etc/openvpn/*' -name '*.conf' \) \) ! -path '/etc/openvpn/server/*' 2>/dev/null)
    [ "$IS_ROOT" = 1 ] || incomplete 'VPN-профили других пользователей'
    for fpath in "${files[@]}"; do
        txt=$(cat -- "$fpath" 2>/dev/null)
        remotes=$(awk '$1 == "remote" { print $2 }' <<< "$txt" | paste -sd, - | sed 's/,/, /g')
        has_route=''
        [ -n "$EXTRA_ROUTE" ] && grep -qF -- "$EXTRA_ROUTE" <<< "$txt" && has_route=" | маршрут до $EXTRA_ROUTE есть"
        case $fpath in /home/*) owner=${fpath#/home/}; owner=${owner%%/*} ;; /root/*) owner=root ;; *) owner='общий' ;; esac
        foreign=''
        name=${fpath##*/}; name=${name%.*}
        if [ -n "$KEY_PATTERN" ] && [ "$owner" != 'общий' ] && [[ $name =~ $KEY_PATTERN ]] && [ -n "${BASH_REMATCH[1]:-}" ]; then
            kuser=$(trim "${BASH_REMATCH[1]}")
            if [[ ${owner,,} != "${kuser,,}"* ]] && [[ ${kuser,,} != "${owner,,}"* ]]; then foreign=$kuser; fi
        fi
        line "Ключ ($owner)" "${fpath##*/} → ${remotes:-?}$has_route${foreign:+ | ЧУЖОЙ КЛЮЧ ($foreign)}" "$([ -n "$foreign" ] && echo warn)" \
            "$([ -n "$foreign" ] && echo "Чужой VPN-ключ у $owner: ${fpath##*/}")"
    done

    if have nmcli; then
        while IFS= read -r nl; do
            nt=${nl##*:}; nname=${nl%:*}; nname=${nname//\\:/:}
            case $nt in vpn|wireguard) ;; *) continue ;; esac
            [ "$nt" = vpn ] && nt=$(nmcli -g vpn.service-type connection show "$nname" 2>/dev/null | sed 's/.*\.//')
            [ "$nt" = openvpn ] && ovpn=1
            foreign=''
            if [ -n "$KEY_PATTERN" ] && [ "$RUSER" != root ] && [[ $nname =~ $KEY_PATTERN ]] && [ -n "${BASH_REMATCH[1]:-}" ]; then
                kuser=$(trim "${BASH_REMATCH[1]}")
                if [[ ${RUSER,,} != "${kuser,,}"* ]] && [[ ${kuser,,} != "${RUSER,,}"* ]]; then foreign=$kuser; fi
            fi
            line 'Профиль NetworkManager' "$nname ($nt)${foreign:+ | ЧУЖОЙ КЛЮЧ ($foreign)}" "$([ -n "$foreign" ] && echo warn)" \
                "$([ -n "$foreign" ] && echo "Чужой VPN-профиль у $RUSER: $nname")"
            nm_vpn+=("$nname")
        done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
    fi
    if [ "${#files[@]}" -eq 0 ] && [ "${#nm_vpn[@]}" -eq 0 ] && [ "$ovpn" = 1 ]; then line 'Профили VPN' 'не найдены' warn; fi

    local addrs ifc ip tun=''
    if have ip; then addrs=$(ip -4 -o addr show 2>/dev/null | awk '{ print $2, $4 }')
    else addrs=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF { print "?", $1 }'); fi
    if [ -n "$VPN_PREFIX" ]; then
        while read -r ifc ip; do [[ $ip == "$VPN_PREFIX"* ]] && { tun="$ifc ${ip%/*}"; break; }; done <<< "$addrs"
        if [ -n "$tun" ]; then line 'VPN-туннель сейчас' "поднят, адрес ${tun#* } (${tun%% *})" ok
        else line 'VPN-туннель сейчас' 'не поднят'; fi
    else
        nst=0
        while read -r ifc ip; do
            case $ifc in tun*|tap*|wg*|ppp*) line 'VPN-интерфейс поднят' "$ifc: ${ip%/*}"; nst=1 ;; esac
        done <<< "$addrs"
        [ "$nst" = 0 ] && line 'VPN-туннель сейчас' 'не поднят (интерфейсов tun/tap/wg нет)'
    fi
    if [ "${#DCS[@]}" -gt 0 ]; then
        if [ "${#dcok[@]}" -gt 0 ]; then line 'Контроллеры домена' "доступны: $(join_by ', ' "${dcok[@]}")" ok
        else line 'Контроллеры домена' 'недоступны (порт 389)' warn; fi
    fi

    local has_vpn=0 mode ms='' mi=''
    [ "$ovpn" = 1 ] && [ $(( ${#files[@]} + ${#nm_vpn[@]} )) -gt 0 ] && has_vpn=1
    if [ "$in_corp" = 1 ] && [ "$has_vpn" = 1 ]; then mode='в домене + OpenVPN-ключ'; ms=ok
    elif [ "$in_corp" = 1 ]; then mode='в домене, без VPN (офис)'; ms=ok
    elif [ "$has_vpn" = 1 ]; then mode='НЕ в домене, только OpenVPN-ключ'; ms=warn; mi='Не введён в домен, работает только по VPN-ключу'
    else mode='ни домена, ни VPN'; ms=bad; mi='Не в домене и без VPN'; fi
    # без конфига ожидаемого режима нет — просто показываем факт
    if [ -n "$CORP_DOMAIN" ]; then line 'Итог' "$mode" "$ms" "$mi"; else line 'Итог' "$mode"; fi
    REPORT['Домен/VPN']=$mode

    # ================= итог =================
    section 'Итог'
    if [ "${#ISSUES[@]}" -gt 0 ]; then
        printf '%s  Замечаний: %d%s\n' "$C_WARN" "${#ISSUES[@]}" "$C_0"
        for l in "${ISSUES[@]}"; do printf '%s  - %s%s\n' "$C_WARN" "$l" "$C_0"; done
    else
        printf '%s  Замечаний нет%s\n' "$C_OK" "$C_0"
    fi
    [ "${#INCOMPLETE[@]}" -gt 0 ] && warn_msg "  Неполные проверки (нет root): $(join_by ', ' "${INCOMPLETE[@]}")"
    REPORT['Замечания']=$(join_by '; ' "${ISSUES[@]}")

    if [ -n "$CSV" ]; then
        if write_csv "$CSV" 2>/dev/null; then note "
  Строка добавлена в $CSV"; else err_msg "
  Не удалось записать CSV: $CSV"; fi
    fi
    if [ -n "$JSON" ]; then
        if write_json "$JSON" 2>/dev/null; then note "  Отчёт сохранён в $JSON"; else err_msg "  Не удалось записать JSON: $JSON"; fi
    fi
    echo
}

main "$@"
