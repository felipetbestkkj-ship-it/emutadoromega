param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot 'omegas-mp48-ecu.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('omegas-boot-spy-' + [guid]::NewGuid().ToString('N'))
$statePath = Join-Path $testRoot 'estado.json'
$serialLog = Join-Path $testRoot 'serial.log'
$eventsLog = Join-Path $testRoot 'protocol-events.jsonl'
$memoryPath = Join-Path $testRoot 'memory.json'
$pipeName = 'omegas-boot-spy-' + [guid]::NewGuid().ToString('N')
$engineProcess = $null
$client = $null
$script:assertions = 0

function Convert-HexToBytes([string]$Hex) {
    return [byte[]]@(($Hex -split '\s+') | ForEach-Object { [Convert]::ToByte($_, 16) })
}

function Convert-BytesToHex([byte[]]$Bytes) {
    return [BitConverter]::ToString($Bytes).Replace('-', ' ')
}

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Message) {
    $script:assertions++
    if ($Expected -ne $Actual) {
        throw "$Message`nEsperado: $Expected`nObtido:   $Actual"
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) {
        throw $Message
    }
}

function Write-State([bool]$BootSpy) {
    [ordered]@{
        sequence = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        bootSpy = $BootSpy
        rpm = 0
        fuel = 'PETROL'
        petrolMs = 0
        gasMs = 0
        mapBar = 0.2
        pressureBar = 2.0
        waterC = 20
        gasC = 20
        levelPercent = 50
        dynamicCorrection = 0
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Read-Exact([int]$Length) {
    $result = [byte[]]::new($Length)
    $offset = 0
    while ($offset -lt $Length) {
        $read = $client.Read($result, $offset, $Length - $offset)
        if ($read -le 0) {
            throw "A porta fechou com $offset de $Length bytes recebidos."
        }
        $offset += $read
    }
    return $result
}

function Invoke-Frame(
    [string]$RequestHex,
    [string]$ResponseHex,
    [switch]$Fragmented
) {
    $request = Convert-HexToBytes $RequestHex
    $response = Convert-HexToBytes $ResponseHex
    if ($Fragmented -and $request.Length -gt 1) {
        $client.Write($request, 0, 1)
        $client.Flush()
        Start-Sleep -Milliseconds 35
        $client.Write($request, 1, $request.Length - 1)
    } else {
        $client.Write($request, 0, $request.Length)
    }
    $client.Flush()
    $actual = Read-Exact ($request.Length + $response.Length)
    Assert-Equal "$RequestHex $ResponseHex" (Convert-BytesToHex $actual) "Resposta incorreta para $RequestHex"
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Write-State $true

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$engine`"",
        '-PipeName', $pipeName,
        '-Scenario', 'interactive',
        '-ScenarioFile', "`"$statePath`"",
        '-LogPath', "`"$serialLog`"",
        '-SessionLogPath', "`"$eventsLog`"",
        '-MemoryPath', "`"$memoryPath`""
    )
    $engineProcess = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    # A primeira carga do PowerShell pode ser mais lenta em maquinas ocupadas.
    # O teste espera o canal ficar pronto em vez de competir com a inicializacao.
    $client.Connect(15000)
    $client.ReadMode = [IO.Pipes.PipeTransmissionMode]::Byte

    # Normal ECU identification must remain usable while the spy is armed.
    Invoke-Frame '00 02 02' '53 04 FE 4F 45 0B F4'

    # All five statically proven boot actions.
    Invoke-Frame '00 09 09' '53 00 53' -Fragmented
    Invoke-Frame 'A0 01 A1' '53 00 53'
    Invoke-Frame '93 93' '53 00 53'
    Invoke-Frame 'F1 01 F2' '53 00 53'
    Invoke-Frame '53 32 01 86' '53 00 53'
    Invoke-Frame '3A 01 3B' '53 00 53'
    Invoke-Frame '85 85' '53 00 53'
    Invoke-Frame '00 0A 0A' '53 00 53'
    Invoke-Frame '00 0B 0B' '53 00 53'

    # Two sentinels can arrive in the same OS-level chunk and must remain
    # distinct transactions.
    $burst = Convert-HexToBytes '93 93 85 85'
    $client.Write($burst, 0, $burst.Length)
    $client.Flush()
    Assert-Equal '93 93 53 00 53 85 85 53 00 53' (Convert-BytesToHex (Read-Exact 10)) 'Parser misturou dois sentinelas no mesmo pacote.'
    Invoke-Frame '00 0A 0A' '53 00 53'

    # Unknown frames must never receive a false success while Boot Spy is on.
    Invoke-Frame '12 34 46' 'CA 01 10 DB'
    Invoke-Frame '12 34 46' 'CA 01 10 DB'

    # Stress the parser and strict policy with forty different valid frames.
    for ($index = 0; $index -lt 40; $index++) {
        $command = 0xF0
        $argument = $index
        $checksum = ($command + $argument) -band 0xFF
        $requestHex = '{0:X2} {1:X2} {2:X2}' -f $command, $argument, $checksum
        Invoke-Frame $requestHex 'CA 01 10 DB' -Fragmented:($index % 2 -eq 0)
    }

    # Programming can be detected from the payload itself, independently of
    # a button, menu, licence tier or the known boot sentinels.
    Invoke-Frame '53 32 01 86' '53 00 53'
    Invoke-Frame '00 0A 0A' '53 00 53'

    # Disabling the spy restores the existing compatibility behavior.
    Write-State $false
    Start-Sleep -Milliseconds 80
    Invoke-Frame '12 34 46' '53 00 53'

    $client.Dispose()
    $client = $null

    # A malformed frame is still valuable evidence. It should be recorded raw,
    # the connection may end, and the next clean connection must work.
    Write-State $true
    Start-Sleep -Milliseconds 80
    $client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    $client.Connect(5000)
    $malformed = Convert-HexToBytes '12 34 00'
    $client.Write($malformed, 0, $malformed.Length)
    $client.Flush()
    Start-Sleep -Milliseconds 80
    $client.Dispose()
    $client = $null
    Start-Sleep -Milliseconds 300

    $client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    $client.Connect(5000)
    Invoke-Frame '93 93' '53 00 53'
    $client.Dispose()
    $client = $null
    Start-Sleep -Milliseconds 180

    $events = @(
        Get-Content -LiteralPath $eventsLog |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $transactions = @($events | Where-Object { $_.type -eq 'transaction' })
    $raw = @($events | Where-Object { $_.type -eq 'boot-raw' })
    $blocks = @($events | Where-Object { $_.type -eq 'boot-block' })
    $known = @($transactions | Where-Object { $_.source -eq 'boot-spy-known' })
    $adaptive = @($transactions | Where-Object { $_.source -eq 'boot-spy-adaptive' })
    $unknown = @($transactions | Where-Object { $_.source -eq 'boot-spy-unmapped' })
    $observed = @($transactions | Where-Object { $_.source -eq 'observed' })
    $compatibility = @($transactions | Where-Object { $_.source -eq 'generic-ack' })

    Assert-Equal '10' ([string]$known.Count) 'Quantidade incorreta de etapas conhecidas.'
    Assert-Equal '5' ([string]$adaptive.Count) 'Quantidade incorreta de respostas adaptativas.'
    Assert-Equal '5' ([string]$blocks.Count) 'Quantidade incorreta de blocos catalogados.'
    Assert-Equal '42' ([string]$unknown.Count) 'Quantidade incorreta de quadros desconhecidos.'
    Assert-True ($observed.Count -ge 1) 'Identificacao normal deixou de usar resposta observada.'
    Assert-Equal '1' ([string]$compatibility.Count) 'Modo normal nao restaurou o ACK de compatibilidade.'
    Assert-True ($raw.Count -ge 134) 'Captura bruta TX/RX ficou incompleta.'
    Assert-True (@($observed | Where-Object { $null -ne $_.bootSpy }).Count -eq 0) 'Resposta observada foi rotulada incorretamente como quadro de boot desconhecido.'
    Assert-True (@($known | Where-Object { $_.bootSpy.action -eq 'start-flash' }).Count -eq 3) 'Inicios de flash nao apareceram corretamente nos eventos estruturados.'
    Assert-True (@($blocks | Where-Object { $_.action -eq 'boot-negotiation' }).Count -eq 1) 'Negociacao automatica de boot nao foi catalogada.'
    Assert-True (@($blocks | Where-Object { $_.action -eq 'program-block-autodetected' -and $_.detectedBy -eq 'motorola-s-record' }).Count -eq 1) 'Programacao nao foi autodetectada pela assinatura do payload.'
    Assert-True (@($blocks | Where-Object { $_.payloadKind -eq 'motorola-s-record' }).Count -eq 2) 'Blocos Motorola S-record nao foram classificados.'
    Assert-True (@($blocks | Where-Object { $_.payloadKind -eq 'intel-hex' }).Count -eq 1) 'Bloco Intel HEX nao foi classificado.'
    Assert-True (@($blocks | Where-Object { $_.action -eq 'program-block' -and $_.payloadKind -eq 'binary-or-framed' }).Count -eq 1) 'Bloco binario nao foi classificado.'
    Assert-True (@($raw | Where-Object { $_.direction -eq 'TX' -and $_.frame -eq '12 34 00' }).Count -eq 1) 'Quadro malformado nao foi preservado como evidencia bruta.'

    Write-Output "BOOT_SPY_TEST_OK assertions=$script:assertions transactions=$($transactions.Count) known=$($known.Count) adaptive=$($adaptive.Count) unmapped=$($unknown.Count) blocks=$($blocks.Count) raw=$($raw.Count)"
    if ($KeepArtifacts) {
        Write-Output "ARTIFACTS=$testRoot"
    }
}
finally {
    if ($null -ne $client) {
        $client.Dispose()
    }
    if ($null -ne $engineProcess -and -not $engineProcess.HasExited) {
        Stop-Process -Id $engineProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot)) {
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $resolvedTest = [IO.Path]::GetFullPath($testRoot)
        if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path $resolvedTest -Leaf).StartsWith('omegas-boot-spy-')) {
            Remove-Item -LiteralPath $resolvedTest -Recurse -Force
        }
    }
}
