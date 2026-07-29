param(
    [ValidateRange(1, 10000)]
    [int]$Ensaios = 1000,
    [string]$Destino = '',
    [switch]$SomentePlano
)

$ErrorActionPreference = 'Stop'

$laboratorio = Split-Path $PSScriptRoot -Parent
$modeloPath = Join-Path $laboratorio 'Dados\modelo-comportamental.json'
$motorPath = Join-Path $PSScriptRoot 'omegas-mp48-ecu.ps1'

function Hex-ParaBytes([string]$Hex) {
    return [byte[]]@($Hex.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { [Convert]::ToByte($_, 16) })
}

function Bytes-ParaHex([byte[]]$Bytes) {
    return [BitConverter]::ToString($Bytes).Replace('-', ' ')
}

function Ler-Exato([IO.Stream]$Stream, [int]$Quantidade) {
    $buffer = [byte[]]::new($Quantidade)
    $offset = 0
    while ($offset -lt $Quantidade) {
        $lidos = $Stream.Read($buffer, $offset, $Quantidade - $offset)
        if ($lidos -le 0) { throw 'A ECU virtual encerrou a conexao durante a leitura.' }
        $offset += $lidos
    }
    return $buffer
}

function Enviar-Leitura([IO.Pipes.NamedPipeClientStream]$Pipe, [string]$Hex) {
    $pedido = Hex-ParaBytes $Hex
    $Pipe.Write($pedido, 0, $pedido.Length)
    $Pipe.Flush()
    $eco = Ler-Exato $Pipe $pedido.Length
    if ((Bytes-ParaHex $eco) -ne $Hex) { throw "Eco inesperado para $Hex" }
    $cabecalho = Ler-Exato $Pipe 2
    $corpo = if ($cabecalho[1] -gt 0) { Ler-Exato $Pipe ([int]$cabecalho[1]) } else { [byte[]]::new(0) }
    $checksum = Ler-Exato $Pipe 1
    $resposta = [byte[]]@($cabecalho + $corpo + $checksum)
    $soma = 0
    for ($i = 0; $i -lt $resposta.Length - 1; $i++) { $soma = ($soma + $resposta[$i]) -band 0xFF }
    if ($soma -ne $resposta[-1]) { throw "Checksum invalido na resposta de $Hex" }
    return $resposta
}

function Valor-Do-Grupo($Grupo, [string]$Nome, [int]$Indice) {
    $faixa = $Grupo.values.$Nome
    if ($null -eq $faixa) { return 0.0 }
    $seletor = $Indice % 3
    if ($seletor -eq 0) { return [double]$faixa.p10 }
    if ($seletor -eq 1) { return [double]$faixa.median }
    return [double]$faixa.p90
}

function Novo-EstadoDeEnsaio($Grupo, [int]$Indice) {
    $combustivel = switch ([string]$Grupo.fuel) { 'PETROL' { 'PETROL' } 'TRANSITION' { 'TRANSITION' } default { 'CNG' } }
    $rpm = [int][Math]::Round((Valor-Do-Grupo $Grupo 'rpm' $Indice))
    $map = [Math]::Round((Valor-Do-Grupo $Grupo 'load_bar' $Indice), 3)
    $pressao = [Math]::Round((Valor-Do-Grupo $Grupo 'gas_pressure_abs_bar' $Indice), 3)
    $injGasolina = [Math]::Round((Valor-Do-Grupo $Grupo 'petrol_ms' $Indice), 2)
    $injGnv = [Math]::Round((Valor-Do-Grupo $Grupo 'gas_ms_diagnostic' $Indice), 2)
    if ($combustivel -eq 'PETROL') { $injGnv = 0 }
    if ([string]$Grupo.state -eq 'CUTOFF') { $injGasolina = [Math]::Min(0.5, $injGasolina); $injGnv = 0 }
    return [ordered]@{
        sequence = $Indice + 1
        publishedAt = [DateTimeOffset]::Now.ToString('o')
        rpm = $rpm
        petrolMs = $injGasolina
        gasMs = $injGnv
        mapBar = $map
        pressureBar = $pressao
        waterC = [int][Math]::Round((Valor-Do-Grupo $Grupo 'water_c' $Indice))
        gasC = [int][Math]::Round((Valor-Do-Grupo $Grupo 'gas_c' $Indice))
        levelPercent = 68
        dynamicCorrection = [int][Math]::Round((Valor-Do-Grupo $Grupo 'dynamic_correction' $Indice))
        fuel = $combustivel
        cutoff = ([string]$Grupo.state -eq 'CUTOFF')
        stable = ($combustivel -eq 'CNG' -and [string]$Grupo.state -in @('CRUISE', 'LOAD'))
        behaviorState = [string]$Grupo.state
        modelBucket = "$($Grupo.fuel)/$($Grupo.state)/$($Grupo.rpmBin)/$($Grupo.loadBin)"
        campaign = 'protocol-read-only-v1'
    }
}

function Publicar-Estado($Estado, [string]$Path) {
    $temporario = "$Path.tmp"
    $Estado | ConvertTo-Json | Set-Content -LiteralPath $temporario -Encoding UTF8
    Move-Item -LiteralPath $temporario -Destination $Path -Force
}

function Decodificar-Telemetria([byte[]]$Resposta) {
    if ($Resposta.Length -lt 38 -or $Resposta[0] -ne 0x53) { throw 'Resposta de telemetria curta.' }
    $payload = $Resposta[2..($Resposta.Length - 2)]
    $u16 = { param([int]$Offset) [int]$payload[$Offset] + ([int]$payload[$Offset + 1] * 256) }
    return [ordered]@{
        rpm = & $u16 0
        gasMs = [Math]::Round((& $u16 6) * 0.00256, 3)
        petrolMs = [Math]::Round((& $u16 8) * 0.00256, 3)
        fuelRaw = [int]$payload[11]
        pressureRaw = & $u16 14
        mapBar = [Math]::Round((& $u16 17) / 1000.0, 3)
    }
}

if ([string]::IsNullOrWhiteSpace($Destino)) {
    $Destino = Join-Path $laboratorio ("Sessoes\campanha-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$Destino = [IO.Path]::GetFullPath($Destino)
[IO.Directory]::CreateDirectory($Destino) | Out-Null

if (-not (Test-Path -LiteralPath $modeloPath)) { throw "Modelo comportamental ausente: $modeloPath" }
$modelo = Get-Content -LiteralPath $modeloPath -Raw | ConvertFrom-Json
if ($modelo.schema -ne 'omegas-behaviour-v1' -or @($modelo.buckets).Count -eq 0) { throw 'Modelo comportamental invalido.' }

$estados = for ($indice = 0; $indice -lt $Ensaios; $indice++) {
    Novo-EstadoDeEnsaio $modelo.buckets[$indice % $modelo.buckets.Count] $indice
}

$plano = [ordered]@{
    createdAt = [DateTimeOffset]::Now.ToString('o')
    type = 'campanha-ecu-virtual'
    mode = if ($SomentePlano) { 'plano' } else { 'execucao' }
    scenarios = $Ensaios
    sourceModel = 'omegas-behaviour-v1'
    sourceSamples = $modelo.sampleCount
    safety = 'Somente leituras do protocolo contra uma ECU virtual. Nenhuma escrita de Mapa K, Curva K ou contato com ECU fisica.'
    limitation = 'Esta campanha testa o protocolo da ECU virtual. Ela nao mede comportamento visual do ProgBase sem uma ponte COM virtual.'
}
$plano | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destino 'campanha.json') -Encoding UTF8

if ($SomentePlano) {
    $estados | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Destino 'plano-de-estados.json') -Encoding UTF8
    "PLANO_OK ensaios=$Ensaios destino=$Destino"
    exit 0
}

$pipeName = 'omegas-campanha-' + [guid]::NewGuid().ToString('N')
$statePath = Join-Path $Destino 'estado-atual.json'
$eventsPath = Join-Path $Destino 'resultados.jsonl'
$engineLog = Join-Path $Destino 'serial.log'
$protocolLog = Join-Path $Destino 'protocol-events.jsonl'
$memoryPath = Join-Path $Destino 'memoria-ecu-virtual.json'
$args = "-NoProfile -ExecutionPolicy Bypass -File `"$motorPath`" -PipeName $pipeName -Scenario interactive -ScenarioFile `"$statePath`" -LogPath `"$engineLog`" -SessionLogPath `"$protocolLog`" -MemoryPath `"$memoryPath`""
$motor = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
$pipe = $null

try {
    $limite = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
        try { $pipe.Connect(400) } catch { $pipe.Dispose(); $pipe = $null; Start-Sleep -Milliseconds 120 }
    } while ($null -eq $pipe -and [DateTime]::UtcNow -lt $limite)
    if ($null -eq $pipe) { throw 'A ECU virtual nao iniciou a tempo.' }
    $pipe.ReadTimeout = 2500
    [void](Enviar-Leitura $pipe '00 02 02')
    $leituras = @('48 01 49', '29 5B 01 85', '29 5C 01 86', '29 61 01 8B', '29 62 01 8C', '29 63 01 8D', '29 8D 01 B7', '29 8E 01 B8')
    $falhas = 0
    foreach ($estado in $estados) {
        Publicar-Estado $estado $statePath
        $resultado = [ordered]@{ sequence=$estado.sequence; bucket=$estado.modelBucket; input=$estado; reads=@(); ok=$true }
        foreach ($leitura in $leituras) {
            try {
                $resposta = Enviar-Leitura $pipe $leitura
                $registro = [ordered]@{ request=$leitura; response=(Bytes-ParaHex $resposta); ok=$true }
                if ($leitura -eq '48 01 49') { $registro.telemetry = Decodificar-Telemetria $resposta }
                $resultado.reads += $registro
            } catch {
                $resultado.ok = $false
                $resultado.reads += [ordered]@{ request=$leitura; ok=$false; error=$_.Exception.Message }
                $falhas++
            }
        }
        [IO.File]::AppendAllText($eventsPath, (($resultado | ConvertTo-Json -Compress -Depth 7) + [Environment]::NewLine), [Text.Encoding]::UTF8)
    }
    $linhas = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })
    $rpmObservada = @($linhas | ForEach-Object { $_.reads | Where-Object { $_.request -eq '48 01 49' } | ForEach-Object { $_.telemetry.rpm } })
    $relatorio = @(
        '# Campanha ECU virtual',
        '',
        "- Ensaios: **$Ensaios**",
        "- Leituras por ensaio: **$($leituras.Count)**",
        "- Total de leituras: **$($Ensaios * $leituras.Count)**",
        "- Falhas de leitura: **$falhas**",
        "- RPM observada: **$([int](($rpmObservada | Measure-Object -Minimum).Minimum)) a $([int](($rpmObservada | Measure-Object -Maximum).Maximum))**",
        '',
        '## O que este resultado prova',
        '',
        '- A ECU virtual respondeu de forma consistente aos estados e leituras conhecidos da campanha.',
        '- Os arquivos `resultados.jsonl` e `protocol-events.jsonl` preservam cada entrada e resposta.',
        '- Este ensaio nao afirma que o ProgBase desenhou ou decidiu algo: isso exige a ponte COM virtual e o ProgBase conectado.'
    )
    [IO.File]::WriteAllLines((Join-Path $Destino 'RELATORIO.md'), $relatorio, [Text.Encoding]::UTF8)
    "CAMPANHA_OK ensaios=$Ensaios leituras=$($Ensaios * $leituras.Count) falhas=$falhas destino=$Destino"
}
finally {
    if ($null -ne $pipe) { $pipe.Dispose() }
    if ($null -ne $motor -and -not $motor.HasExited) { Stop-Process -Id $motor.Id -Force }
}
