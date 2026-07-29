param(
    [string]$PipeName = 'omegas-ecu',
    [ValidateSet('captured', 'idle-cng', 'stable-load', 'acceleration', 'cutoff', 'transition', 'interactive')]
    [string]$Scenario = 'captured',
    [string]$ScenarioFile = (Join-Path $PSScriptRoot '..\Capturas\estado-interativo.json'),
    [string]$ProtocolGuide = (Join-Path $PSScriptRoot '..\Dados\GUIA_INDUSTRIAL_COMPLETO_AEB_OMEGAS_PROGBASE_DLL.md'),
    [string]$LogPath = (Join-Path $PSScriptRoot '..\Capturas\omegas-mp48-ecu.log'),
    [string]$SessionLogPath = '',
    [string]$MemoryPath = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Convert-HexToBytes([string]$Hex) {
    if ([string]::IsNullOrWhiteSpace($Hex)) {
        return [byte[]]::new(0)
    }
    $tokens = $Hex.Trim() -split '\s+'
    return [byte[]]@($tokens | ForEach-Object { [Convert]::ToByte($_, 16) })
}

function Convert-BytesToHex([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ''
    }
    return [BitConverter]::ToString($Bytes).Replace('-', ' ')
}

function Test-RequestChecksum([byte[]]$Bytes) {
    if ($Bytes.Length -lt 3) {
        return $false
    }
    $sum = 0
    for ($i = 0; $i -lt $Bytes.Length - 1; $i++) {
        $sum = ($sum + $Bytes[$i]) -band 0xFF
    }
    return $sum -eq $Bytes[-1]
}

function New-AckFrame([byte[]]$Payload = [byte[]]::new(0)) {
    $frame = [Collections.Generic.List[byte]]::new()
    $frame.Add(0x53)
    $frame.Add([byte]$Payload.Length)
    $frame.AddRange($Payload)
    $checksum = 0
    foreach ($value in $frame) {
        $checksum = ($checksum + $value) -band 0xFF
    }
    $frame.Add([byte]$checksum)
    return $frame.ToArray()
}

function New-NackFrame([byte]$Code = 0x10) {
    # CA 01 10 DB is the documented "unavailable" response.  In Boot Spy
    # mode it is deliberately preferable to a generic ACK: an invented OK
    # would make ProgBase advance through a protocol we have not observed.
    $frame = [byte[]]@(0xCA, 0x01, $Code, 0x00)
    Update-ResponseChecksum $frame
    return $frame
}

function Set-U16Le([byte[]]$Bytes, [int]$Offset, [int]$Value) {
    $Bytes[$Offset] = [byte]($Value -band 0xFF)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xFF)
}

function Update-ResponseChecksum([byte[]]$Response) {
    $checksum = 0
    for ($i = 0; $i -lt $Response.Length - 1; $i++) {
        $checksum = ($checksum + $Response[$i]) -band 0xFF
    }
    $Response[$Response.Length - 1] = [byte]$checksum
}

function Get-MapReadKey([int]$Row) {
    $checksum = (0x2A + 0x54 + $Row) -band 0xFF
    return ('2A 54 00 {0:X2} {1:X2}' -f $Row, $checksum)
}

function New-VirtualAutoCalMemory {
    return [ordered]@{
        enabled = $false; freshOnNextSample = $false
        petrolCount = [int[]]::new(18); petrolInj = [int[]]::new(18); petrolMap = [int[]]::new(18)
        gasCount = [int[]]::new(18); gasInj = [int[]]::new(18); gasMap = [int[]]::new(18)
        samples = 0; stableFuel = ''; stableBand = -1; stableTicks = 0
    }
}

function Initialize-VirtualMemory(
    [Collections.Generic.Dictionary[string, byte[]]]$Responses,
    [string]$Path
) {
    $memory = [ordered]@{ mul = [int[]]::new(30); map = @(); writeCount = 0; autoCalResetMask = 0; autoCalResetCount = 0; autoMatchCount = 0; autoCal = (New-VirtualAutoCalMemory) }
    $mulResponse = $Responses['29 61 01 8B']
    for ($index = 0; $index -lt 30; $index++) {
        $memory.mul[$index] = [int]$mulResponse[2 + ($index * 2)] + ([int]$mulResponse[3 + ($index * 2)] * 256)
    }
    for ($row = 0; $row -lt 13; $row++) {
        $response = $Responses[(Get-MapReadKey $row)]
        $line = [int[]]::new(12)
        for ($column = 0; $column -lt 12; $column++) { $line[$column] = $response[2 + $column] }
        $memory.map += ,$line
    }
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        try {
            $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if ($saved.mul.Count -eq 30 -and $saved.map.Count -eq 13 -and (@($saved.map | ForEach-Object { $_.Count -eq 12 } | Where-Object { -not $_ }).Count -eq 0)) {
                $memory.mul = [int[]]@($saved.mul | ForEach-Object { [int]$_ })
                $memory.map = @()
                foreach ($savedRow in $saved.map) {
                    $memory.map += ,([int[]]@($savedRow | ForEach-Object { [int]$_ }))
                }
                $memory.writeCount = [int]$saved.writeCount
                if ($null -ne $saved.autoCalResetMask) { $memory.autoCalResetMask = [int]$saved.autoCalResetMask }
                if ($null -ne $saved.autoCalResetCount) { $memory.autoCalResetCount = [int]$saved.autoCalResetCount }
                if ($null -ne $saved.autoMatchCount) { $memory.autoMatchCount = [int]$saved.autoMatchCount }
                if ($null -ne $saved.autoCal -and $saved.autoCal.petrolCount.Count -eq 18 -and $saved.autoCal.gasCount.Count -eq 18) {
                    foreach ($name in @('petrolCount','petrolInj','petrolMap','gasCount','gasInj','gasMap')) {
                        if ($null -ne $saved.autoCal.$name -and $saved.autoCal.$name.Count -eq 18) { $memory.autoCal.$name = [int[]]@($saved.autoCal.$name | ForEach-Object { [int]$_ }) }
                    }
                    $memory.autoCal.enabled = [bool]$saved.autoCal.enabled
                    $memory.autoCal.freshOnNextSample = [bool]$saved.autoCal.freshOnNextSample
                    $memory.autoCal.samples = [int]$saved.autoCal.samples
                    $memory.autoCal.stableFuel = [string]$saved.autoCal.stableFuel
                    $memory.autoCal.stableBand = [int]$saved.autoCal.stableBand
                    $memory.autoCal.stableTicks = [int]$saved.autoCal.stableTicks
                }
            }
        } catch {
            Write-Log "virtual-memory-read-error=$($_.Exception.Message)"
        }
    }
    return $memory
}

function Sync-VirtualMemoryToResponses([Collections.Generic.Dictionary[string, byte[]]]$Responses) {
    $mulResponse = $Responses['29 61 01 8B']
    for ($index = 0; $index -lt 30; $index++) {
        $value = $script:VirtualMemory.mul[$index]
        $mulResponse[2 + ($index * 2)] = [byte]($value -band 0xFF)
        $mulResponse[3 + ($index * 2)] = [byte](($value -shr 8) -band 0xFF)
    }
    Update-ResponseChecksum $mulResponse
    for ($row = 0; $row -lt 13; $row++) {
        $response = $Responses[(Get-MapReadKey $row)]
        for ($column = 0; $column -lt 12; $column++) { $response[2 + $column] = [byte]$script:VirtualMemory.map[$row][$column] }
        Update-ResponseChecksum $response
    }
}

function Save-VirtualMemory {
    if ([string]::IsNullOrWhiteSpace($script:ResolvedMemoryPath)) { return }
    try {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ResolvedMemoryPath)) | Out-Null
        $temp = "$script:ResolvedMemoryPath.tmp"
        $script:VirtualMemory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:ResolvedMemoryPath -Force
    } catch {
        Write-Log "virtual-memory-write-error=$($_.Exception.Message)"
    }
}

function Apply-VirtualWrite([byte[]]$Request) {
    if ($Request.Length -ne 7 -or $Request[0] -ne 0x14) { return $null }
    if ($Request[1] -eq 0x61 -and $Request[2] -eq 0x01 -and $Request[3] -lt 30) {
        $index = [int]$Request[3]
        $value = [int]$Request[4] + ([int]$Request[5] * 256)
        $script:VirtualMemory.mul[$index] = $value
        $script:VirtualMemory.writeCount++
        Sync-VirtualMemoryToResponses $responses
        Save-VirtualMemory
        return [pscustomobject]@{ target = 'MUL_ACT'; index = $index; value = $value }
    }
    if ($Request[1] -eq 0x54 -and $Request[2] -eq 0x00 -and $Request[3] -lt 13 -and $Request[4] -lt 12) {
        $row = [int]$Request[3]; $column = [int]$Request[4]; $value = [int]$Request[5]
        $script:VirtualMemory.map[$row][$column] = $value
        $script:VirtualMemory.writeCount++
        Sync-VirtualMemoryToResponses $responses
        Save-VirtualMemory
        return [pscustomobject]@{ target = 'MAP_K'; row = $row; column = $column; value = $value }
    }
    return $null
}

function Reset-ObservedVector([string]$Key) {
    if (-not $responses.ContainsKey($Key)) { return }
    $response = $responses[$Key]
    for ($index = 2; $index -lt ($response.Length - 1); $index++) { $response[$index] = 0 }
    Update-ResponseChecksum $response
}

function Set-ObservedU16Vector([string]$Key, [int[]]$Values) {
    if (-not $responses.ContainsKey($Key)) { return }
    $response = $responses[$Key]
    for ($index = 0; $index -lt $Values.Length; $index++) { Set-U16Le $response (2 + ($index * 2)) $Values[$index] }
    Update-ResponseChecksum $response
}

function Set-ObservedU8Vector([string]$Key, [int[]]$Values) {
    if (-not $responses.ContainsKey($Key)) { return }
    $response = $responses[$Key]
    for ($index = 0; $index -lt $Values.Length; $index++) { $response[2 + $index] = [byte]($Values[$index] -band 0xFF) }
    Update-ResponseChecksum $response
}

function Reset-VirtualAutoCalMemory([int]$Mode = 4) {
    if ($Mode -in @(1,4)) { $script:VirtualMemory.autoCal.petrolCount = [int[]]::new(18); $script:VirtualMemory.autoCal.petrolInj = [int[]]::new(18); $script:VirtualMemory.autoCal.petrolMap = [int[]]::new(18) }
    if ($Mode -in @(2,4)) { $script:VirtualMemory.autoCal.gasCount = [int[]]::new(18); $script:VirtualMemory.autoCal.gasInj = [int[]]::new(18); $script:VirtualMemory.autoCal.gasMap = [int[]]::new(18) }
    if ($Mode -eq 4) { $script:VirtualMemory.autoCal.samples = 0; $script:VirtualMemory.autoCal.stableFuel = ''; $script:VirtualMemory.autoCal.stableBand = -1; $script:VirtualMemory.autoCal.stableTicks = 0 }
}

function Get-AutoCalBand([int]$MapRaw, $State) {
    if ($null -ne $State.autoCalBand -and [int]$State.autoCalBand -ge 0 -and [int]$State.autoCalBand -lt 18) { return [int]$State.autoCalBand }
    $thresholds = Get-ObservedU16Vector '29 4C 01 76'
    for ($index = 0; $index -lt $thresholds.Length; $index++) { if ($MapRaw -le $thresholds[$index]) { return $index } }
    return 17
}

function Get-InterpolatedReturnCurve([int[]]$Injection, [int[]]$Pressure, [int[]]$Count) {
    $axis = [int[]](Get-ObservedU16Vector '29 4B 01 75')
    $anchors = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 18; $index++) { if ($Count[$index] -gt 0 -and $Injection[$index] -gt 0 -and $Pressure[$index] -gt 0) { $anchors.Add([pscustomobject]@{ x=$Injection[$index]; y=$Pressure[$index] }) } }
    if ($anchors.Count -eq 0) { return [int[]]::new(30) }
    $ordered = @($anchors | Sort-Object x)
    $result = [int[]]::new(30)
    for ($point = 0; $point -lt 30; $point++) {
        $x = $axis[$point]
        if ($x -le $ordered[0].x) { $result[$point] = $ordered[0].y; continue }
        if ($x -ge $ordered[-1].x) { $result[$point] = $ordered[-1].y; continue }
        for ($anchor = 0; $anchor -lt $ordered.Count - 1; $anchor++) {
            $left = $ordered[$anchor]; $right = $ordered[$anchor + 1]
            if ($x -ge $left.x -and $x -le $right.x) {
                $result[$point] = [int][Math]::Round($left.y + (($x - $left.x) * ($right.y - $left.y) / ($right.x - $left.x)))
                break
            }
        }
    }
    return $result
}

function Sync-VirtualAutoCalToResponses {
    $auto = $script:VirtualMemory.autoCal
    Set-ObservedU16Vector '29 5B 01 85' $auto.petrolCount; Set-ObservedU16Vector '29 5C 01 86' $auto.gasCount
    Set-ObservedU16Vector '29 62 01 8C' $auto.petrolInj; Set-ObservedU16Vector '29 63 01 8D' $auto.petrolMap
    Set-ObservedU16Vector '29 5F 01 89' $auto.gasInj; Set-ObservedU16Vector '29 60 01 8A' $auto.gasMap
    Set-ObservedU16Vector '29 5D 01 87' $auto.gasInj; Set-ObservedU16Vector '29 5E 01 88' $auto.gasMap
    $zonesPetrol = [int[]]::new(4); $zonesGas = [int[]]::new(4); $ranges = @(@(0,5),@(6,9),@(10,13),@(14,17))
    for ($zone = 0; $zone -lt 4; $zone++) {
        $range = $ranges[$zone]; $zonesPetrol[$zone] = if (@($auto.petrolCount[$range[0]..$range[1]] | Where-Object { $_ -ge 3 }).Count -gt 0) { 1 } else { 0 }
        $zonesGas[$zone] = if (@($auto.gasCount[$range[0]..$range[1]] | Where-Object { $_ -ge 3 }).Count -gt 0) { 1 } else { 0 }
    }
    Set-ObservedU8Vector '29 6F 01 99' $zonesPetrol; Set-ObservedU8Vector '29 70 01 9A' $zonesGas
    Set-ObservedU16Vector '29 8D 01 B7' (Get-InterpolatedReturnCurve $auto.petrolInj $auto.petrolMap $auto.petrolCount)
    Set-ObservedU16Vector '29 8E 01 B8' (Get-InterpolatedReturnCurve $auto.gasInj $auto.gasMap $auto.gasCount)
}

function Apply-InteractiveAutoCalSample($State) {
    $auto = $script:VirtualMemory.autoCal
    if ([bool]$State.autoCalSyntheticStart) { $auto.enabled = $true; $auto.freshOnNextSample = $true }
    if (-not $auto.enabled) { return $null }
    if ($auto.freshOnNextSample) { Reset-VirtualAutoCalMemory 4; $auto.freshOnNextSample = $false }
    $fuel = [string]$State.fuel
    if ($fuel -notin @('PETROL','CNG')) { return $null }
    $mapRaw = [int][Math]::Round([double]$State.mapBar * 1024)
    $injRaw = [int][Math]::Round([double]$State.petrolMs * 512)
    if ($mapRaw -le 0 -or $injRaw -le 0 -or [bool]$State.cutoff) { return $null }
    $band = Get-AutoCalBand $mapRaw $State
    if (-not [bool]$State.stable -and -not [bool]$State.autoCalStimulus) {
        $auto.stableFuel = ''; $auto.stableBand = -1; $auto.stableTicks = 0
        return $null
    }
    if ($auto.stableFuel -eq $fuel -and $auto.stableBand -eq $band) { $auto.stableTicks++ } else { $auto.stableFuel = $fuel; $auto.stableBand = $band; $auto.stableTicks = 1 }
    if ($auto.stableTicks -lt 3) { return $null }
    $countName = if ($fuel -eq 'PETROL') { 'petrolCount' } else { 'gasCount' }
    $injName = if ($fuel -eq 'PETROL') { 'petrolInj' } else { 'gasInj' }
    $mapName = if ($fuel -eq 'PETROL') { 'petrolMap' } else { 'gasMap' }
    $count = [int]$auto.$countName[$band]
    if ($count -lt 10) {
        $auto.$injName[$band] = [int][Math]::Round((($auto.$injName[$band] * $count) + $injRaw) / ($count + 1))
        $auto.$mapName[$band] = [int][Math]::Round((($auto.$mapName[$band] * $count) + $mapRaw) / ($count + 1))
        $auto.$countName[$band] = $count + 1
    } else {
        $auto.$injName[$band] = [int][Math]::Round((($auto.$injName[$band] * 9) + $injRaw) / 10)
        $auto.$mapName[$band] = [int][Math]::Round((($auto.$mapName[$band] * 9) + $mapRaw) / 10)
    }
    $auto.samples++; Sync-VirtualAutoCalToResponses; Save-VirtualMemory
    return [pscustomobject]@{ target='AUTOCAL_SAMPLE'; fuel=$fuel; band=$band; count=$auto.$countName[$band]; samples=$auto.samples; stableTicks=$auto.stableTicks }
}

function Apply-VirtualAutoCalEnable([byte[]]$Request) {
    if ($Request.Length -ne 5 -or $Request[0] -ne 0x12 -or $Request[1] -ne 0x4A -or $Request[2] -ne 0x01 -or $Request[3] -notin @(0,1) -or -not (Test-RequestChecksum $Request)) { return $null }
    $script:VirtualMemory.autoCal.enabled = ($Request[3] -eq 1)
    if ($script:VirtualMemory.autoCal.enabled) { $script:VirtualMemory.autoCal.freshOnNextSample = $true }
    Save-VirtualMemory
    return [pscustomobject]@{ target='AUTOCAL_ENABLE'; enabled=$script:VirtualMemory.autoCal.enabled }
}

function Apply-VirtualAutoCalReset([byte[]]$Request) {
    # Comandos C2 documentados: 01=gasolina, 02=GNV, 04=total.
    if ($Request.Length -ne 5 -or $Request[0] -ne 0x02 -or $Request[1] -ne 0x24 -or $Request[2] -ne 0x04) { return $null }
    if (-not (Test-RequestChecksum $Request)) { return $null }
    $mode = [int]$Request[3]
    if ($mode -notin @(1, 2, 4)) { return $null }

    if ($mode -in @(1, 4)) {
        Reset-VirtualAutoCalMemory $mode
        foreach ($key in @('29 5B 01 85','29 62 01 8C','29 63 01 8D','29 6F 01 99','29 8D 01 B7')) { Reset-ObservedVector $key }
    }
    if ($mode -in @(2, 4)) {
        if ($mode -eq 2) { Reset-VirtualAutoCalMemory $mode }
        foreach ($key in @('29 5C 01 86','29 5D 01 87','29 5E 01 88','29 5F 01 89','29 60 01 8A','29 70 01 9A','29 8E 01 B8')) { Reset-ObservedVector $key }
    }
    if ($mode -eq 4) {
        for ($index = 0; $index -lt 30; $index++) { $script:VirtualMemory.mul[$index] = 16384 }
        Sync-VirtualMemoryToResponses $responses
    }
    $persistMask = if ($mode -eq 4) { 3 } else { $mode }
    $script:VirtualMemory.autoCalResetMask = $script:VirtualMemory.autoCalResetMask -bor $persistMask
    $script:VirtualMemory.autoCalResetCount++
    Save-VirtualMemory
    $label = switch ($mode) { 1 { 'gasolina' } 2 { 'GNV' } default { 'total' } }
    return [pscustomobject]@{ target = 'AUTOCAL_RESET'; mode = $label; count = $script:VirtualMemory.autoCalResetCount }
}

function Apply-PersistedAutoCalReset {
    $mask = [int]$script:VirtualMemory.autoCalResetMask
    if (($mask -band 1) -ne 0) { foreach ($key in @('29 5B 01 85','29 62 01 8C','29 63 01 8D','29 6F 01 99','29 8D 01 B7')) { Reset-ObservedVector $key } }
    if (($mask -band 2) -ne 0) { foreach ($key in @('29 5C 01 86','29 5D 01 87','29 5E 01 88','29 5F 01 89','29 60 01 8A','29 70 01 9A','29 8E 01 B8')) { Reset-ObservedVector $key } }
}

function Get-ObservedU16Vector([string]$Key) {
    if (-not $responses.ContainsKey($Key)) { return @() }
    $response = $responses[$Key]
    $values = @()
    for ($offset = 2; $offset -lt ($response.Length - 2); $offset += 2) {
        $values += ([int]$response[$offset] + ([int]$response[$offset + 1] * 256))
    }
    return $values
}

function Get-InverseCurveTime([int[]]$Axis, [int[]]$Curve, [int]$Target) {
    for ($index = 0; $index -lt ($Curve.Length - 1); $index++) {
        $left = $Curve[$index]; $right = $Curve[$index + 1]
        if ($left -eq 0 -or $right -eq 0 -or $right -eq $left) { continue }
        if (($Target -ge [Math]::Min($left, $right)) -and ($Target -le [Math]::Max($left, $right))) {
            return $Axis[$index] + [int][Math]::Truncate((($Target - $left) * ($Axis[$index + 1] - $Axis[$index])) / ($right - $left))
        }
    }
    return $null
}

function Apply-VirtualAutoMatch([byte[]]$Request) {
    if ($Request.Length -ne 5 -or $Request[0] -ne 0x02 -or $Request[1] -ne 0x24 -or $Request[2] -ne 0x04 -or $Request[3] -ne 0x08) { return $null }
    if (-not (Test-RequestChecksum $Request)) { return $null }

    # Modelo de laboratorio, nunca uma alegacao de formula Landi: usa as duas
    # curvas de retorno para gerar um deslocamento horizontal em Q14.
    $axis = [int[]](Get-ObservedU16Vector '29 4B 01 75')
    $petrol = [int[]](Get-ObservedU16Vector '29 8D 01 B7')
    $gas = [int[]](Get-ObservedU16Vector '29 8E 01 B8')
    if ($axis.Length -ne 30 -or $petrol.Length -ne 30 -or $gas.Length -ne 30) {
        return [pscustomobject]@{ target = 'AUTOMATCH_HYPOTHESIS'; changed = 0; reason = 'curvas-ausentes' }
    }
    $calculated = [int[]]::new(30)
    $valid = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt 30; $index++) {
        if ($axis[$index] -le 0 -or $petrol[$index] -le 0) { continue }
        $gasTime = Get-InverseCurveTime $axis $gas $petrol[$index]
        if ($null -eq $gasTime -or $gasTime -le 0) { continue }
        $calculated[$index] = [Math]::Max(9830, [Math]::Min(57344, [int][Math]::Truncate(($gasTime * 16384.0) / $axis[$index])))
        $valid.Add($index)
    }
    if ($valid.Count -eq 0) { return [pscustomobject]@{ target = 'AUTOMATCH_HYPOTHESIS'; changed = 0; reason = 'sem-sobreposicao' } }
    $first = $valid[0]; $last = $valid[$valid.Count - 1]
    for ($index = 0; $index -lt $first; $index++) { $calculated[$index] = $calculated[$first] }
    for ($index = $last + 1; $index -lt 30; $index++) { $calculated[$index] = $calculated[$last] }
    $changed = 0
    for ($index = 0; $index -lt 30; $index++) {
        if ($script:VirtualMemory.mul[$index] -ne $calculated[$index]) { $changed++ }
        $script:VirtualMemory.mul[$index] = $calculated[$index]
    }
    $script:VirtualMemory.autoMatchCount++
    Sync-VirtualMemoryToResponses $responses
    Save-VirtualMemory
    return [pscustomobject]@{ target = 'AUTOMATCH_HYPOTHESIS'; changed = $changed; count = $script:VirtualMemory.autoMatchCount; formula = 'horizontal-q14-lab' }
}

function New-ScenarioTelemetry([string]$Name, [int]$Tick) {
    # MP48 payload layout is based on captured frames and the documented
    # decoding offsets: rpm 0, gas 6, petrol 8, fuel 11, water 12,
    # level 13, gas pressure 14, gas temperature 16, MAP 17.
    $payload = [byte[]]::new(34)
    $rpm = 850; $gas = 1600; $petrol = 1400; $fuel = 0x90
    $water = 19; $level = 80; $pressure = 1600; $gasTemperature = 55; $map = 400
    switch ($Name) {
        'stable-load' {
            $rpm = 2500; $gas = 2400; $petrol = 2100; $pressure = 1900; $map = 900
        }
        'acceleration' {
            $phase = [Math]::Min($Tick, 16)
            $rpm = 1400 + ($phase * 250)
            $gas = 1500 + ($phase * 90)
            $petrol = 1350 + ($phase * 80)
            $pressure = 1850; $map = 450 + ($phase * 45)
        }
        'cutoff' {
            $rpm = 3200; $gas = 0; $petrol = 180; $pressure = 1500; $map = 250
        }
        'transition' {
            $rpm = 1800; $gas = 1200; $petrol = 1650; $fuel = 0x88; $pressure = 1750; $map = 550
        }
    }
    Set-U16Le $payload 0 $rpm
    Set-U16Le $payload 6 $gas
    Set-U16Le $payload 8 $petrol
    $payload[11] = [byte]$fuel
    $payload[12] = [byte]$water
    $payload[13] = [byte]$level
    Set-U16Le $payload 14 $pressure
    $payload[16] = [byte]$gasTemperature
    Set-U16Le $payload 17 $map
    Set-U16Le $payload 24 $gas
    Set-U16Le $payload 28 $petrol
    return New-AckFrame $payload
}

function Refresh-InteractiveState([string]$Path) {
    # Always read the latest published state. Depending only on the file time
    # made a running laboratory appear frozen on systems whose timestamps do
    # not advance between two quick atomic replacements.
    try {
        $latestState = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -ne $latestState) {
            $script:InteractiveState = $latestState
            $sequence = if ($null -ne $latestState.sequence) { [int64]$latestState.sequence } else { -1 }
            if ($sequence -ne $script:InteractiveStateSequence) {
                $script:InteractiveStateSequence = $sequence
                Write-Log "interactive-state sequence=$sequence rpm=$($latestState.rpm) fuel=$($latestState.fuel)"
            }
        }
    } catch {
        # An atomic state replacement can leave a tiny read window. Keep the
        # previous valid state; never pause serial telemetry for a UI write.
        Write-Log "interactive-state-read-error=$($_.Exception.Message)"
    }
    return $script:InteractiveState
}

function Get-BootSpyEnabled([string]$Path) {
    $state = Refresh-InteractiveState $Path
    return ($null -ne $state -and $null -ne $state.bootSpy -and [bool]$state.bootSpy)
}

function New-InteractiveTelemetry([string]$Path) {
    $state = Refresh-InteractiveState $Path
    if ($null -eq $state) {
        return New-ScenarioTelemetry 'idle-cng' 0
    }
    $payload = [byte[]]::new(34)
    $rpm = [Math]::Max(0, [Math]::Min(9000, [int]$state.rpm))
    $gas = [Math]::Max(0, [Math]::Min(19531, [int]([double]$state.gasMs / 0.00256)))
    $petrol = [Math]::Max(0, [Math]::Min(15625, [int]([double]$state.petrolMs / 0.00256)))
    $fuel = switch ([string]$state.fuel) { 'PETROL' { 0x80 } 'TRANSITION' { 0x88 } default { 0x90 } }
    $water = [Math]::Max(0, [Math]::Min(255, 109 - [int]$state.waterC))
    $gasTemperature = [Math]::Max(0, [Math]::Min(255, 20 + [int]$state.gasC))
    $pressure = [Math]::Max(0, [Math]::Min(4000, [int]([double]$state.pressureBar * 800)))
    $map = [Math]::Max(0, [Math]::Min(2500, [int]([double]$state.mapBar * 1000)))
    $level = [Math]::Max(0, [Math]::Min(255, 255 - [int](([double]$state.levelPercent * 255) / 100)))
    Set-U16Le $payload 0 $rpm
    Set-U16Le $payload 6 $gas
    Set-U16Le $payload 8 $petrol
    $payload[11] = [byte]$fuel
    $payload[12] = [byte]$water
    $payload[13] = [byte]$level
    Set-U16Le $payload 14 $pressure
    $payload[16] = [byte]$gasTemperature
    Set-U16Le $payload 17 $map
    $payload[19] = [byte]([Math]::Max(0, [Math]::Min(255, [int]$state.dynamicCorrection)))
    Set-U16Le $payload 24 $gas
    Set-U16Le $payload 28 $petrol
    return New-AckFrame $payload
}

function Apply-VirtualBootSpy([byte[]]$Request, [bool]$Enabled) {
    if (-not $Enabled) {
        return $null
    }

    $key = Convert-BytesToHex $Request
    $action = switch ($key) {
        '00 09 09' { 'cancel-flash' }
        '00 0A 0A' { 'exit-boot' }
        '00 0B 0B' { 'force-exit-boot' }
        '93 93' { 'start-flash' }
        '85 85' { 'end-flash' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($action)) {
        return @{ target = 'BOOT_SPY'; known = $false; action = 'unmapped'; mode = $script:VirtualBoot.mode }
    }

    switch ($action) {
        'cancel-flash' { $script:VirtualBoot.mode = 'boot-waiting' }
        'exit-boot' { $script:VirtualBoot.mode = 'application' }
        'force-exit-boot' { $script:VirtualBoot.mode = 'application' }
        'start-flash' { $script:VirtualBoot.mode = 'flash-receiving'; $script:VirtualBoot.records = 0 }
        'end-flash' { $script:VirtualBoot.mode = 'boot-waiting' }
    }
    $script:VirtualBoot.frames++
    return @{ target = 'BOOT_SPY'; known = $true; action = $action; mode = $script:VirtualBoot.mode; frames = $script:VirtualBoot.frames }
}

function Import-ObservedResponses([string]$Path) {
    $responses = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::OrdinalIgnoreCase)
    $linePattern = '^\|\s*((?:[0-9A-Fa-f]{2}\s+)+[0-9A-Fa-f]{2})\s*\|.*?\|\s*((?:53|CA|96)(?:\s+[0-9A-Fa-f]{2})+)\s*\|'
    foreach ($line in [IO.File]::ReadLines([IO.Path]::GetFullPath($Path))) {
        $match = [regex]::Match($line, $linePattern)
        if (-not $match.Success) {
            continue
        }
        $request = ($match.Groups[1].Value.Trim() -replace '\s+', ' ').ToUpperInvariant()
        $response = Convert-HexToBytes $match.Groups[2].Value
        if ((Test-RequestChecksum $response) -and -not $responses.ContainsKey($request)) {
            $responses.Add($request, $response)
        }
    }

    # These session frames are the minimum required to establish a real MP48 session.
    $responses['00 02 02'] = Convert-HexToBytes '53 04 FE 4F 45 0B F4'
    $responses['01 00 3A 3B'] = Convert-HexToBytes '53 00 53'
    $responses['00 25 25'] = Convert-HexToBytes '53 01 02 56'
    $responses['00 01 01'] = Convert-HexToBytes '53 00 53'
    # Optional page selector: the real ECU reports this page as unavailable.
    $responses['01 04 54 59'] = Convert-HexToBytes 'CA 01 10 DB'
    $responses['48 08 50'] = Convert-HexToBytes 'CA 01 10 DB'

    return $responses
}

function Get-NextRequest(
    [Collections.Generic.List[byte]]$Buffer,
    [Collections.Generic.Dictionary[string, byte[]]]$Responses
) {
    # A standalone 00 is the documented wake byte. If init follows immediately,
    # the stream begins 00 00 02 02; discard only the first wake byte.
    while ($Buffer.Count -ge 2 -and $Buffer[0] -eq 0x00 -and $Buffer[1] -eq 0x00) {
        $Buffer.RemoveAt(0)
    }
    # Two documented boot/flash sentinels have no length/checksum wrapper.
    # Recognise only those exact pairs before applying normal frame parsing.
    foreach ($bootPair in @('93 93', '85 85')) {
        $bytes = Convert-HexToBytes $bootPair
        if ($Buffer.Count -ge $bytes.Length -and $Buffer[0] -eq $bytes[0] -and $Buffer[1] -eq $bytes[1]) {
            $Buffer.RemoveRange(0, $bytes.Length)
            return $bytes
        }
    }
    if ($Buffer.Count -lt 3) {
        return $null
    }

    # Prefer an observed complete frame over a shorter prefix that happens to
    # have a coincidental checksum (for example 0A 1B 00 25 4A). Candidates
    # are indexed once at startup; converting every one of 773 commands here
    # delayed replies long enough for Omegas to retransmit map rows.
    $candidates = $script:RequestCandidates[[int]$Buffer[0]]
    foreach ($candidate in $candidates) {
        if ($candidate.Bytes.Length -gt $Buffer.Count) {
            continue
        }
        $matches = $true
        for ($i = 0; $i -lt $candidate.Bytes.Length; $i++) {
            if ($Buffer[$i] -ne $candidate.Bytes[$i]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            $Buffer.RemoveRange(0, $candidate.Bytes.Length)
            return $candidate.Bytes
        }
    }

    $maxLength = [Math]::Min($Buffer.Count, 260)
    for ($length = 3; $length -le $maxLength; $length++) {
        $candidate = [byte[]]$Buffer.GetRange(0, $length).ToArray()
        $key = Convert-BytesToHex $candidate
        if ($Responses.ContainsKey($key) -or (Test-RequestChecksum $candidate)) {
            $Buffer.RemoveRange(0, $length)
            return $candidate
        }
    }
    return $null
}

function Write-Log([string]$Message) {
    $timestamp = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    [IO.File]::AppendAllText($script:ResolvedLogPath, "$timestamp $Message$([Environment]::NewLine)")
}

function Write-SessionEvent([hashtable]$Event) {
    if ([string]::IsNullOrWhiteSpace($script:ResolvedSessionLogPath)) {
        return
    }
    $Event.timestamp = [DateTimeOffset]::Now.ToString('o')
    [IO.File]::AppendAllText(
        $script:ResolvedSessionLogPath,
        (($Event | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine),
        [Text.Encoding]::UTF8
    )
}

$responses = Import-ObservedResponses $ProtocolGuide
$script:ResolvedMemoryPath = if ([string]::IsNullOrWhiteSpace($MemoryPath)) { '' } else { [IO.Path]::GetFullPath($MemoryPath) }
$script:VirtualMemory = Initialize-VirtualMemory $responses $script:ResolvedMemoryPath
Sync-VirtualMemoryToResponses $responses
Apply-PersistedAutoCalReset
$script:VirtualBoot = [ordered]@{ mode = 'application'; frames = 0; records = 0 }
$script:ScenarioTick = 0
$script:InteractiveState = $null
$script:InteractiveStateStamp = $null
$script:InteractiveStateSequence = -1
$script:RequestCandidates = @{}
foreach ($responseKey in $responses.Keys) {
    $requestBytes = Convert-HexToBytes $responseKey
    $bucket = [int]$requestBytes[0]
    if (-not $script:RequestCandidates.ContainsKey($bucket)) {
        $script:RequestCandidates[$bucket] = [Collections.Generic.List[object]]::new()
    }
    $script:RequestCandidates[$bucket].Add([pscustomobject]@{ Bytes = $requestBytes })
}
foreach ($bucket in @($script:RequestCandidates.Keys)) {
    $script:RequestCandidates[$bucket] = [Collections.Generic.List[object]]@(
        $script:RequestCandidates[$bucket] | Sort-Object { $_.Bytes.Length } -Descending
    )
}

if ($SelfTest) {
    $required = @('00 02 02', '01 00 3A 3B', '00 25 25', '48 01 49')
    foreach ($request in $required) {
        if (-not $responses.ContainsKey($request)) {
            throw "Resposta obrigatoria ausente: $request"
        }
    }
    foreach ($entry in $responses.GetEnumerator()) {
        if ($entry.Value.Length -lt 3) {
            throw "Resposta curta para $($entry.Key)"
        }
        $expected = 0
        for ($i = 0; $i -lt $entry.Value.Length - 1; $i++) {
            $expected = ($expected + $entry.Value[$i]) -band 0xFF
        }
        if ($expected -ne $entry.Value[-1]) {
            throw "Checksum de resposta invalido para $($entry.Key)"
        }
    }
    $testBuffer = [Collections.Generic.List[byte]]::new()
    foreach ($value in (Convert-HexToBytes '00 00 02')) {
        $testBuffer.Add($value)
    }
    if ($null -ne (Get-NextRequest $testBuffer $responses)) {
        throw 'Parser aceitou quadro fragmentado'
    }
    $testBuffer.Add(0x02)
    $parsed = Get-NextRequest $testBuffer $responses
    if ((Convert-BytesToHex $parsed) -ne '00 02 02') {
        throw 'Parser nao removeu wake byte corretamente'
    }
    $bootBuffer = [Collections.Generic.List[byte]]::new()
    foreach ($value in (Convert-HexToBytes '93 93')) { $bootBuffer.Add($value) }
    $bootStart = Get-NextRequest $bootBuffer $responses
    if ((Convert-BytesToHex $bootStart) -ne '93 93') { throw 'Parser nao reconheceu o sentinela de inicio do flash' }
    $bootAction = Apply-VirtualBootSpy $bootStart $true
    if ($null -eq $bootAction -or -not $bootAction.known -or $bootAction.mode -ne 'flash-receiving') { throw 'Boot Spy nao entrou no estado de recepcao virtual' }
    $bootUnknown = Apply-VirtualBootSpy (Convert-HexToBytes '12 34 46') $true
    if ($null -eq $bootUnknown -or $bootUnknown.known -or -not (Test-RequestChecksum (New-NackFrame))) { throw 'Boot Spy nao sinalizou comando desconhecido com NACK valido' }
    $autoMatch = Apply-VirtualAutoMatch (Convert-HexToBytes '02 24 04 08 32')
    if ($null -eq $autoMatch -or $autoMatch.target -ne 'AUTOMATCH_HYPOTHESIS' -or $autoMatch.changed -le 0) {
        throw 'AutoMatch experimental nao atualizou a Curva K virtual'
    }
    $enableAutoCal = Apply-VirtualAutoCalEnable (Convert-HexToBytes '12 4A 01 01 5E')
    if ($null -eq $enableAutoCal -or -not $enableAutoCal.enabled) { throw 'AutoCal virtual nao foi habilitada' }
    $syntheticSample = [pscustomobject]@{ fuel='PETROL'; mapBar=0.20; petrolMs=3.5; cutoff=$false; stable=$true; autoCalBand=1; autoCalStimulus=$true; autoCalSyntheticStart=$true }
    for ($sampleIndex = 0; $sampleIndex -lt 3; $sampleIndex++) { $null = Apply-InteractiveAutoCalSample $syntheticSample; $syntheticSample.autoCalSyntheticStart=$false }
    if ($script:VirtualMemory.autoCal.petrolCount[1] -lt 1 -or (Get-ObservedU16Vector '29 62 01 8C')[1] -le 0 -or (Get-ObservedU16Vector '29 8D 01 B7')[0] -le 0) {
        throw 'AutoCal virtual nao acumulou nem publicou uma amostra estavel'
    }
    $petrolCountBefore = [byte[]]$responses['29 5B 01 85'].Clone()
    $resetPetrol = Apply-VirtualAutoCalReset (Convert-HexToBytes '02 24 04 01 2B')
    if ($null -eq $resetPetrol -or $resetPetrol.target -ne 'AUTOCAL_RESET' -or $resetPetrol.mode -ne 'gasolina') {
        throw 'Reset virtual de gasolina nao foi reconhecido'
    }
    $petrolCountAfter = $responses['29 5B 01 85']
    if ((@($petrolCountBefore[2..($petrolCountBefore.Length - 2)] | Where-Object { $_ -ne 0 }).Count -eq 0) -or (@($petrolCountAfter[2..($petrolCountAfter.Length - 2)] | Where-Object { $_ -ne 0 }).Count -ne 0)) {
        throw 'Reset virtual de gasolina nao limpou o buffer observado'
    }
    $resetTotal = Apply-VirtualAutoCalReset (Convert-HexToBytes '02 24 04 04 2E')
    if ($null -eq $resetTotal -or $resetTotal.mode -ne 'total' -or (@($script:VirtualMemory.mul | Where-Object { $_ -ne 16384 }).Count -ne 0)) {
        throw 'Reset virtual total nao restaurou a Curva K para 1,000'
    }
    "SELF_TEST_OK responses=$($responses.Count) telemetry=$((Convert-BytesToHex $responses['48 01 49']))"
    exit 0
}

$script:ResolvedLogPath = [IO.Path]::GetFullPath($LogPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ResolvedLogPath)) | Out-Null
$script:ResolvedSessionLogPath = if ([string]::IsNullOrWhiteSpace($SessionLogPath)) { '' } else { [IO.Path]::GetFullPath($SessionLogPath) }
if (-not [string]::IsNullOrWhiteSpace($script:ResolvedSessionLogPath)) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ResolvedSessionLogPath)) | Out-Null
}
Write-Log "emulator-start pipe=\\.\pipe\$PipeName scenario=$Scenario responses=$($responses.Count)"
Write-SessionEvent @{ type = 'emulator-start'; pipe = $PipeName; scenario = $Scenario; observedResponses = $responses.Count; virtualWriteCount = $script:VirtualMemory.writeCount }

while ($true) {
    $pipe = [IO.Pipes.NamedPipeServerStream]::new(
        $PipeName,
        [IO.Pipes.PipeDirection]::InOut,
        1,
        [IO.Pipes.PipeTransmissionMode]::Byte,
        [IO.Pipes.PipeOptions]::WriteThrough,
        4096,
        4096
    )
    try {
        $pipe.WaitForConnection()
        Write-Log 'connected'
        Write-SessionEvent @{ type = 'connection'; state = 'connected' }
        $buffer = [Collections.Generic.List[byte]]::new()
        $readBuffer = [byte[]]::new(4096)

        while ($pipe.IsConnected) {
            $count = $pipe.Read($readBuffer, 0, $readBuffer.Length)
            if ($count -le 0) {
                break
            }
            $chunk = [byte[]]$readBuffer[0..($count - 1)]
            $buffer.AddRange($chunk)
            Write-Log "rx-chunk length=$count hex=$(Convert-BytesToHex $chunk)"
            $bootSpyEnabled = ($Scenario -eq 'interactive' -and (Get-BootSpyEnabled $ScenarioFile))
            if ($bootSpyEnabled) {
                Write-SessionEvent @{ type = 'boot-raw'; direction = 'TX'; frame = (Convert-BytesToHex $chunk); bytes = $chunk.Length; bootMode = $script:VirtualBoot.mode }
            }

            while ($true) {
                $request = Get-NextRequest $buffer $responses
                if ($null -eq $request) {
                    break
                }
                $requestKey = Convert-BytesToHex $request
                $bootSpyEnabled = ($Scenario -eq 'interactive' -and (Get-BootSpyEnabled $ScenarioFile))
                $bootResult = Apply-VirtualBootSpy $request $bootSpyEnabled
                $virtualWrite = Apply-VirtualWrite $request
                if ($null -ne $bootResult -and $bootResult.known) {
                    $response = New-AckFrame
                    $source = 'boot-spy-known'
                } elseif ($null -ne $bootResult -and -not $bootResult.known -and -not $responses.ContainsKey($requestKey)) {
                    $response = New-NackFrame
                    $source = 'boot-spy-unmapped'
                } else {
                    if ($null -eq $virtualWrite) { $virtualWrite = Apply-VirtualAutoCalReset $request }
                    if ($null -eq $virtualWrite) { $virtualWrite = Apply-VirtualAutoCalEnable $request }
                    if ($null -eq $virtualWrite) { $virtualWrite = Apply-VirtualAutoMatch $request }
                }
                if ($null -ne $bootResult -and ($bootResult.known -or (-not $bootResult.known -and -not $responses.ContainsKey($requestKey)))) {
                    # Response and source were intentionally assigned above.
                } elseif ($null -ne $virtualWrite) {
                    $response = New-AckFrame
                    $source = if ($virtualWrite.target -eq 'AUTOCAL_RESET') { 'virtual-autocal-reset' } elseif ($virtualWrite.target -eq 'AUTOCAL_ENABLE') { 'virtual-autocal-enable' } elseif ($virtualWrite.target -eq 'AUTOMATCH_HYPOTHESIS') { 'virtual-automatch-hypothesis' } else { 'virtual-write' }
                } elseif ($requestKey -eq '48 01 49' -and $Scenario -ne 'captured') {
                    $script:ScenarioTick++
                    if ($Scenario -eq 'interactive') {
                        try {
                            $stateForSample = Get-Content -LiteralPath $ScenarioFile -Raw | ConvertFrom-Json
                            $sample = Apply-InteractiveAutoCalSample $stateForSample
                            if ($null -ne $sample) { Write-Log "autocal-sample fuel=$($sample.fuel) band=$($sample.band) count=$($sample.count)" }
                        } catch { Write-Log "autocal-sample-read-error=$($_.Exception.Message)" }
                    }
                    $response = if ($Scenario -eq 'interactive') { New-InteractiveTelemetry $ScenarioFile } else { New-ScenarioTelemetry $Scenario $script:ScenarioTick }
                    $source = "scenario-$Scenario"
                } elseif ($responses.ContainsKey($requestKey)) {
                    $response = $responses[$requestKey]
                    $source = 'observed'
                } else {
                    $response = New-AckFrame
                    $source = 'generic-ack'
                }

                # The physical Landi/AEB interface echoes the complete request first.
                $pipe.Write($request, 0, $request.Length)
                $pipe.Write($response, 0, $response.Length)
                $pipe.Flush()
                Write-Log "transaction request=$requestKey source=$source response=$(Convert-BytesToHex $response)"
                $event = @{ type = 'transaction'; request = $requestKey; source = $source; response = (Convert-BytesToHex $response); scenario = $Scenario }
                if ($null -ne $virtualWrite) { $event.virtualWrite = $virtualWrite }
                if ($null -ne $bootResult) { $event.bootSpy = $bootResult }
                if ($Scenario -eq 'interactive' -and $null -ne $script:InteractiveState) {
                    $event.state = $script:InteractiveState
                    $event.stateSequence = $script:InteractiveStateSequence
                }
                Write-SessionEvent $event
                if ($bootSpyEnabled) {
                    Write-SessionEvent @{ type = 'boot-raw'; direction = 'RX'; request = $requestKey; frame = (Convert-BytesToHex $response); bytes = $response.Length; source = $source; bootMode = $script:VirtualBoot.mode }
                }
            }
        }
    }
    catch {
        Write-Log "error=$($_.Exception.Message)"
    }
    finally {
        $pipe.Dispose()
        Write-Log 'disconnected'
        Write-SessionEvent @{ type = 'connection'; state = 'disconnected' }
    }
    Start-Sleep -Milliseconds 250
}
