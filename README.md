# workstation-inventory

Скрипты инвентаризации рабочих мест для **Windows** и **Linux**. Запускаются одной командой и выводят в консоль цветной отчёт:
зелёный — в порядке, жёлтый — стоит посмотреть, красный — проблема. В конце печатается список замечаний.
Строку по каждому ПК можно дописать в общую CSV-таблицу, а полный отчёт сохранить в JSON.

Скрипты **только читают**: в системе ничего не меняют. Linux-версия даже не обновляет списки пакетов, а берёт их из кэша.

## Что проверяется

| Раздел | Windows (`windows/inventory.ps1`) | Linux (`linux/inventory.sh`) |
|---|---|---|
| Общее | имя ПК, пользователь, производитель, модель, серийник, ноутбук или нет, время без перезагрузки (> 14 дн. — жёлтый) | то же: `/sys/class/dmi/id`, `chassis_type`, `/proc/uptime` |
| Процессор | модель, ядра / потоки | `lscpu` |
| Память | объём (< 8 ГБ — красный, < 16 ГБ — жёлтый), модули: тип, частота, производитель, распайка или съёмная плашка ([как определяется](#распайка-или-слот)), слоты по BIOS | `/proc/meminfo` + `dmidecode -t memory` (нужен root), те же правила определения распайки |
| Диски | физические диски (SSD / HDD / NVMe, состояние), свободное место на томах | `lsblk` (тип по ROTA и TRAN), SMART через `smartctl`, свободное место на `/` и `/home` |
| Периферия | мониторы (EDID), принтеры и способ подключения, батарея и её износ, ИБП | мониторы из `/sys/class/drm/*/edid` (`edid-decode`, если установлен), `lpstat`, `/sys/class/power_supply`, ИБП через `upsc` (NUT) или `lsusb` |
| ОС и обновления | версия, сборка, срок поддержки Microsoft, TPM, Secure Boot, служба обновлений, последнее обновление, доступные обновления, ожидание перезагрузки | дистрибутив, ядро, срок поддержки (Ubuntu / Debian), TPM, Secure Boot, последнее обновление и доступные обновления (apt / dnf / yum / zypper / pacman), `reboot-required` / `needs-restarting` |
| Антивирус | продукты из Центра безопасности, включён ли, актуальны ли базы; ожидаемый антивирус из конфига | Kaspersky Endpoint Security for Linux (`kesl-control`), ClamAV (версия и возраст баз), иначе «не найден» |
| Администраторы | состав группы «Администраторы», доменные учётки в ней, админ ли текущий пользователь, встроенный Administrator | члены групп sudo / wheel / admin, админ ли пользователь (`sudo -l`), пароль root, вход root по SSH |
| Домен и VPN | домен, доверие с доменом, тип учётки, OpenVPN GUI / Connect и версия, ключи `.ovpn` (в том числе чужие), туннель, доступность контроллеров домена | `realm` / sssd / winbind, доверие (`adcli testjoin` / `wbinfo -t`), версия `openvpn`, профили в `/etc/openvpn`, `/home` и NetworkManager, туннель, доступность контроллеров по TCP 389 |

Без прав администратора (root) скрипты всё равно работают, а в конце перечисляют проверки, которые остались неполными.

## Компьютер компании или личный

В начале скрипт спрашивает: «Это компьютер компании или личный? 1 — компании, 2 — личный».
Чтобы не спрашивать, передайте `-Owner company` / `-Owner personal` (в Linux `--owner company` / `--owner personal`).

| | Компании | Личный |
|---|---|---|
| Железо: производитель, модель, CPU, память, диски, мониторы, принтеры, батарея, ИБП | да | да |
| ОС, сроки поддержки, обновления, TPM, Secure Boot, антивирус | да | да |
| Права админа у пользователя, вход в домен, наличие VPN, замечания | да | да, без имён |
| Имя ПК, имя пользователя, серийные номера (ПК и мониторов) | да | скрыто |
| Состав группы администраторов, доменные учётки | имена | только количество |
| Имя домена, сервер входа, имена и серверы VPN-ключей, IP туннеля и принтеров, пути к файлам отчёта | да | скрыто |

В личном режиме вместо скрытых значений в консоли, CSV и JSON стоит «скрыто (личный ПК)». В колонке CSV `Тип` пишется «компании» или «личный».

> Если спросить не получается (нет консоли, `-NonInteractive`, нет терминала у `curl | bash`), компьютер **считается личным**.
> Поэтому при массовом запуске (GPO, планировщик, скрипт входа) всегда указывайте `-Owner company` / `--owner company`,
> иначе в общей таблице не будет имён ПК, а скрипт входа может ждать ответа в невидимом окне.

## Быстрый запуск

Однострочники берут файлы из конкретного релиза, а не из `main`. Подставьте нужную версию вместо `v1.0.2`.

### Windows

PowerShell **от администратора**:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData('https://github.com/softsol-pro/workstation-inventory/releases/download/v1.0.2/inventory.ps1')).TrimStart([char]0xFEFF))) -SkipWU
```

С конфигом и записью в общую таблицу:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData('https://github.com/softsol-pro/workstation-inventory/releases/download/v1.0.2/inventory.ps1')).TrimStart([char]0xFEFF))) -Owner company -Config '\\server\share\inventory\config.json' -CsvPath '\\server\share\inventory\inventory.csv'
```

> Почему не `irm`: GitHub отдаёт ассеты релиза как `application/octet-stream`, и `Invoke-RestMethod` в Windows PowerShell 5.1
> декодирует их как Latin-1, игнорируя BOM. Кириллица превращается в мусор, и скрипт не запускается.
> Поэтому файл скачивается байтами и явно декодируется как UTF-8. `ExecutionPolicy` на такой запуск не влияет.

### Linux

```bash
curl -fsSL https://github.com/softsol-pro/workstation-inventory/releases/download/v1.0.2/inventory.sh | sudo bash -s -- --skip-updates
```

С конфигом и записью в общую таблицу:

```bash
curl -fsSL https://github.com/softsol-pro/workstation-inventory/releases/download/v1.0.2/inventory.sh | sudo bash -s -- --owner company --config https://intranet.example.com/inventory/config.json --csv /mnt/share/inventory/inventory.csv
```

> Ссылки `releases/download/...` открываются без авторизации, только если репозиторий **публичный**.
> Если репозиторий приватный, используйте запуск с общей папки (ниже).

## Проверка хеша перед запуском

К каждому релизу приложен файл `SHA256SUMS`. Скачайте скрипт, сверьте хеш и только потом запускайте.

### Windows

```powershell
$v = 'v1.0.2'; $b = "https://github.com/softsol-pro/workstation-inventory/releases/download/$v"; $f = "$env:TEMP\inventory.ps1"
$wc = New-Object Net.WebClient; $wc.DownloadFile("$b/inventory.ps1", $f)
$expected = (($wc.DownloadString("$b/SHA256SUMS") -split "`n" | Where-Object { $_ -match 'inventory\.ps1' }) -split '\s+')[0]
if ((Get-FileHash $f -Algorithm SHA256).Hash -eq $expected) { powershell -ExecutionPolicy Bypass -File $f -SkipWU } else { Write-Host 'ХЕШ НЕ СОВПАДАЕТ' -ForegroundColor Red }
```

### Linux

```bash
cd "$(mktemp -d)" && v=v1.0.2 && b=https://github.com/softsol-pro/workstation-inventory/releases/download/$v && curl -fsSLO "$b/inventory.sh" -fsSLO "$b/SHA256SUMS" && sha256sum -c --ignore-missing SHA256SUMS && sudo bash inventory.sh --skip-updates
```

## Запуск с общей папки (без интернета)

Положите `inventory.ps1`, `inventory.sh` и `config.json` в общую папку, например `\\server\share\inventory\`.

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File \\server\share\inventory\inventory.ps1 -Owner company -Config \\server\share\inventory\config.json -CsvPath \\server\share\inventory\inventory.csv
```

Linux (папка смонтирована, например, `sudo mount -t cifs //server/share /mnt/share -o username=...`):

```bash
sudo bash /mnt/share/inventory/inventory.sh --owner company --config /mnt/share/inventory/config.json --csv /mnt/share/inventory/inventory.csv
```

## Параметры

| Windows | Linux | Что делает |
|---|---|---|
| `-Owner company\|personal` | `--owner company\|personal` | чей компьютер; без параметра скрипт спросит, а без консоли или терминала считает ПК личным ([подробнее](#компьютер-компании-или-личный)) |
| `-Config <путь\|URL>` | `--config <путь\|URL>` | конфиг организации: локальный путь, UNC-путь (Windows) или `https://`-URL |
| `-CsvPath <файл>` | `--csv <файл>` | дописать строку по этому ПК в CSV (разделитель `;`, UTF-8 с BOM, открывается в Excel). Если файла нет, он создаётся с заголовком |
| `-JsonPath <файл>` | `--json <файл>` | сохранить полный отчёт в JSON: сводка, замечания, неполные проверки и все строки вывода |
| `-SkipWU` | `--skip-updates` | не проверять доступные обновления (на Windows поиск в Центре обновления занимает до 1–2 минут) |

Колонки CSV у обеих версий одинаковые, поэтому Windows и Linux можно писать в одну таблицу.
Для Linux в колонке `Windows` будет дистрибутив, в `Сборка` — ядро, в `C: свободно ГБ` — свободное место на `/`.

## Конфиг

Всё, что относится к конкретной организации, вынесено в JSON-конфиг. Пример с вымышленными значениями — [config.example.json](config.example.json):

```json
{
  "domain": "corp.example.com",
  "dcs": ["10.0.0.10", "10.0.0.11"],
  "vpnTunnelPrefix": "10.8.0.",
  "vpnExtraRouteIp": "203.0.113.10",
  "minOpenVpn": "2.6.0",
  "corpVpnKeyPattern": "^example-corp_(.+)$",
  "expectedAv": "Kaspersky"
}
```

| Поле | Что значит |
|---|---|
| `domain` | FQDN домена AD. Компьютер в другом домене или вне домена получает замечание |
| `dcs` | IP контроллеров домена. По ним проверяется доступность (TCP 389) и доверие с доменом |
| `vpnTunnelPrefix` | начало адреса VPN-туннеля. По нему видно, поднят ли туннель |
| `vpnExtraRouteIp` | IP, маршрут до которого должен быть в `.ovpn`. Если маршрут есть, у ключа появляется пометка |
| `minOpenVpn` | минимальная версия OpenVPN (по умолчанию `2.6.0`) |
| `corpVpnKeyPattern` | регулярное выражение для имени корпоративного ключа. Группа 1 — имя пользователя: если ключ лежит в чужом профиле, это «чужой ключ» |
| `expectedAv` | подстрока в названии ожидаемого антивируса. Если такого нет, это замечание |

**Без конфига** проверки домена, VPN и антивируса работают в универсальном режиме: показывают факты (в каком домене ПК,
какие VPN-адаптеры подняты, какие антивирусы найдены), но ничего не сравнивают с ожидаемыми значениями.

Настоящий конфиг **не храните в этом репозитории**: `.gitignore` и так исключает все `*.json`, кроме примера.
Держите его в общей папке или на внутреннем https-сервере.

В Linux конфиг разбирается через `jq`, а если его нет — через `python3`. Если нет ни того ни другого, скрипт работает без конфига и предупреждает об этом.
Регэксп `corpVpnKeyPattern` в Linux проверяется как ERE (bash `=~`), поэтому PCRE-конструкции вроде `\d` или `(?i)` там не работают.

## Распайка или слот

Отдельного поля «распаяно» в SMBIOS нет, поэтому скрипты решают по признакам. Правила идут по порядку, первое сработавшее решает:

| # | Признак | Вердикт |
|---|---|---|
| 1 | тип памяти LPDDR | распайка (LPDDR) |
| 2 | Part Number — номер микросхемы DRAM, а не модуля: `K4…` (Samsung), `H5…` / `H9…` / `HKN…` (SK Hynix), `MT40/41/46/52/53/60/61/62…` (Micron), `NT5…` / `NT6…` (Nanya), `CXDB…` (CXMT) | распайка (номер микросхемы) |
| 3 | Part Number готового модуля: `M378` / `M471` / `M393` (Samsung), `HMA` / `HMT` / `HMCG` (SK Hynix), `MTA` / `MTC` (Micron), `KVR` / `KF` / `KCP` / `KHX` / `ACR` (Kingston), `CT` / `BL` (Crucial), `F4-` / `F5-` (G.Skill), `CM…` (Corsair) и другие | съёмная плашка (номер модуля) |
| 4 | настольный корпус (Desktop, Tower, Mini Tower и т. п.) | съёмная плашка (настольный ПК) |
| 5 | серийник пустой, из нулей или одинаковый у нескольких модулей | скорее распайка |
| 6 | форм-фактор DIMM или SODIMM | скорее съёмная |
| 7 | ничего из перечисленного | не определить |

Вердикты 1–4 надёжные, 5–7 — оценка. Если хотя бы один модуль определён по правилам 5–7, в строке «Итого» появляется пометка
«часть — оценка», а в колонке CSV `ОЗУ распаяно/слоты` — «(оценка)». Объём, который не удалось определить, пишется как `/?N`, например `8/8/?8 (оценка)`.

Списки префиксов заданы в скриптах (`$ChipPn` / `$ModulePn` в Windows, `CHIP_PN` / `MODULE_PN` в Linux). Если встретился модуль,
который определился как «не определить» или «скорее…», его префикс можно добавить в нужный список.

## Пример вывода

```
Инвентаризация WS-042 — 19.10.2026 14:27 (inventory.ps1 1.0.2)
Конфиг: \\server\share\inventory\config.json

=== Общее ===
  Чей компьютер               компании
  Компьютер                   WS-042
  Пользователь                CORP\ivanov
  Модель                      ThinkPad T14 Gen 2 (20W0004XRT)
  Тип                         Ноутбук
  Без перезагрузки            3 дн. 2 ч.

=== Оперативная память ===
  Всего                       16 ГБ (занято 63%, свободно 5.9 ГБ)
  ChannelA-DIMM0              8 ГБ DDR4-3200 | Samsung K4AAG165WA-BCWE | распайка (номер микросхемы)
  ChannelB-DIMM0              8 ГБ DDR4-3200 | Samsung M471A1K43DB1-CWE | съёмная плашка (номер модуля)
  Итого                       распаяно 8 ГБ, в слотах 8 ГБ | слотов по BIOS: 2, макс. 32 ГБ

=== Windows и обновления ===
  Версия                      Windows 11 Pro (25H2)
  Поддержка Microsoft         до 12.10.2027 — версия актуальна
  Последнее обновление        14.10.2026 (5 дн. назад)

=== Домен и VPN ===
  Домен                       в домене corp.example.com
  Доверие с доменом           в порядке
  OpenVPN GUI                 установлен, версия 2.5.8
  Ключ (ivanov)               example-corp_petrov.ovpn → vpn.example.com | ЧУЖОЙ КЛЮЧ (petrov)
  Контроллеры домена          доступны: 10.0.0.10, 10.0.0.11
  Итог                        в домене + OpenVPN-ключ

=== Итог ===
  Замечаний: 2
  - Старый OpenVPN 2.5.8 — обновить до 2.6.0+
  - Чужой VPN-ключ у ivanov: example-corp_petrov.ovpn
```

## Проверка достоверности

В папке `tests` лежат скрипты, которые запускают инвентаризацию на текущем ПК во всех режимах и сверяют результат
с независимыми источниками. В системе они ничего не меняют. Их стоит прогнать на нескольких разных машинах
(ноутбук, настольный ПК, моноблок, виртуалка), прежде чем раскатывать скрипт на всех.

```powershell
powershell -ExecutionPolicy Bypass -File tests\check-windows.ps1
```

```bash
sudo bash tests/check-linux.sh
```

Что сверяется:

| Проверка | Windows | Linux |
|---|---|---|
| имя ПК | `$env:COMPUTERNAME` | `hostname` |
| процессор | реестр `CentralProcessor\0` | `/proc/cpuinfo` |
| объём ОЗУ | `TotalPhysicalMemory` (± 2 ГБ) | `MemTotal` (± 2,5 ГБ) |
| сборка / ядро | `ver` | `uname -r` |
| свободно на системном томе | `Get-PSDrive` (± 2 ГБ) | `stat -f /` (± 1 ГБ) |
| число дисков | `Get-Disk` | `/sys/block` |
| последнее обновление | не раньше последнего KB из `Get-HotFix` | — |
| модули памяти разобраны | — | при root и данных `dmidecode` |
| личный режим | в выводе, CSV и JSON нет имени ПК, пользователя, серийника BIOS и домена | то же: `hostname`, пользователь, `product_serial`, домен из `realm` |
| без консоли и без `-Owner` / `--owner` | ПК считается личным, скрипт не зависает | то же (через `setsid`, без терминала) |
| запуск как однострочник | через `scriptblock` | через stdin, как `curl \| bash` |

CI запускает эти проверки на каждый коммит: Windows Server 2022 и 2025 (от администратора),
виртуалки Ubuntu 22.04 и 24.04 (от root, со строгим режимом `--strict`: под root не должно остаться неполных проверок),
контейнеры Ubuntu 22.04 / 24.04 и Debian 12 / 13.

Распайку памяти, батарею, мониторы, принтеры и ИБП на виртуалках проверить нельзя: такого железа там нет.
Эти разделы стоит один раз сверить вручную на реальных ПК.

## Сопровождение

- **Сроки поддержки ОС обновлять раз в год.** Таблица `$Life` в начале `windows/inventory.ps1` (плюс `$LatestWin11`) и таблица `EOL` в начале `linux/inventory.sh`.
  Сборки новее таблицы Windows-скрипт считает актуальными. Версии Ubuntu / Debian, которых нет в таблице, считаются старыми, если они не новее самой новой версии в таблице.
- `windows/inventory.ps1` хранится в **UTF-8 с BOM** и совместим с Windows PowerShell 5.1 (без `?:`, `??`, `&&`). CI проверяет и то, и другое.
- Линтеры: PSScriptAnalyzer (настройки в [PSScriptAnalyzerSettings.psd1](PSScriptAnalyzerSettings.psd1)) и shellcheck.
  Workflow [lint.yml](.github/workflows/lint.yml) также запускает [проверку достоверности](#проверка-достоверности) на нескольких ОС.

### Выпуск релиза

1. Поднять версию в `$ScriptVersion` (`windows/inventory.ps1`) и `VERSION` (`linux/inventory.sh`).
2. Закоммитить, поставить тег и запушить:
   ```bash
   git tag v1.0.3 && git push origin v1.0.3
   ```
3. Workflow [release.yml](.github/workflows/release.yml) проверит, что версия в скриптах совпадает с тегом, и приложит к релизу `inventory.ps1`, `inventory.sh` и `SHA256SUMS`.
4. Обновить версию в однострочниках этого README.
