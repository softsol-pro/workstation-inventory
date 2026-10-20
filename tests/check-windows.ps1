<#
  check-windows.ps1 — проверка достоверности windows\inventory.ps1 на этом ПК.
  Запускает инвентаризацию в режимах «компании», «личный», без консоли и через scriptblock
  и сверяет результат с независимыми источниками (реестр, ver, Get-Disk, Get-PSDrive, Get-HotFix).
  В системе ничего не меняет, временные файлы удаляет.

    powershell -ExecutionPolicy Bypass -File tests\check-windows.ps1
#>
param([string]$Script = (Join-Path $PSScriptRoot '..\windows\inventory.ps1'))

$Script = (Resolve-Path $Script).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('inv-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$fails = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "  OK    $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL  $Name — $Detail" -ForegroundColor Red; $script:fails++ }
}
function Invoke-Inventory([string[]]$Arguments) {
    (& powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String)
}
function Read-Report([string]$Path) { Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Test-Word([string]$Text, [string]$Word) {
    [regex]::IsMatch($Text, '(?<![\w])' + [regex]::Escape($Word) + '(?![\w])', 'IgnoreCase')
}

Write-Host "`nПроверка $Script" -ForegroundColor Cyan

# ---------- разбор вывода Kaspersky avp.com на сохранённых примерах (работает и без Kaspersky) ----------
Write-Host "`nРазбор вывода avp.com (tests\fixtures)" -ForegroundColor White
$ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
foreach ($fn in 'ConvertFrom-AvpStatus', 'ConvertFrom-AvpUpdater') {
    $def = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $fn }, $true) | Select-Object -First 1
    if ($def) { . ([scriptblock]::Create($def.Extent.Text)) } else { Check "функция $fn есть в скрипте" $false 'не найдена' }
}
$fx = Join-Path $PSScriptRoot 'fixtures'
function Read-Fixture([string]$Name) { @([IO.File]::ReadAllLines((Join-Path $fx $Name), [Text.Encoding]::UTF8)) }
$st = ConvertFrom-AvpStatus (Read-Fixture 'avp-status.txt')
Check 'STATUS: постоянная защита файлов — running' ($st['File_Monitoring'] -eq 'running') "File_Monitoring = $($st['File_Monitoring'])"
Check 'STATUS: брандмауэр и почта разобраны' ($st['Firewall'] -eq 'running' -and $st['Mail_Monitoring'] -eq 'running') "Firewall = $($st['Firewall']), Mail = $($st['Mail_Monitoring'])"
Check 'STATUS: задач больше 30' ($st.Count -gt 30) "задач: $($st.Count)"
$st = ConvertFrom-AvpStatus (Read-Fixture 'avp-status-off.txt')
Check 'STATUS: выключенная защита распознаётся' ($st['File_Monitoring'] -eq 'stopped') "File_Monitoring = $($st['File_Monitoring'])"
$uo = ConvertFrom-AvpUpdater (Read-Fixture 'avp-updater.txt')
Check 'Updater: время и успех' ($uo.Ok -eq $true -and $uo.Finish -eq [datetime]'2026-10-20 12:48:58') "Ok = $($uo.Ok), Finish = $($uo.Finish)"
$uo = ConvertFrom-AvpUpdater (Read-Fixture 'avp-updater-failed.txt')
Check 'Updater: ошибка обновления распознаётся' ($uo.Ok -eq $false) "Ok = $($uo.Ok)"
$uo = ConvertFrom-AvpUpdater @()
Check 'Updater: пустой вывод — нет данных, а не «успешно»' ($null -eq $uo.Ok -and $null -eq $uo.Finish) "Ok = $($uo.Ok)"

# ---------- компьютер компании: сверка с независимыми источниками ----------
Write-Host "`nРежим «компании»" -ForegroundColor White
$cj = Join-Path $tmp 'company.json'
$null = Invoke-Inventory @('-Owner', 'company', '-SkipWU', '-JsonPath', $cj, '-CsvPath', (Join-Path $tmp 'company.csv'))
Check 'JSON-отчёт записан' (Test-Path $cj) 'файла нет'
if (Test-Path $cj) {
    $c = Read-Report $cj; $s = $c.summary
    Check 'owner = company' ($c.owner -eq 'company') "owner = $($c.owner)"
    Check 'имя ПК' ($s.'ПК' -eq $env:COMPUTERNAME) "в отчёте «$($s.'ПК')», в системе «$env:COMPUTERNAME»"

    $cpuReg = ("$((Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0').ProcessorNameString)" -replace '\s+', ' ').Trim()
    Check 'процессор совпадает с реестром' ($s.CPU -eq $cpuReg) "в отчёте «$($s.CPU)», в реестре «$cpuReg»"

    $visGB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
    $ram = [double]$s.'ОЗУ ГБ'
    Check 'объём ОЗУ близок к видимому системе' ($ram -ge [math]::Floor($visGB) -and $ram -le [math]::Ceiling($visGB) + 2) ("в отчёте {0} ГБ, видно системе {1:N1} ГБ" -f $ram, $visGB)

    $verBuild = $null
    if ("$(cmd /c ver)" -match '\d+\.\d+\.(\d+)\.(\d+)') { $verBuild = "$($Matches[1]).$($Matches[2])" }
    Check 'сборка Windows совпадает с ver' ($s.'Сборка' -eq $verBuild) "в отчёте «$($s.'Сборка')», ver «$verBuild»"

    $sysFree = (Get-PSDrive $env:SystemDrive.TrimEnd(':')).Free / 1GB
    Check 'свободно на системном томе' ([math]::Abs([double]$s.'C: свободно ГБ' - $sysFree) -le 2) ("в отчёте {0} ГБ, Get-PSDrive {1:N1} ГБ" -f $s.'C: свободно ГБ', $sysFree)

    $repDisks = @($c.details | Where-Object { $_.Section -eq 'Диски' -and $_.Name -like 'Диск *' }).Count
    $sysDisks = @(Get-Disk).Count
    Check 'число физических дисков' ($repDisks -eq $sysDisks) "в отчёте $repDisks, Get-Disk $sysDisks"

    $hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf -and $s.'Последнее обновление') {
        Check 'последнее обновление не раньше последнего KB' ([datetime]$s.'Последнее обновление' -ge $hf.InstalledOn.Date) "в отчёте $($s.'Последнее обновление'), Get-HotFix $($hf.InstalledOn.ToString('yyyy-MM-dd'))"
    }
    # серийники дисков — сверка с Get-Disk (другой интерфейс, чем Get-PhysicalDisk в скрипте)
    foreach ($gd in @(Get-Disk)) {
        $gsn = "$($gd.SerialNumber)".Trim().TrimEnd('.').Trim()
        if ($gsn.Length -lt 4 -or $gsn -match '^0+$') { continue }
        $row = $c.details | Where-Object { $_.Section -eq 'Диски' -and $_.Name -eq "Диск $($gd.Number)" } | Select-Object -First 1
        Check "серийник диска $($gd.Number) совпадает с Get-Disk" ("$($row.Value)".Contains($gsn)) "в отчёте «$($row.Value)», Get-Disk «$gsn»"
    }
    $kb = @($c.details | Where-Object { $_.Name -in 'Клавиатура', 'Мышь / тачпад' })
    Check 'раздел клавиатуры и мыши есть' ($kb.Count -ge 2) "строк: $($kb.Count)"
    # если Windows видит USB-клавиатуру, отчёт не должен говорить «не найдена»
    $usbKb = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass = 'Keyboard'" | Where-Object { "$($_.DeviceID)" -match 'VID_[0-9A-F]{4}' -and "$($_.Name)" -notmatch 'Virtual|Hyper-V|Terminal Server' })
    if ($usbKb.Count) {
        $kbRow = $kb | Where-Object { $_.Name -eq 'Клавиатура' } | Select-Object -First 1
        Check 'USB-клавиатура из Win32_PnPEntity попала в отчёт' ("$($kbRow.Value)" -ne 'не найдена') "USB-клавиатур: $($usbKb.Count), в отчёте «$($kbRow.Value)»"
    }
    foreach ($r in $kb) { Write-Host "        $($r.Name): $($r.Value)" -ForegroundColor DarkGray }
    # Kaspersky на этом ПК: сверка с avp.com напрямую и со службой
    $kSvcChk = Get-CimInstance Win32_Service -Filter "Name LIKE 'AVP%' AND State = 'Running'" | Select-Object -First 1
    if ($kSvcChk) {
        $kRow = $c.details | Where-Object { $_.Name -eq 'Постоянная защита файлов' } | Select-Object -First 1
        Check 'Kaspersky: строка о постоянной защите есть' ([bool]$kRow) 'нет строки'
        $uRow = $c.details | Where-Object { $_.Name -eq 'Последнее обновление баз' } | Select-Object -First 1
        Check 'Kaspersky: строка об обновлении баз есть' ($uRow -and "$($uRow.Value)" -ne 'нет данных') "«$($uRow.Value)»"
        Write-Host ("        {0}: {1}`n        {2}: {3}" -f $kRow.Name, $kRow.Value, $uRow.Name, $uRow.Value) -ForegroundColor DarkGray
    }
    Check 'в отчёте больше 20 строк' (@($c.details).Count -gt 20) "строк: $(@($c.details).Count)"
    Write-Host ("        права администратора: {0}; неполные проверки: {1}" -f $c.isAdmin, $(if ($c.incomplete) { $c.incomplete -join ', ' } else { 'нет' })) -ForegroundColor DarkGray
}

# ---------- личный ПК: ничего идентифицирующего ----------
Write-Host "`nРежим «личный»" -ForegroundColor White
$pj = Join-Path $tmp 'personal.json'; $pc = Join-Path $tmp 'personal.csv'
$pOut = Invoke-Inventory @('-Owner', 'personal', '-SkipWU', '-JsonPath', $pj, '-CsvPath', $pc)
Check 'JSON и CSV записаны' ((Test-Path $pj) -and (Test-Path $pc)) 'файлов нет'
if (Test-Path $pj) {
    $p = Read-Report $pj
    Check 'owner = personal' ($p.owner -eq 'personal') "owner = $($p.owner)"
    Check 'имя ПК в сводке скрыто' ($p.summary.'ПК' -like 'скрыто*') "ПК = $($p.summary.'ПК')"
    $all = $pOut + (Get-Content $pj -Raw -Encoding UTF8) + (Get-Content $pc -Raw -Encoding UTF8)
    $cs = Get-CimInstance Win32_ComputerSystem
    $secrets = @($env:COMPUTERNAME, $env:USERNAME, "$($cs.UserName)".Split('\')[-1], "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim())
    if ($cs.PartOfDomain) { $secrets += $cs.Domain, $env:USERDOMAIN }
    $secrets += @(Get-PhysicalDisk | ForEach-Object { "$($_.SerialNumber)".Trim().TrimEnd('.') })
    $secrets += "$((Get-CimInstance Win32_BaseBoard | Select-Object -First 1).SerialNumber)".Trim()
    $secrets += @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | ForEach-Object { (($_.SerialNumberID | Where-Object { $_ }) | ForEach-Object { [char]$_ }) -join '' })
    $secrets += @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { "$($_.SerialNumber)".Trim() })
    $secrets = $secrets | Where-Object { "$_".Trim().Length -ge 4 -and $_ -notmatch '^(0+|To be filled.*|Default string|System Serial Number|None|Not Specified)$' } | Sort-Object -Unique
    foreach ($x in $secrets) { Check "нигде нет «$x»" (-not (Test-Word $all $x)) 'найдено в выводе, CSV или JSON' }
}

# ---------- CSV от старой версии: строка должна уйти в -v2.csv ----------
Write-Host "`nCSV с колонками от старой версии" -ForegroundColor White
$old = Join-Path $tmp 'old.csv'
[IO.File]::WriteAllText($old, "`"Дата`";`"ПК`"`r`n`"x`";`"y`"`r`n", (New-Object Text.UTF8Encoding $true))
$null = Invoke-Inventory @('-Owner', 'company', '-SkipWU', '-CsvPath', $old)
$v2 = Join-Path $tmp 'old-v2.csv'
Check 'старый файл не тронут' (@(Get-Content $old).Count -eq 2) "строк: $(@(Get-Content $old).Count)"
Check 'строка записана в old-v2.csv с новыми колонками' ((Test-Path $v2) -and "$(Get-Content $v2 -TotalCount 1 -Encoding UTF8)" -like '*"Клавиатура и мышь"') 'old-v2.csv нет или заголовок другой'
$null = Invoke-Inventory @('-Owner', 'company', '-SkipWU', '-CsvPath', $old)
Check 'повторный запуск дописывает в тот же old-v2.csv' ((Test-Path $v2) -and @(Get-Content $v2).Count -eq 3 -and -not (Test-Path (Join-Path $tmp 'old-v3.csv'))) "строк в old-v2: $(@(Get-Content $v2).Count)"

# ---------- без консоли и без -Owner ----------
Write-Host "`nБез консоли и без -Owner" -ForegroundColor White
$nj = Join-Path $tmp 'nonint.json'
$null = Invoke-Inventory @('-SkipWU', '-JsonPath', $nj)
if (Test-Path $nj) { $n = Read-Report $nj; Check 'считается личным ПК' ($n.owner -eq 'personal') "owner = $($n.owner)" }
else { Check 'считается личным ПК' $false 'JSON не записан (скрипт мог зависнуть на вопросе)' }

# ---------- запуск как однострочник (scriptblock) ----------
Write-Host "`nЗапуск через scriptblock" -ForegroundColor White
$code = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Script)).TrimStart([char]0xFEFF)
$sj = Join-Path $tmp 'sb.json'
$null = & ([scriptblock]::Create($code)) -Owner company -SkipWU -JsonPath $sj 6>&1
Check 'отчёт записан' (Test-Path $sj) 'JSON не записан'

Remove-Item $tmp -Recurse -Force
if ($fails) { Write-Host "`nНе пройдено проверок: $fails" -ForegroundColor Red; exit 1 }
Write-Host "`nВсе проверки пройдены" -ForegroundColor Green
