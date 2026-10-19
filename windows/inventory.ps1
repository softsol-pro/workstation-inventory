<#
  inventory.ps1 — инвентаризация рабочего места (Windows)
  Железо, периферия, Windows и обновления, антивирус, локальные админы, домен / OpenVPN.
  Скрипт только читает: в системе ничего не меняет.

  Запуск (лучше от администратора — тогда видно TPM, батарею, доверие с доменом, чужие профили VPN):
    powershell -ExecutionPolicy Bypass -File .\inventory.ps1
    powershell -ExecutionPolicy Bypass -File .\inventory.ps1 -SkipWU
    powershell -ExecutionPolicy Bypass -File .\inventory.ps1 -Config \\server\share\config.json -CsvPath \\server\share\inventory.csv
    powershell -ExecutionPolicy Bypass -File .\inventory.ps1 -JsonPath .\report.json
    powershell -ExecutionPolicy Bypass -File .\inventory.ps1 -Owner company   # не спрашивать, чей ПК (company / personal)
  В начале скрипт спрашивает, чей это компьютер. Для личного ПК имя ПК, пользователь, серийники, учётки,
  имя домена, VPN-ключи и IP-адреса не собираются.
  Запуск одной строкой с GitHub — см. README.md
#>
[CmdletBinding()]
param(
    [string]$Owner,     # company / personal — чей компьютер; если не указан, скрипт спросит (без консоли — считает личным)
    [string]$Config,    # конфиг организации: путь (локальный / UNC) или https-URL; без него домен/VPN/антивирус только показываются, без сравнения
    [string]$CsvPath,   # дописать строку по этому ПК в общую таблицу (разделитель ";", открывается в Excel)
    [string]$JsonPath,  # сохранить полный отчёт в JSON
    [switch]$SkipWU     # не спрашивать Центр обновления о доступных обновлениях (быстрее)
)

$ErrorActionPreference = 'SilentlyContinue'
$ScriptVersion = '1.0.2'

# ================= сроки поддержки Windows =================
# ОБНОВЛЯТЬ РАЗ В ГОД — когда выходит новая версия Windows 11 (обычно осенью):
# добавить строку с новой сборкой и поправить $LatestWin11.
# Сроки: https://learn.microsoft.com/lifecycle/products/
# сборка = Название, Home/Pro до, Enterprise/Education до, LTSC до
$Life = @{
    17763 = 'Windows 10 1809 / LTSC 2019', '2020-11-10', '2021-05-11', '2029-01-09'
    19044 = 'Windows 10 21H2 / LTSC 2021', '2023-06-13', '2024-06-11', '2027-01-12'
    19045 = 'Windows 10 22H2',             '2025-10-14', '2025-10-14', ''
    22621 = 'Windows 11 22H2',             '2024-10-08', '2025-10-14', ''
    22631 = 'Windows 11 23H2',             '2025-11-11', '2026-11-10', ''
    26100 = 'Windows 11 24H2 / LTSC 2024', '2026-10-13', '2027-10-12', '2029-10-09'
    26200 = 'Windows 11 25H2',             '2027-10-12', '2028-10-10', ''
}
$LatestWin11  = '25H2'
$LifeMaxBuild = ($Life.Keys | Measure-Object -Maximum).Maximum

# ================= вывод =================
$Issues     = New-Object System.Collections.Generic.List[string]
$Incomplete = New-Object System.Collections.Generic.List[string]
$Details    = New-Object System.Collections.Generic.List[object]
$Ctx        = @{ Section = '' }
$Colors     = @{ ok = 'Green'; warn = 'Yellow'; bad = 'Red' }
$Report     = [ordered]@{}
'Дата','ПК','Пользователь','Модель','Серийник','Тип','CPU','ОЗУ ГБ','ОЗУ распаяно/слоты','Диски','C: свободно ГБ',
'Мониторы','Принтеры','ИБП/батарея','Windows','Сборка','Поддержка до','Последнее обновление','Ожидают обновлений',
'Антивирус','Польз. админ','Домен/VPN','OpenVPN','Замечания' | ForEach-Object { $Report[$_] = '' }
$Report['Дата'] = Get-Date -Format 'yyyy-MM-dd HH:mm'
$Report['ПК']   = $env:COMPUTERNAME

function Section([string]$Title) { $Ctx.Section = $Title; Write-Host "`n=== $Title ===" -ForegroundColor Cyan }
function Line([string]$Name, $Value, [string]$State, [string]$Issue) {
    $c = 'Gray'; if ($State -and $Colors.ContainsKey($State)) { $c = $Colors[$State] }
    $Details.Add([pscustomobject]@{ Section = $Ctx.Section; Name = $Name; Value = "$Value"; State = $State })
    if ($Name.Length -gt 27) { $Name = $Name.Substring(0, 26) + '…' }
    Write-Host ('  {0,-28}' -f $Name) -NoNewline
    Write-Host $Value -ForegroundColor $c
    if ($Issue) { $Issues.Add($Issue) }
}
function Test-Port([string]$Ip, [int]$Port, [int]$Ms = 800) {
    $t = New-Object Net.Sockets.TcpClient
    try { $a = $t.BeginConnect($Ip, $Port, $null, $null); ($a.AsyncWaitHandle.WaitOne($Ms) -and $t.Connected) }
    catch { $false } finally { $t.Close() }
}
function ConvertFrom-WmiString($Arr) { if ($Arr) { (($Arr | Where-Object { $_ -ne 0 }) | ForEach-Object { [char]$_ }) -join '' } }

# Распайка или слот. Поля «распаяно» в SMBIOS нет, поэтому решаем по признакам — первый сработавший решает.
# Part Number с номером микросхемы DRAM (а не модуля) — память распаяна на плате
$ChipPn   = '^(K4[A-Z0-9]|H5[A-Z]|H9[A-Z]|HKN|MT(40|41|46|52|53|60|61|62)[A-Z]|NT5|NT6|CXDB)'
# Part Number готового модуля (Samsung, SK Hynix, Micron, Kingston, Crucial, G.Skill, Corsair, ADATA, HyperX, Team, Silicon Power, Ramaxel)
$ModulePn = '^(M3[79][0-9]|M47[0-9]|HMA|HMT|HMCG|HMAA|MTA|MTC|KVR|KF[0-9]|KCP|KHX|KTD|KTH|KTL|ACR[0-9]|CT[0-9]|BL[0-9]|F[345]-|CM[A-Z]|AD[45]|AX[45]|HX[45]|TF[0-9]|TED|SP0|RMSA|RMUA|99U5)'
function Get-MemVerdict([bool]$IsLpddr, [string]$PartNumber, [string]$Serial, [bool]$SerialDup, [bool]$IsDimm, [bool]$IsDesktop) {
    $pn = $PartNumber.Trim().ToUpper()
    $snEmpty = ($Serial -match '^0*$') -or ($Serial -in 'Unknown', 'Not Specified', 'None', '[Empty]')
    if ($IsLpddr)                     { $r = 'распайка (LPDDR)', 'sold', $true }
    elseif ($pn -match $ChipPn)       { $r = 'распайка (номер микросхемы)', 'sold', $true }
    elseif ($pn -match $ModulePn)     { $r = 'съёмная плашка (номер модуля)', 'slot', $true }
    elseif ($IsDesktop)               { $r = 'съёмная плашка (настольный ПК)', 'slot', $true }
    elseif ($snEmpty -or $SerialDup)  { $r = 'скорее распайка (серийник пустой / повторяется)', 'sold', $false }
    elseif ($IsDimm)                  { $r = 'скорее съёмная (форм-фактор DIMM / SODIMM)', 'slot', $false }
    else                              { $r = 'не определить', 'unknown', $false }
    [pscustomobject]@{ Text = $r[0]; Kind = $r[1]; Sure = $r[2] }
}

# ================= конфиг =================
# Всё, что относится к конкретной организации, берётся из JSON-конфига (пример — config.example.json)
function Read-InventoryConfig([string]$Source) {
    try {
        if ($Source -match '^https://') {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $wc = New-Object Net.WebClient
            $wc.Encoding = [Text.Encoding]::UTF8
            $raw = $wc.DownloadString($Source)
        } elseif ($Source -match '^[a-z]+://') {
            throw 'поддерживается только https://'
        } else {
            $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source)
            $raw  = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        }
        return ($raw.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Host "Не удалось прочитать конфиг ${Source}: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}
$Cfg = $null
if ($Config) { $Cfg = Read-InventoryConfig $Config }
function Get-CfgValue([string]$Name) { if ($Cfg -and $Cfg.PSObject.Properties[$Name]) { $Cfg.$Name } }

$CorpDomain   = [string](Get-CfgValue 'domain')             # FQDN домена AD
$DCs          = @(Get-CfgValue 'dcs' | Where-Object { $_ }) # IP контроллеров домена
$VpnPrefix    = [string](Get-CfgValue 'vpnTunnelPrefix')    # начало адреса туннеля, например "10.8.0."
$ExtraRouteIp = [string](Get-CfgValue 'vpnExtraRouteIp')    # IP, маршрут до которого должен быть в .ovpn
$KeyPattern   = [string](Get-CfgValue 'corpVpnKeyPattern')  # регэксп имени ключа, группа 1 — имя пользователя
$ExpectedAv   = [string](Get-CfgValue 'expectedAv')         # подстрока в названии антивируса
$MinOvpn      = [version]'2.6.0'
$mv = Get-CfgValue 'minOpenVpn'; if ($mv) { try { $MinOvpn = [version]$mv } catch {} }
if ($KeyPattern) {
    try { $null = New-Object regex $KeyPattern } catch {
        Write-Host "corpVpnKeyPattern в конфиге — неверный регэксп, проверка чужих ключей отключена" -ForegroundColor Red
        $KeyPattern = ''
    }
}

$Me      = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = ([Security.Principal.WindowsPrincipal]$Me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ================= чей компьютер =================
# Личный ПК: железо, ОС, обновления и защита — собираем; имя ПК, пользователь, серийники, учётки,
# имя домена, VPN-ключи и IP-адреса — нет (в консоли, CSV и JSON вместо них «скрыто»)
$Owner = "$Owner".Trim().ToLower(); $OwnerNote = $null
if ($Owner -in 'company', 'компании', '1')    { $Owner = 'company' }
elseif ($Owner -in 'personal', 'личный', '2') { $Owner = 'personal' }
elseif ($Owner) { Write-Host "Неизвестное значение -Owner '$Owner' (нужно company или personal)" -ForegroundColor Red; $Owner = '' }
if (-not $Owner) {
    $canAsk = [Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' })
    for ($i = 0; $canAsk -and -not $Owner -and $i -lt 3; $i++) {
        $a = ''
        try { $a = "$(Read-Host "`nЭто компьютер компании или личный? 1 — компании, 2 — личный")".Trim().ToLower() } catch { $canAsk = $false }
        if ($a -in '1', 'к', 'компании', 'company')    { $Owner = 'company' }
        elseif ($a -in '2', 'л', 'личный', 'personal') { $Owner = 'personal' }
    }
    if (-not $Owner) { $Owner = 'personal'; $OwnerNote = 'Не удалось спросить, чей это ПК, — считаю личным. Для учёта ПК компании запустите с -Owner company' }
}
$IsPersonal = $Owner -eq 'personal'
function Hide($Value) { if ($IsPersonal) { 'скрыто (личный ПК)' } else { $Value } }

# ================= общее =================
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$encl = Get-CimInstance Win32_SystemEnclosure
$IsLaptop = @($encl.ChassisTypes | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0
$Model = if ($cs.Manufacturer -match 'LENOVO' -and $cs.SystemFamily) { "$($cs.SystemFamily) ($($cs.Model))" } else { $cs.Model }
$Uptime = (Get-Date) - $os.LastBootUpTime

Write-Host "`nИнвентаризация $(if ($IsPersonal) { 'личного ПК' } else { $env:COMPUTERNAME }) — $(Get-Date -Format 'dd.MM.yyyy HH:mm') (inventory.ps1 $ScriptVersion)" -ForegroundColor White
if ($OwnerNote) { Write-Host $OwnerNote -ForegroundColor DarkYellow }
if ($IsPersonal) { Write-Host 'Личный ПК: имя ПК, пользователь, серийники, учётки, домен, VPN-ключи и IP-адреса не собираются' -ForegroundColor DarkGray }
else             { Write-Host 'Компьютер компании: собирается полный отчёт' -ForegroundColor DarkGray }
if (-not $IsAdmin) { Write-Host 'Запущено без прав администратора — часть проверок будет неполной' -ForegroundColor DarkYellow }
if ($Cfg)        { Write-Host "Конфиг: $(if ($IsPersonal) { 'загружен' } else { $Config })" -ForegroundColor DarkGray }
elseif ($Config) { Write-Host 'Конфиг не загружен — домен, VPN и антивирус проверяются без сравнения с ожидаемыми значениями' -ForegroundColor DarkYellow }
else             { Write-Host 'Без конфига — домен, VPN и антивирус проверяются без сравнения с ожидаемыми значениями' -ForegroundColor DarkGray }

Section 'Общее'
Line 'Чей компьютер'   $(if ($IsPersonal) { 'личный' } else { 'компании' })
Line 'Компьютер'      (Hide $env:COMPUTERNAME)
Line 'Пользователь'   (Hide $cs.UserName)
Line 'Производитель'  $cs.Manufacturer
Line 'Модель'         $Model
Line 'Серийный номер' (Hide $bios.SerialNumber)
Line 'Тип'            $(if ($IsLaptop) { 'Ноутбук' } else { 'Настольный / прочее' })
$upSt = if ($Uptime.TotalDays -gt 14) { 'warn' } else { 'ok' }
Line 'Без перезагрузки' ('{0} дн. {1} ч.' -f [int][math]::Floor($Uptime.TotalDays), $Uptime.Hours) $upSt $(if ($upSt -eq 'warn') { 'Не перезагружался больше 2 недель' })
$Report['ПК']           = Hide $env:COMPUTERNAME
$Report['Пользователь'] = Hide $cs.UserName
$Report['Модель']       = "$($cs.Manufacturer) $Model"
$Report['Серийник']     = Hide $bios.SerialNumber
$Report['Тип']          = "$(if ($IsLaptop) { 'Ноутбук' } else { 'ПК' }), $(if ($IsPersonal) { 'личный' } else { 'компании' })"

# ================= процессор =================
Section 'Процессор'
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cpuName = ($cpu.Name -replace '\s+', ' ').Trim()
Line 'Модель'          $cpuName
Line 'Ядер / потоков'  "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"
$Report['CPU'] = $cpuName

# ================= память =================
Section 'Оперативная память'
$mem     = @(Get-CimInstance Win32_PhysicalMemory)
$memArr  = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
$totalGB = [math]::Round((($mem | Measure-Object Capacity -Sum).Sum) / 1GB)
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$usedPct = [math]::Round(100 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
$ramSt   = if ($totalGB -lt 8) { 'bad' } elseif ($totalGB -lt 16) { 'warn' } else { 'ok' }
Line 'Всего' "$totalGB ГБ (занято $usedPct%, свободно $freeGB ГБ)" $ramSt $(if ($totalGB -lt 8) { "Мало ОЗУ: $totalGB ГБ" })

$mt  = @{ 24 = 'DDR3'; 26 = 'DDR4'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
$dup = @($mem | Group-Object { "$($_.SerialNumber)".Trim() } | Where-Object Count -gt 1 | ForEach-Object Name)
$IsDesktop = (-not $IsLaptop) -and @($encl.ChassisTypes | Where-Object { $_ -in 3,4,5,6,7,15,16,17,23,24 }).Count -gt 0
$solderedGB = 0; $slotGB = 0; $unknownGB = 0; $guess = $false
foreach ($m in $mem) {
    $sn = "$($m.SerialNumber)".Trim(); $t = [int]$m.SMBIOSMemoryType
    $type = if ($mt.ContainsKey($t)) { $mt[$t] } else { "код $t" }
    $gb = [math]::Round($m.Capacity / 1GB)
    $v = Get-MemVerdict -IsLpddr ($t -in 29, 30, 35) -PartNumber "$($m.PartNumber)" -Serial $sn `
                        -SerialDup ($sn -in $dup) -IsDimm ($m.FormFactor -in 8, 12) -IsDesktop $IsDesktop
    switch ($v.Kind) { 'sold' { $solderedGB += $gb } 'slot' { $slotGB += $gb } default { $unknownGB += $gb } }
    if (-not $v.Sure) { $guess = $true }
    $label = ("{0} {1}" -f $m.BankLabel, $m.DeviceLocator).Trim()
    Line $label ("{0} ГБ {1}-{2} | {3} {4} | {5}" -f $gb, $type, $m.ConfiguredClockSpeed, $m.Manufacturer, "$($m.PartNumber)".Trim(), $v.Text)
}
$memSum = "распаяно $solderedGB ГБ, в слотах $slotGB ГБ"
if ($unknownGB) { $memSum += ", не определено $unknownGB ГБ" }
if ($guess)     { $memSum += ' (часть — оценка)' }
Line 'Итого' ("{0} | слотов по BIOS: {1}, макс. {2} ГБ" -f $memSum, $memArr.MemoryDevices, [math]::Round($memArr.MaxCapacity / 1MB))
$Report['ОЗУ ГБ'] = $totalGB
$Report['ОЗУ распаяно/слоты'] = "$solderedGB/$slotGB$(if ($unknownGB) { "/?$unknownGB" })$(if ($guess) { ' (оценка)' })"

# ================= диски =================
Section 'Диски'
$diskList = @()
$pd = @(Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })
if ($pd.Count) {
    foreach ($d in $pd) {
        $media = "$($d.MediaType)"; $bus = "$($d.BusType)"; $health = "$($d.HealthStatus)"
        $type = if ($media -in 'SSD', '4') { 'SSD' } elseif ($media -in 'HDD', '3') { 'HDD' } else { '?' }
        if ($bus -in 'NVMe', '17') { $type = 'SSD NVMe'; $bus = 'NVMe' }
        $size = [math]::Round($d.Size / 1GB)
        $hs = if ($health -in 'Healthy', '0') { 'ok' } elseif ($health -in 'Warning', '1') { 'warn' } else { 'bad' }
        Line "Диск $($d.DeviceId)" ("{0} | {1} | {2} ГБ | {3} | {4}" -f $d.FriendlyName, $type, $size, $bus, $health) $hs $(if ($hs -ne 'ok') { "Диск $($d.FriendlyName): состояние $health" })
        if ($bus -notin 'USB', '7') { $diskList += "$type $size ГБ" }
    }
} else {
    foreach ($d in Get-CimInstance Win32_DiskDrive) {
        $size = [math]::Round($d.Size / 1GB)
        Line "Диск $($d.Index)" ("{0} | {1} ГБ | {2}" -f $d.Model, $size, $d.InterfaceType)
        $diskList += "$($d.Model) $size ГБ"
    }
}
foreach ($ld in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
    $f = [math]::Round($ld.FreeSpace / 1GB, 1); $s = [math]::Round($ld.Size / 1GB)
    $p = if ($ld.Size) { [math]::Round($ld.FreeSpace / $ld.Size * 100) } else { 0 }
    $isSys = $ld.DeviceID -eq $env:SystemDrive
    $st = if ($f -lt 10 -or $p -lt 10) { 'bad' } elseif ($f -lt 25 -or $p -lt 20) { 'warn' } else { 'ok' }
    $iss = $null; if ($isSys -and $st -eq 'bad') { $iss = "Мало места на $($ld.DeviceID): $f ГБ" }
    Line "Том $($ld.DeviceID)$(if ($isSys) { ' (система)' })" ("свободно $f из $s ГБ ($p%)") $st $iss
    if ($isSys) { $Report['C: свободно ГБ'] = $f }
}
$Report['Диски'] = $diskList -join ' + '

# ================= периферия =================
Section 'Мониторы и периферия'
$monNames = @(); $i = 0
foreach ($m in Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID) {
    $i++
    $name = ConvertFrom-WmiString $m.UserFriendlyName; $mfr = ConvertFrom-WmiString $m.ManufacturerName; $sn = ConvertFrom-WmiString $m.SerialNumberID
    if (-not $name) { $name = '(встроенный / без имени)' }
    $disp = if ($mfr -and $name -like "$mfr*") { $name } else { "$mfr $name".Trim() }
    Line "Монитор $i" ("{0} | S/N {1} | {2} г." -f $disp, (Hide $sn), $m.YearOfManufacture)
    $monNames += $disp
}
if (-not $i) { Line 'Мониторы' 'не определены' }
$Report['Мониторы'] = $monNames -join ', '

$skip = 'Microsoft Print to PDF|XPS|OneNote|Fax|Факс|PDF|Send To|AnyDesk|Snagit'
$prn  = @(Get-CimInstance Win32_Printer | Where-Object { $_.Name -notmatch $skip })
foreach ($p in $prn) {
    $how = if ($p.Network) { 'сетевой (через сервер)' }
    elseif ($p.PortName -match '^USB') { 'USB' }
    elseif ($p.PortName -match '^WSD') { 'WSD (по сети)' }
    elseif ($p.PortName -match '\d+\.\d+\.\d+\.\d+|^IP_') { "TCP/IP $(if (-not $IsPersonal) { $p.PortName })".Trim() }
    elseif ($IsPersonal) { 'другой порт' }
    else { $p.PortName }
    Line 'Принтер / МФУ' ("{0} | {1}{2}" -f $p.Name, $how, $(if ($p.Default) { ' | по умолчанию' }))
}
if (-not $prn.Count) { Line 'Принтер / МФУ' 'нет' }
$Report['Принтеры'] = ($prn | ForEach-Object Name) -join ', '

$bat    = @(Get-CimInstance Win32_Battery)
$upsPnp = @(Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'UPS|ИБП|APC|Ippon|Powercom|Eaton|CyberPower' })
if ($IsLaptop) {
    if ($bat.Count) {
        $des  = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
        $wear = $null; if ($des -and $full) { $wear = [math]::Round($full / $des * 100) }
        if (-not $wear -and -not $IsAdmin) { $Incomplete.Add('износ батареи') }
        $wSt  = if ($wear -and $wear -lt 60) { 'warn' } else { 'ok' }
        Line 'Батарея' ("заряд {0}%{1}" -f $bat[0].EstimatedChargeRemaining, $(if ($wear) { ", ёмкость $wear% от заводской" })) $wSt
        $Report['ИБП/батарея'] = $(if ($wear) { "батарея $wear%" } else { 'батарея' })
    }
    if ($upsPnp.Count) { Line 'ИБП' $upsPnp[0].FriendlyName 'ok' }
} else {
    if ($bat.Count)        { Line 'ИБП' ("{0} | заряд {1}%" -f $bat[0].Name, $bat[0].EstimatedChargeRemaining) 'ok'; $Report['ИБП/батарея'] = $bat[0].Name }
    elseif ($upsPnp.Count) { Line 'ИБП' $upsPnp[0].FriendlyName 'ok'; $Report['ИБП/батарея'] = $upsPnp[0].FriendlyName }
    else                   { Line 'ИБП' 'не обнаружен (или подключён без USB-кабеля)' 'warn'; $Report['ИБП/батарея'] = 'нет' }
}

# ================= Windows и обновления =================
Section 'Windows и обновления'
$cv      = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build   = [int]$cv.CurrentBuild; $ubr = [int]$cv.UBR
$ver     = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
$edition = $cv.EditionID
$osName  = ($os.Caption -replace '^(Майкрософт|Microsoft)\s+', '').Trim()
$isLtsc  = $edition -match 'EnterpriseS|LTSC'
$isEnt   = $edition -match 'Enterprise|Education|IoT'
Line 'Версия'   "$osName ($ver)"
Line 'Сборка'   "$build.$ubr"
Line 'Редакция' $edition
$Report['Windows'] = "$osName $ver"
$Report['Сборка']  = "$build.$ubr"

if ($Life.ContainsKey($build)) {
    $l = $Life[$build]
    $endStr = if ($isLtsc -and $l[3]) { $l[3] } elseif ($isEnt) { $l[2] } else { $l[1] }
    $end  = [datetime]::ParseExact($endStr, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $left = ($end - (Get-Date)).Days
    $Report['Поддержка до'] = $end.ToString('yyyy-MM-dd')
    if ($left -lt 0) {
        $advice = if ($build -lt 22000) { 'нужен переход на Windows 11 (смотри TPM ниже)' } else { "обновить до $LatestWin11 через Центр обновления" }
        Line 'Поддержка Microsoft' ("ЗАКОНЧИЛАСЬ {0:dd.MM.yyyy} — {1}" -f $end, $advice) 'bad' "Windows $ver без поддержки с $($end.ToString('dd.MM.yyyy'))"
    } elseif ($left -lt 120) {
        Line 'Поддержка Microsoft' ("до {0:dd.MM.yyyy} (осталось {1} дн.) — пора планировать обновление" -f $end, $left) 'warn'
    } else {
        Line 'Поддержка Microsoft' ("до {0:dd.MM.yyyy} — версия актуальна" -f $end) 'ok'
    }
} elseif ($build -gt $LifeMaxBuild) {
    Line 'Поддержка Microsoft' 'сборка новее таблицы в скрипте — скорее всего, актуальная' 'ok'
} else {
    Line 'Поддержка Microsoft' 'старая версия, не поддерживается' 'bad' "Устаревшая Windows (сборка $build)"
}

$tpm = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm
$tpmVer = if ($tpm) { ("$($tpm.SpecVersion)" -split ',')[0].Trim() } else { $null }
if (-not $IsAdmin) { $Incomplete.Add('TPM') }
$sb = $null; try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch {}
Line 'TPM' $(if ($tpmVer) { "есть, версия $tpmVer" } elseif ($IsAdmin) { 'не найден' } else { 'нет данных (нужны права админа)' }) $(if ($tpmVer -like '2*') { 'ok' } elseif ($IsAdmin) { 'warn' })
Line 'Secure Boot' $(if ($sb -eq $true) { 'включён' } elseif ($sb -eq $false) { 'выключен' } else { 'нет данных / Legacy BIOS' }) $(if ($sb -eq $true) { 'ok' } else { 'warn' })

$wuSvc = Get-Service wuauserv
if ("$($wuSvc.StartType)" -eq 'Disabled') { Line 'Служба обновлений' 'ОТКЛЮЧЕНА' 'bad' 'Служба Центра обновления отключена' }

# последнее установленное обновление: история WU + Get-HotFix, берём самое свежее
$lastDate = $null; $lastTitle = $null; $Searcher = $null
try {
    $Session  = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $cnt = $Searcher.GetTotalHistoryCount()
    if ($cnt -gt 0) {
        $hist = foreach ($e in $Searcher.QueryHistory(0, [math]::Min($cnt, 200))) {
            if ($e.Operation -eq 1 -and $e.ResultCode -in 2, 3 -and $e.Title -notmatch 'Defender|^[0-9A-Z]{12}-') { $e }
        }
        $top = $hist | Sort-Object Date -Descending | Select-Object -First 1
        if ($top) { $lastDate = $top.Date.ToLocalTime(); $lastTitle = $top.Title }
    }
} catch {}
$hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
if ($hf -and (-not $lastDate -or $hf.InstalledOn -gt $lastDate)) { $lastDate = $hf.InstalledOn; $lastTitle = "$($hf.HotFixID) ($($hf.Description))" }
if ($lastDate) {
    $days = ((Get-Date) - $lastDate).Days
    $st = if ($days -gt 70) { 'bad' } elseif ($days -gt 40) { 'warn' } else { 'ok' }
    Line 'Последнее обновление' ("{0:dd.MM.yyyy} ({1} дн. назад)" -f $lastDate, $days) $st $(if ($st -eq 'bad') { "Обновления не ставились $days дн. — проверить Центр обновления" })
    if ($lastTitle) { Line '' $lastTitle }
    $Report['Последнее обновление'] = $lastDate.ToString('yyyy-MM-dd')
} else { Line 'Последнее обновление' 'не удалось определить' 'warn' }

if (-not $SkipWU) {
    Write-Host '  ...спрашиваю Центр обновления, это до 1–2 минут' -ForegroundColor DarkGray
    try {
        if (-not $Searcher) { $Session = New-Object -ComObject Microsoft.Update.Session; $Searcher = $Session.CreateUpdateSearcher() }
        $res  = $Searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $pend = @(foreach ($u in $res.Updates) { if ($u.Title -notmatch 'Defender') { $u } })
        if ($pend.Count -eq 0) {
            Line 'Доступные обновления' 'нет — система актуальна' 'ok'
        } else {
            $cu = @($pend | Where-Object { $_.Title -match 'Cumulative|Накопительн' })
            $st = if ($cu.Count) { 'bad' } else { 'warn' }
            Line 'Доступные обновления' ("можно обновить: {0} шт.{1}" -f $pend.Count, $(if ($cu.Count) { ', есть накопительное' })) $st $(if ($cu.Count) { 'Не установлено накопительное обновление Windows' })
            foreach ($u in ($pend | Select-Object -First 6)) { Line '' ('• ' + $u.Title) }
        }
        $Report['Ожидают обновлений'] = $pend.Count
    } catch {
        Line 'Доступные обновления' "Центр обновления не ответил: $($_.Exception.Message)" 'warn'
        $Report['Ожидают обновлений'] = '?'
    }
} else { $Report['Ожидают обновлений'] = 'не проверялось' }

$needReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
              (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
if ($needReboot) { Line 'Перезагрузка' 'ТРЕБУЕТСЯ для завершения обновлений' 'warn' 'Ждёт перезагрузки после обновлений' }

# ================= антивирус =================
Section 'Антивирус'
$av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct | Group-Object displayName | ForEach-Object {
    $_.Group | Sort-Object { ('{0:X6}' -f [int]$_.productState).Substring(2, 2) -in '10', '11' } -Descending | Select-Object -First 1
})
if (-not $av.Count) { Line 'Антивирус' 'Центр безопасности ничего не вернул (серверная ОС?)' 'warn' }
$expAv = $null; $activeAv = @()
foreach ($a in $av) {
    $hex = '{0:X6}' -f [int]$a.productState
    $on  = $hex.Substring(2, 2) -in '10', '11'
    $upd = $hex.Substring(4, 2) -eq '00'
    if ($on) {
        $activeAv += $a.displayName
        Line $a.displayName ("включён, базы {0}" -f $(if ($upd) { 'актуальны' } else { 'УСТАРЕЛИ' })) $(if ($upd) { 'ok' } else { 'warn' })
        if (-not $ExpectedAv -and -not $upd) { $Issues.Add("$($a.displayName): базы устарели") }
    } else {
        Line $a.displayName 'выключен'
    }
    if ($ExpectedAv -and $a.displayName -match [regex]::Escape($ExpectedAv)) { $expAv = [pscustomobject]@{ Name = $a.displayName; On = $on; Upd = $upd } }
}
if ($ExpectedAv) {
    $avRx  = [regex]::Escape($ExpectedAv)
    $avSvc = @(Get-Service | Where-Object { $_.DisplayName -match $avRx -or ($ExpectedAv -match 'Kaspersky' -and $_.Name -match '^AVP') })
    if ($avSvc.Count) {
        $running = @($avSvc | Where-Object { "$($_.Status)" -eq 'Running' }).Count
        Line "Служба $ExpectedAv" (($avSvc | ForEach-Object { "$($_.Name): $($_.Status)" }) -join ', ') $(if ($running) { 'ok' } else { 'bad' })
    }
    if ($expAv) {
        if (-not $expAv.On)      { $Issues.Add("$($expAv.Name) установлен, но защита выключена") }
        elseif (-not $expAv.Upd) { $Issues.Add("$($expAv.Name): базы устарели") }
        $Report['Антивирус'] = "$($expAv.Name) | $(if ($expAv.On) { 'вкл' } else { 'ВЫКЛ' }) | базы $(if ($expAv.Upd) { 'ок' } else { 'УСТАРЕЛИ' })"
    } else {
        Line $ExpectedAv 'не найден' 'bad' "$ExpectedAv не установлен"
        $Report['Антивирус'] = "$ExpectedAv нет; активен: $($activeAv -join ', ')"
    }
} else {
    if ($av.Count -and -not $activeAv.Count) { Line 'Активный антивирус' 'нет' 'bad' 'Нет включённого антивируса' }
    $Report['Антивирус'] = $(if ($activeAv.Count) { "активен: $($activeAv -join ', ')" } else { 'нет активного' })
}

# ================= локальные админы =================
Section 'Локальные администраторы'
$admMembers = @(); $admDomUsers = @()
try {
    $admObjs     = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    $admMembers  = @($admObjs | ForEach-Object { $_.Name })
    $admDomUsers = @($admObjs | Where-Object { "$($_.ObjectClass)" -match 'User|Пользователь' -and "$($_.PrincipalSource)" -eq 'ActiveDirectory' } | ForEach-Object { $_.Name })
} catch {
    try {
        $gName = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        $g = [ADSI]"WinNT://$env:COMPUTERNAME/$gName,group"
        $admMembers = @($g.psbase.Invoke('Members') | ForEach-Object {
            ($_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null)) -replace '^WinNT://', '' -replace '/', '\'
        })
    } catch {}
}
if ($IsPersonal) { Line 'Состав группы' "учёток: $($admMembers.Count) (имена скрыты)" }
else             { Line 'Состав группы' ($admMembers -join ', ') }
if ($admDomUsers.Count -and $IsPersonal) {
    Line 'Доменные учётки в админах' "$($admDomUsers.Count) шт. (имена скрыты)" 'warn' "Локальный админ выдан доменной учётке напрямую ($($admDomUsers.Count) шт.)"
} elseif ($admDomUsers.Count) {
    Line 'Доменные учётки в админах' ($admDomUsers -join ', ') 'warn' "Локальный админ выдан доменной учётке напрямую: $($admDomUsers -join ', ')"
}

$user = $cs.UserName; $userAdmin = $null
if ($user) {
    if ($Me.Name -ieq $user) {
        $userAdmin = [bool]((whoami /groups) -match 'S-1-5-32-544'); $method = 'по токену, с учётом вложенных групп'
    } else {
        $userAdmin = $admMembers -contains $user; $method = 'по прямому членству, вложенные группы не проверены'
    }
    $uName = if ($IsPersonal) { 'текущий пользователь' } else { $user }
    if ($userAdmin) { Line 'Пользователь — админ?' "ДА, $uName ($method)" 'bad' "Пользователь $uName — локальный администратор" }
    else            { Line 'Пользователь — админ?' "нет ($method)" 'ok' }
} else { Line 'Пользователь — админ?' 'в системе никто не залогинен' }
$Report['Польз. админ'] = $(if ($userAdmin) { 'ДА' } elseif ($userAdmin -eq $false) { 'нет' } else { '?' })

$builtin = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' }
if ($builtin) { Line 'Встроенный Administrator' $(if ($builtin.Enabled) { 'включён' } else { 'отключён' }) $(if ($builtin.Enabled) { 'warn' } else { 'ok' }) }

# ================= домен и VPN =================
Section 'Домен и VPN'
$dcOk = @($DCs | Where-Object { Test-Port $_ 389 })
# без конфига «свой» домен — любой домен, в который введена машина
$inCorp = if ($CorpDomain) { $cs.PartOfDomain -and ($cs.Domain -ieq $CorpDomain) } else { [bool]$cs.PartOfDomain }

if ($inCorp) {
    Line 'Домен' "в домене $(Hide $cs.Domain)" $(if ($CorpDomain) { 'ok' })
    if (-not $DCs.Count)      { Line 'Доверие с доменом' 'не проверено — в конфиге не заданы контроллеры (dcs)' }
    elseif (-not $dcOk.Count) { Line 'Доверие с доменом' 'не проверено — DC недоступны' }
    elseif (-not $IsAdmin)    { Line 'Доверие с доменом' 'не проверено (нужны права админа)'; $Incomplete.Add('доверие с доменом') }
    else {
        $sc = $null; try { $sc = Test-ComputerSecureChannel -ErrorAction Stop } catch {}
        if ($sc -eq $true)      { Line 'Доверие с доменом' 'в порядке' 'ok' }
        elseif ($sc -eq $false) { Line 'Доверие с доменом' 'НАРУШЕНО' 'bad' 'Нарушены доверительные отношения с доменом' }
    }
} elseif ($cs.PartOfDomain) { Line 'Домен' "в ДРУГОМ домене: $(Hide $cs.Domain)" 'warn' 'Компьютер в чужом домене' }
else                        { Line 'Домен' "не в домене (рабочая группа $(Hide $cs.Domain))" $(if ($CorpDomain) { 'warn' }) }

$uDom = if ($user) { ($user -split '\\')[0] } else { '' }
$acc  = if (-not $user) { '—' } elseif ($uDom -ieq $env:COMPUTERNAME) { 'локальная' } elseif ($uDom -eq 'AzureAD') { 'Microsoft Entra' }
        elseif ($IsPersonal) { 'доменная' } else { "доменная ($uDom)" }
Line 'Учётка пользователя' $acc

$ovpnExe = @("$env:ProgramFiles\OpenVPN\bin\openvpn.exe", "${env:ProgramFiles(x86)}\OpenVPN\bin\openvpn.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$connectExe = Test-Path "$env:ProgramFiles\OpenVPN Connect\OpenVPNConnect.exe"
$ovpnVer = $null
if ($ovpnExe) {
    $vl = "$(& $ovpnExe --version 2>&1 | Select-Object -First 1)"
    if ($vl -match 'OpenVPN (\d+\.\d+\.\d+)') { $ovpnVer = [version]$Matches[1] }
    $st = if ($ovpnVer -and $ovpnVer -lt $MinOvpn) { 'warn' } else { 'ok' }
    Line 'OpenVPN GUI' ("установлен, версия {0}" -f $(if ($ovpnVer) { $ovpnVer } else { '?' })) $st $(if ($st -eq 'warn') { "Старый OpenVPN $ovpnVer — обновить до $MinOvpn+" })
    $Report['OpenVPN'] = "$ovpnVer"
} elseif ($connectExe) {
    Line 'OpenVPN' 'стоит OpenVPN Connect, а не GUI' 'warn'; $Report['OpenVPN'] = 'Connect'
} else {
    Line 'OpenVPN' 'не установлен'; $Report['OpenVPN'] = 'нет'
}

$cfgDirs  = @("$env:ProgramFiles\OpenVPN\config", "$env:ProgramFiles\OpenVPN\config-auto")
$cfgDirs += Get-ChildItem 'C:\Users' -Directory | ForEach-Object { Join-Path $_.FullName 'OpenVPN\config' }
$cfgs = @($cfgDirs | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Recurse -File -Include *.ovpn, *.conf })
if (-not $IsAdmin) { $Incomplete.Add('VPN-ключи других пользователей') }
foreach ($f in $cfgs) {
    $txt      = Get-Content $f.FullName -Raw
    $remotes  = ([regex]::Matches($txt, '(?m)^\s*remote\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ', '
    $hasRoute = $ExtraRouteIp -and ($txt -match [regex]::Escape($ExtraRouteIp))
    $keyOwner    = if ($f.FullName -match '\\Users\\([^\\]+)\\') { $Matches[1] } else { 'общий' }
    $foreign  = $null
    if ($KeyPattern -and $keyOwner -ne 'общий' -and $f.BaseName -match $KeyPattern -and $Matches[1]) {
        $keyUser = $Matches[1].Trim()
        if (-not ($keyOwner -like "$keyUser*" -or $keyUser -like "$keyOwner*")) { $foreign = $keyUser }
    }
    $kSt = if ($foreign) { 'warn' } else { $null }
    if ($IsPersonal) {
        $where = if ($keyOwner -eq 'общий') { 'общий' } else { 'в профиле пользователя' }
        Line 'Ключ VPN' ("{0} (имя и сервер скрыты){1}{2}" -f $where, $(if ($hasRoute) { " | маршрут до $ExtraRouteIp есть" }), $(if ($foreign) { ' | ЧУЖОЙ КЛЮЧ' })) $kSt $(if ($foreign) { 'Чужой VPN-ключ в профиле пользователя' })
    } else {
        Line "Ключ ($keyOwner)" ("{0} → {1}{2}{3}" -f $f.Name, $remotes, $(if ($hasRoute) { " | маршрут до $ExtraRouteIp есть" }), $(if ($foreign) { " | ЧУЖОЙ КЛЮЧ ($foreign)" })) $kSt $(if ($foreign) { "Чужой VPN-ключ у $keyOwner`: $($f.Name)" })
    }
}
if (-not $cfgs.Count -and ($ovpnExe -or $connectExe)) { Line 'Ключи .ovpn' 'не найдены' 'warn' }

if ($VpnPrefix) {
    $tun = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "$VpnPrefix*" } | Select-Object -First 1
    Line 'VPN-туннель сейчас' $(if ($tun) { "поднят, адрес $(Hide $tun.IPAddress)" } else { 'не поднят' }) $(if ($tun) { 'ok' })
} else {
    $vpnIf = @(Get-NetAdapter | Where-Object { "$($_.Status)" -eq 'Up' -and $_.InterfaceDescription -match 'TAP-Windows|Wintun|OpenVPN|WireGuard|Data Channel Offload' })
    foreach ($a in $vpnIf) {
        $ip = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 | ForEach-Object { $_.IPAddress }) -join ', '
        Line 'VPN-адаптер поднят' ("{0}: {1}" -f $a.InterfaceDescription, (Hide $ip))
    }
    if (-not $vpnIf.Count) { Line 'VPN-туннель сейчас' 'не поднят (активных VPN-адаптеров нет)' }
}
if ($DCs.Count) {
    Line 'Контроллеры домена' $(if ($dcOk.Count) { "доступны: $($dcOk -join ', ')" } else { 'недоступны (порт 389)' }) $(if ($dcOk.Count) { 'ok' } else { 'warn' })
} elseif ($cs.PartOfDomain -and $env:LOGONSERVER -and -not $IsPersonal) {
    Line 'Сервер входа' ($env:LOGONSERVER -replace '^\\\\', '')
}

$hasVpn = [bool]($ovpnExe -or $connectExe) -and $cfgs.Count -gt 0
$mi = $null
if ($inCorp -and $hasVpn) { $mode = 'в домене + OpenVPN-ключ'; $ms = 'ok' }
elseif ($inCorp)          { $mode = 'в домене, без VPN (офис)'; $ms = 'ok' }
elseif ($hasVpn)          { $mode = 'НЕ в домене, только OpenVPN-ключ'; $ms = 'warn'; $mi = 'Не введён в домен, работает только по VPN-ключу' }
else                      { $mode = 'ни домена, ни VPN'; $ms = 'bad'; $mi = 'Не в домене и без VPN' }
# без конфига ожидаемого режима нет — просто показываем факт
if ($CorpDomain) { Line 'Итог' $mode $ms $mi } else { Line 'Итог' $mode }
$Report['Домен/VPN'] = $mode

# ================= итог =================
Section 'Итог'
if ($Issues.Count) {
    Write-Host "  Замечаний: $($Issues.Count)" -ForegroundColor Yellow
    $Issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
} else {
    Write-Host '  Замечаний нет' -ForegroundColor Green
}
if ($Incomplete.Count) {
    Write-Host "  Неполные проверки (нет прав администратора): $($Incomplete -join ', ')" -ForegroundColor DarkYellow
}
$Report['Замечания'] = $Issues -join '; '

if ($CsvPath) {
    try {
        [pscustomobject]$Report | Export-Csv -Path $CsvPath -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';' -Force -ErrorAction Stop
        Write-Host "`n  Строка добавлена в $(if ($IsPersonal) { Split-Path $CsvPath -Leaf } else { $CsvPath })" -ForegroundColor DarkGray
    } catch {
        Write-Host "`n  Не удалось записать CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}
if ($JsonPath) {
    try {
        $full = [ordered]@{
            version    = $ScriptVersion
            os         = 'windows'
            owner      = $Owner
            generated  = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            isAdmin    = [bool]$IsAdmin
            configUsed = [bool]$Cfg
            summary    = $Report
            issues     = $Issues.ToArray()
            incomplete = $Incomplete.ToArray()
            details    = $Details.ToArray()
        }
        $jp = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
        [IO.File]::WriteAllText($jp, ($full | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
        Write-Host "  Отчёт сохранён в $(if ($IsPersonal) { Split-Path $JsonPath -Leaf } else { $JsonPath })" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Не удалось записать JSON: $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host ''
