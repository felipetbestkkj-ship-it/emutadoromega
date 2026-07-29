Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$laboratoryRoot = Split-Path $PSScriptRoot -Parent
$root = Split-Path $laboratoryRoot -Parent
$engine = Join-Path $PSScriptRoot 'omegas-mp48-ecu.ps1'
$sessionsRoot = Join-Path $laboratoryRoot 'Sessoes'
$script:statePath = Join-Path $laboratoryRoot 'Capturas\estado-interativo.json'
$script:engineProcess = $null
$script:lastTick = [DateTime]::UtcNow
$script:lastSnapshotAt = [DateTime]::MinValue
$script:stateSequence = 0
$script:sessionRoot = ''
$script:sessionEventsPath = ''
$script:sessionStartedAt = $null
$script:lastProtocolScanAt = [DateTime]::MinValue
$script:lastProtocolSummary = [ordered]@{ last='Aguardando o ProgBase'; source=''; transactions=0; unknown=0 }
$script:plant = [ordered]@{ running=$false; rpm=0.0; mapBar=0.28; petrolMs=0.0; gasMs=0.0; waterC=24.0; gasC=24.0; pressureBar=1.10; correction=0.0; level=68.0; stableSince=$null }
$script:behaviorModelPath = Join-Path $laboratoryRoot 'Dados\modelo-comportamental.json'
$script:behaviorBuckets = @()
$script:behaviorModelStatus = 'Fallback interno: modelo comportamental indisponivel.'

function Initialize-BehaviorModel {
    if (-not (Test-Path -LiteralPath $script:behaviorModelPath)) { return }
    try {
        $candidate = Get-Content -LiteralPath $script:behaviorModelPath -Raw | ConvertFrom-Json
        if ($candidate.schema -ne 'omegas-behaviour-v1' -or $null -eq $candidate.buckets -or @($candidate.buckets).Count -eq 0) {
            throw 'Estrutura do modelo invalida.'
        }
        $script:behaviorBuckets = @($candidate.buckets | Where-Object {
            $_.values.rpm.p10 -le $_.values.rpm.median -and $_.values.rpm.median -le $_.values.rpm.p90 -and
            $_.values.load_bar.p10 -le $_.values.load_bar.median -and $_.values.load_bar.median -le $_.values.load_bar.p90
        })
        if ($script:behaviorBuckets.Count -eq 0) { throw 'Nenhuma faixa valida no modelo.' }
        $script:behaviorModelStatus = "Modelo estatistico: $($script:behaviorBuckets.Count) padroes / $($candidate.sampleCount) amostras"
    } catch {
        $script:behaviorBuckets = @()
        $script:behaviorModelStatus = 'Fallback interno: modelo comportamental invalido.'
    }
}
Initialize-BehaviorModel

function Add-Label($text, $x, $y, $w, $h = 24, $font = $null) {
    $label = New-Object Windows.Forms.Label
    $label.Text=$text; $label.Location="$x,$y"; $label.Size="$w,$h"; $label.ForeColor=[Drawing.Color]::Gainsboro
    if ($null -ne $font) { $label.Font=$font }
    $script:activeSurface.Controls.Add($label); return $label
}
function Add-Slider($key, $caption, $min, $max, $value, $x, $y, $suffix) {
    Add-Label $caption $x $y 180 | Out-Null
    $bar = New-Object Windows.Forms.TrackBar
    $bar.Minimum=$min; $bar.Maximum=$max; $bar.Value=$value; $bar.TickFrequency=[Math]::Max(1,[int](($max-$min)/10)); $bar.AutoSize=$false
    $bar.Location="$($x+175),$($y-7)"; $bar.Size='300,32'
    $readout = Add-Label '' ($x+480) $y 100
    $render = { $readout.Text = "$($bar.Value)$suffix" }.GetNewClosure()
    $bar.Add_ValueChanged($render); & $render
    $script:activeSurface.Controls.Add($bar); $controls[$key]=$bar
}
function Stop-ExistingEngine {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*omegas-mp48-ecu.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Write-LabEvent([hashtable]$event) {
    if ([string]::IsNullOrWhiteSpace($script:sessionEventsPath)) { return }
    $event.timestamp = [DateTimeOffset]::Now.ToString('o')
    [IO.File]::AppendAllText(
        $script:sessionEventsPath,
        (($event | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine),
        [Text.Encoding]::UTF8
    )
}
function Start-Engine {
    Stop-ExistingEngine
    Publish-State (Update-Plant)
    $serialLog = Join-Path $script:sessionRoot 'serial.log'
    $protocolEvents = Join-Path $script:sessionRoot 'protocol-events.jsonl'
    $virtualMemory = Join-Path $script:sessionRoot 'memoria-ecu-virtual.json'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$engine`" -Scenario interactive -ScenarioFile `"$script:statePath`" -LogPath `"$serialLog`" -SessionLogPath `"$protocolEvents`" -MemoryPath `"$virtualMemory`""
    $script:engineProcess = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Write-LabEvent @{ type='emulator-restart'; log='serial.log'; protocolEvents='protocol-events.jsonl'; memory='memoria-ecu-virtual.json' }
}
function Start-NewSession {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:sessionRoot = Join-Path $sessionsRoot "sessao-$stamp"
    [IO.Directory]::CreateDirectory($script:sessionRoot) | Out-Null
    $script:sessionEventsPath = Join-Path $script:sessionRoot 'lab-events.jsonl'
    $script:statePath = Join-Path $script:sessionRoot 'estado-atual.json'
    $script:lastSnapshotAt = [DateTime]::MinValue
    $script:sessionStartedAt = [DateTime]::UtcNow
    [ordered]@{
        createdAt = [DateTimeOffset]::Now.ToString('o')
        purpose = 'Bancada virtual Omegas MP48: observacao controlada do ProgBase'
        safety = 'Somente ECU virtual. Nenhuma central fisica e acionada por esta sessao.'
        model = 'Modelo estatistico de bancada, baseado em padroes agregados. Nao e formula da ECU nem replay de uma sessao.'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:sessionRoot 'sessao.json') -Encoding UTF8
    Write-LabEvent @{ type='session-start'; session=(Split-Path $script:sessionRoot -Leaf) }
    Start-Engine
}
function Set-Mode([string]$Mode) {
    $controls.manualRpmEnabled.Checked=$false
    switch ($Mode) {
        'idle' { $controls.pedal.Value=0; $controls.brake.Value=0; $controls.load.Value=15; $controls.fuel.SelectedItem='CNG'; $script:plant.running=$true }
        'cruise' { $controls.pedal.Value=28; $controls.brake.Value=0; $controls.load.Value=35; $controls.fuel.SelectedItem='CNG'; $script:plant.running=$true }
        'accel' { $controls.pedal.Value=70; $controls.brake.Value=0; $controls.load.Value=60; $controls.fuel.SelectedItem='CNG'; $script:plant.running=$true }
        'cutoff' { $controls.pedal.Value=0; $controls.brake.Value=65; $controls.load.Value=30; $controls.fuel.SelectedItem='CNG'; $script:plant.running=$true }
        'autocal' { $controls.pedal.Value=22; $controls.brake.Value=0; $controls.load.Value=32; $controls.fuel.SelectedItem='CNG'; $controls.ambient.Value=25; $script:plant.running=$true }
    }
    Write-LabEvent @{ type='profile'; profile=$Mode }
    Publish-State (Update-Plant)
}
function Publish-OperatorChange([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($script:sessionRoot)) { return }
    # RPM fixada e um controle direto: ela nao deve esperar o proximo ciclo nem ser
    # substituida pela mediana do modelo comportamental.
    if ($Source -eq 'rpm' -and $controls.manualRpmEnabled.Checked) {
        $script:plant.rpm = [double]$controls.manualRpm.Value
    }
    $state = Update-Plant
    Publish-State $state
    Write-LabEvent @{ type='operator-input'; source=$Source; state=$state }
}
function Get-BehaviorTarget([string]$Fuel, [string]$State, [int]$RpmBin, [int]$LoadBin) {
    $candidates = @($script:behaviorBuckets | Where-Object { $_.fuel -eq $Fuel -and $_.state -eq $State })
    if ($candidates.Count -eq 0) { $candidates = @($script:behaviorBuckets | Where-Object { $_.fuel -eq $Fuel }) }
    if ($candidates.Count -eq 0) { return $null }
    return $candidates | Sort-Object @{Expression={ [Math]::Abs([int]$_.rpmBin-$RpmBin) + [Math]::Abs([int]$_.loadBin-$LoadBin) }}, @{Expression={ -[int]$_.count }} | Select-Object -First 1
}
function Get-ModelValue($Bucket, [string]$Name, [double]$Fallback, [double]$NoiseScale = 0.08) {
    if ($controls.coupling.SelectedItem -eq 'Livre') { return $Fallback }
    if ($null -eq $Bucket -or $null -eq $Bucket.values.$Name) { return $Fallback }
    $value = $Bucket.values.$Name
    $mid = [double]$value.median
    $span = [Math]::Max(0, [double]$value.p90 - [double]$value.p10)
    # Oscilacao lenta e deterministica: parece viva sem transformar o laboratorio em sorteio.
    $variation = switch ($controls.stabilityMode.SelectedItem) { 'Estavel' { 0.02 } 'Instavel' { 0.24 } default { $NoiseScale } }
    $phase = [Math]::Sin(($script:stateSequence + $Name.Length * 17) / 19.0)
    return $mid + ($phase * $span * $variation)
}
function Approach([double]$Current, [double]$Target, [double]$Rate, [double]$Dt) {
    return $Current + ($Target - $Current) * [Math]::Min(1, $Rate * $Dt)
}
function Update-Plant {
    $now=[DateTime]::UtcNow; $dt=[Math]::Min(0.4,[Math]::Max(0.02,($now-$script:lastTick).TotalSeconds)); $script:lastTick=$now
    $pedal=$controls.pedal.Value/100.0; $brake=$controls.brake.Value/100.0; $load=$controls.load.Value/100.0; $ambient=$controls.ambient.Value
    $fuel=$controls.fuel.SelectedItem.ToString()
    $modelFuel = if ($fuel -eq 'CNG') { 'CNG' } elseif ($fuel -eq 'PETROL') { 'PETROL' } else { 'TRANSITION' }
    if (-not $script:plant.running) {
        $state='OFF'; $rpmIntent=0; $loadIntent=0
    } else {
        $rpmIntent=[Math]::Max(780,[Math]::Min(6000,820+(4400*$pedal)+(700*$load*$pedal)-(2600*$brake)))
        if ($controls.manualRpmEnabled.Checked) { $rpmIntent = [double]$controls.manualRpm.Value }
        $loadIntent=[Math]::Max(.15,[Math]::Min(1.0,.27+(.72*$pedal)+(.20*$load)-(.16*$brake)))
        if($rpmIntent -gt 1200 -and $pedal -lt .02 -and $brake -gt .15){$state='CUTOFF'}
        elseif($rpmIntent -lt 1300 -and $loadIntent -lt .38){$state='IDLE'}
        elseif($loadIntent -lt .55 -and $rpmIntent -lt 3200){$state='CRUISE'}
        elseif($loadIntent -ge .70 -or $rpmIntent -ge 3200){$state='ACCEL'}else{$state='LOAD'}
    }
    $bucket=Get-BehaviorTarget $modelFuel $state ([Math]::Min(7,[int]($rpmIntent/750))) ([Math]::Min(5,[int]($loadIntent/.2)))
    $targetRpm=Get-ModelValue $bucket 'rpm' $rpmIntent .05
    if($state -eq 'OFF'){$targetRpm=0}
    if($script:plant.running -and $controls.manualRpmEnabled.Checked){$targetRpm=[double]$controls.manualRpm.Value}
    $targetMap=Get-ModelValue $bucket 'load_bar' $loadIntent .06
    $targetPetrol=Get-ModelValue $bucket 'petrol_ms' (1.8+(8.2*$targetMap)+(.0011*$targetRpm)) .06
    $targetGas=Get-ModelValue $bucket 'gas_ms_diagnostic' ($targetPetrol*1.35) .06
    # PowerShell nao aceita um `if` como argumento direto de funcao; decide a referencia antes.
    $pressureFallback = if($modelFuel -eq 'CNG'){ 2.05 - (.18 * $pedal) } else { 1.15 }
    $targetPressure=Get-ModelValue $bucket 'gas_pressure_abs_bar' $pressureFallback .03
    $targetWater=Get-ModelValue $bucket 'water_c' (86+(5*$load)) .015
    $targetGasC=Get-ModelValue $bucket 'gas_c' ($ambient+12) .02
    $targetCorrection=Get-ModelValue $bucket 'dynamic_correction' 0 .03
    if($state -eq 'CUTOFF' -or $state -eq 'OFF'){$targetPetrol=if($state -eq 'OFF'){0}else{[Math]::Min(.5,$targetPetrol)};$targetGas=0}
    if($modelFuel -eq 'PETROL'){$targetGas=0}; if($modelFuel -eq 'TRANSITION'){$targetGas*=.65}
    $script:plant.rpm=Approach $script:plant.rpm $targetRpm 2.4 $dt
    $script:plant.mapBar=Approach $script:plant.mapBar $targetMap 4.0 $dt
    $script:plant.petrolMs=Approach $script:plant.petrolMs $targetPetrol 5.0 $dt
    $script:plant.gasMs=Approach $script:plant.gasMs $targetGas 4.0 $dt
    $script:plant.pressureBar=Approach $script:plant.pressureBar $targetPressure .7 $dt
    $script:plant.waterC=Approach $script:plant.waterC $targetWater .035 $dt
    $script:plant.gasC=Approach $script:plant.gasC $targetGasC .08 $dt
    $script:plant.correction=Approach $script:plant.correction $targetCorrection 1.2 $dt
    if($modelFuel -eq 'CNG' -and $script:plant.rpm -gt 0){$script:plant.level=[Math]::Max(0,$script:plant.level-($dt*.0005*$script:plant.mapBar))}
    $rpm=[int][Math]::Round($script:plant.rpm); $map=[Math]::Round([Math]::Max(.15,[Math]::Min(1.45,$script:plant.mapBar)),3)
    $cutoff=($state -eq 'CUTOFF')
    $petrolMs=[Math]::Max(0,[Math]::Min(22.5,$script:plant.petrolMs)); $gasMs=[Math]::Max(0,[Math]::Min(38,$script:plant.gasMs))
    $stable=($modelFuel -eq 'CNG' -and $state -in @('CRUISE','LOAD') -and $script:plant.waterC -ge 60 -and ($script:plant.pressureBar-$map) -ge .5 -and $brake -lt .05)
    if($stable){if($null -eq $script:plant.stableSince){$script:plant.stableSince=$now}}else{$script:plant.stableSince=$null}
    $stableSeconds=if($null -eq $script:plant.stableSince){0}else{[int](($now-$script:plant.stableSince).TotalSeconds)}
    [ordered]@{ rpm=$rpm; petrolMs=[Math]::Round($petrolMs,2); gasMs=[Math]::Round($gasMs,2); mapBar=$map; pressureBar=[Math]::Round($script:plant.pressureBar,3); waterC=[int][Math]::Round($script:plant.waterC); gasC=[int][Math]::Round($script:plant.gasC); levelPercent=[int][Math]::Round($script:plant.level); dynamicCorrection=[int][Math]::Round($script:plant.correction); fuel=$fuel; cutoff=$cutoff; stable=$stable; stableSeconds=$stableSeconds; behaviorState=$state; manualRpm=$controls.manualRpmEnabled.Checked; requestedRpm=if($controls.manualRpmEnabled.Checked){[int]$controls.manualRpm.Value}else{0}; modelBucket=if($null -eq $bucket){'fallback'}else{"$($bucket.fuel)/$($bucket.state)/$($bucket.rpmBin)/$($bucket.loadBin)"}; modelStatus=$script:behaviorModelStatus }
}
function Publish-State($state) {
    [IO.Directory]::CreateDirectory((Split-Path $script:statePath -Parent)) | Out-Null
    $script:stateSequence++
    $state['sequence'] = $script:stateSequence
    $state['publishedAt'] = [DateTimeOffset]::Now.ToString('o')
    $temp="$script:statePath.tmp"; $state | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8; Move-Item $temp $script:statePath -Force
    if (([DateTime]::UtcNow - $script:lastSnapshotAt).TotalSeconds -ge 1) {
        Write-LabEvent @{ type='state-snapshot'; state=$state }
        $script:lastSnapshotAt = [DateTime]::UtcNow
    }
}
function Read-JsonLines([string]$Path) {
    $items = @()
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) { try { $items += ($line | ConvertFrom-Json) } catch {} }
    return $items
}
function Get-ProtocolSummary {
    if ([string]::IsNullOrWhiteSpace($script:sessionRoot) -or (([DateTime]::UtcNow - $script:lastProtocolScanAt).TotalSeconds -lt 1)) { return $script:lastProtocolSummary }
    $script:lastProtocolScanAt = [DateTime]::UtcNow
    $events = @(Read-JsonLines (Join-Path $script:sessionRoot 'protocol-events.jsonl'))
    $transactions = @($events | Where-Object { $_.type -eq 'transaction' })
    $last = $transactions | Select-Object -Last 1
    $unknown = @($transactions | Where-Object { $_.source -eq 'generic-ack' }).Count
    if ($null -eq $last) {
        $script:lastProtocolSummary = [ordered]@{ last='Aguardando a primeira leitura do ProgBase'; source=''; transactions=0; unknown=0 }
    } else {
        $description = if ($last.request -like '29 61 01*') { 'Leitura da Curva K (MUL_ACT)' } elseif ($last.request -like '48 01 49*') { 'Leitura de telemetria' } elseif ($last.source -eq 'generic-ack') { 'Comando ainda nao mapeado' } else { 'Leitura ou resposta do protocolo' }
        $script:lastProtocolSummary = [ordered]@{ last=$description; source=$last.source; transactions=$transactions.Count; unknown=$unknown }
    }
    return $script:lastProtocolSummary
}
function Add-QuickMarker([string]$Note) {
    $state=Update-Plant; Publish-State $state
    Write-LabEvent @{type='marker'; note=$Note; state=$state}
    $noteBox.Text=$Note
}
function Write-SessionSummary {
    if ([string]::IsNullOrWhiteSpace($script:sessionRoot)) { return }
    $labEvents = @(Read-JsonLines $script:sessionEventsPath)
    $protocolEvents = @(Read-JsonLines (Join-Path $script:sessionRoot 'protocol-events.jsonl'))
    $transactions = @($protocolEvents | Where-Object { $_.type -eq 'transaction' })
    $unknown = @($transactions | Where-Object { $_.source -eq 'generic-ack' })
    $virtualWrites = @($transactions | Where-Object { $_.source -eq 'virtual-write' })
    $virtualResets = @($transactions | Where-Object { $_.source -eq 'virtual-autocal-reset' })
    $requests = @($transactions | Group-Object request | Sort-Object Count -Descending | Select-Object -First 40)
    $markers = @($labEvents | Where-Object { $_.type -eq 'marker' })
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Resumo da sessao Omegas Lab'); $lines.Add('')
    $lines.Add("- Pasta: ``$script:sessionRoot``")
    $lines.Add("- Transacoes decodificadas: $($transactions.Count)")
    $lines.Add("- Pedidos distintos: $($requests.Count)")
    $lines.Add("- Alteracoes manuais mantidas na ECU virtual: $($virtualWrites.Count)")
    $lines.Add("- Resets AutoCal aplicados na ECU virtual: $($virtualResets.Count)")
    $lines.Add("- Pedidos sem resposta observada (ACK generico): $($unknown.Count)"); $lines.Add('')
    $lines.Add('## Marcadores do experimento')
    if ($markers.Count -eq 0) { $lines.Add('- Nenhum marcador manual foi criado.') } else { foreach($marker in $markers) { $lines.Add("- $($marker.timestamp): $($marker.note)") } }
    $lines.Add(''); $lines.Add('## Pedidos mais frequentes'); $lines.Add('')
    $lines.Add('| Pedido do ProgBase | Vezes |'); $lines.Add('|---|---:|')
    foreach ($entry in $requests) { $lines.Add("| ``$($entry.Name)`` | $($entry.Count) |") }
    $lines.Add(''); $lines.Add('## Como interpretar'); $lines.Add('')
    $lines.Add('- `observed`: resposta baseada em um par encontrado nos logs reais.')
    $lines.Add('- `scenario-interactive`: telemetria formada pelo estado desta bancada.')
    $lines.Add('- `virtual-write`: alteracao manual da Curva K ou do Mapa K guardada somente na memoria da ECU virtual.')
    $lines.Add('- `virtual-autocal-reset`: limpeza virtual dos buffers AutoCal. A acao foi entendida e aplicada no estado da bancada.')
    $lines.Add('- `generic-ack`: pedido ainda sem resposta real mapeada. E uma lacuna para investigar, nao um dado da ECU.')
    [IO.File]::WriteAllLines((Join-Path $script:sessionRoot 'RESUMO.md'), $lines, [Text.Encoding]::UTF8)
}

$form=New-Object Windows.Forms.Form
$form.Text='Omegas Lab - ECU MP48 | bancada virtual'
$form.ClientSize='1235,755'; $form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI',9)
$form.BackColor=[Drawing.Color]::FromArgb(20,24,32); $form.ForeColor=[Drawing.Color]::White
$controls=@{}; $script:activeSurface=$form
$title=Add-Label 'OMEGAS LAB' 20 13 230 32 (New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold))
$topStatus=Add-Label '● ECU virtual: preparando     ■ ProgBase: aguardando' 260 18 700 28 (New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)); $topStatus.ForeColor=[Drawing.Color]::LightSkyBlue
$elapsedLabel=Add-Label 'Sessao: 00:00:00' 1000 20 210 24; $elapsedLabel.TextAlign='MiddleRight'
$evidence=Add-Label 'Bancada segura: somente ECU virtual. Os registros da sessao ficam juntos e as respostas mantem sua origem.' 20 51 1180 24; $evidence.ForeColor=[Drawing.Color]::Khaki

$controlPane=New-Object Windows.Forms.GroupBox; $controlPane.Text='CONTROLE - o que voce quer provocar'; $controlPane.Location='20,85'; $controlPane.Size='340,565'; $controlPane.ForeColor=[Drawing.Color]::LightSkyBlue; $form.Controls.Add($controlPane)
$motorPane=New-Object Windows.Forms.GroupBox; $motorPane.Text='MOTOR VIRTUAL - o que esta sendo produzido'; $motorPane.Location='375,85'; $motorPane.Size='450,565'; $motorPane.ForeColor=[Drawing.Color]::LightSkyBlue; $form.Controls.Add($motorPane)
$experimentPane=New-Object Windows.Forms.GroupBox; $experimentPane.Text='ENSAIO - comunicacao e marcadores'; $experimentPane.Location='840,85'; $experimentPane.Size='375,565'; $experimentPane.ForeColor=[Drawing.Color]::LightSkyBlue; $form.Controls.Add($experimentPane)

$script:activeSurface=$controlPane
$fuelLabel=Add-Label 'Combustivel solicitado' 18 28 160
$fuel=New-Object Windows.Forms.ComboBox; $fuel.Items.AddRange(@('CNG','PETROL','TRANSITION')); $fuel.SelectedItem='CNG'; $fuel.DropDownStyle='DropDownList'; $fuel.Location='175,24'; $fuel.Size='145,28'; $controlPane.Controls.Add($fuel); $controls.fuel=$fuel
Add-Slider 'pedal' 'Pedal - intencao' 0 100 0 18 72 '%'
Add-Slider 'load' 'Carga - esforco' 0 100 15 18 117 '%'
Add-Slider 'brake' 'Freio do motor' 0 100 0 18 162 '%'
$manualRpmEnabled=New-Object Windows.Forms.CheckBox; $manualRpmEnabled.Text='Fixar RPM'; $manualRpmEnabled.Location='18,211'; $manualRpmEnabled.Size='100,28'; $manualRpmEnabled.ForeColor=[Drawing.Color]::Khaki; $controlPane.Controls.Add($manualRpmEnabled); $controls.manualRpmEnabled=$manualRpmEnabled
$manualRpm=New-Object Windows.Forms.TrackBar; $manualRpm.Minimum=800; $manualRpm.Maximum=6000; $manualRpm.Value=1800; $manualRpm.TickFrequency=400; $manualRpm.AutoSize=$false; $manualRpm.Location='104,207'; $manualRpm.Size='175,32'; $manualRpm.Enabled=$false; $controlPane.Controls.Add($manualRpm); $controls.manualRpm=$manualRpm
$manualRpmReadout=Add-Label '1.800 rpm' 220 214 105
$manualRpm.Add_ValueChanged({ $manualRpmReadout.Text=('{0:N0} rpm' -f $manualRpm.Value); Publish-OperatorChange 'rpm' }.GetNewClosure())
$manualRpmEnabled.Add_CheckedChanged({ $manualRpm.Enabled=$manualRpmEnabled.Checked; $manualRpmReadout.ForeColor=if($manualRpmEnabled.Checked){[Drawing.Color]::Khaki}else{[Drawing.Color]::Gainsboro}; Publish-OperatorChange 'rpm-mode'; Write-LabEvent @{type='manual-rpm'; enabled=$manualRpmEnabled.Checked; requestedRpm=$manualRpm.Value} }.GetNewClosure())
$couplingLabel=Add-Label 'Acoplamento' 18 258 120
$coupling=New-Object Windows.Forms.ComboBox; $coupling.Items.AddRange(@('Coerente','Assistido','Livre')); $coupling.SelectedItem='Coerente'; $coupling.DropDownStyle='DropDownList'; $coupling.Location='135,254'; $coupling.Size='185,28'; $controlPane.Controls.Add($coupling); $controls.coupling=$coupling
$stabilityModeLabel=Add-Label 'Comportamento' 18 298 120
$stabilityMode=New-Object Windows.Forms.ComboBox; $stabilityMode.Items.AddRange(@('Estavel','Natural','Instavel')); $stabilityMode.SelectedItem='Natural'; $stabilityMode.DropDownStyle='DropDownList'; $stabilityMode.Location='135,294'; $stabilityMode.Size='185,28'; $controlPane.Controls.Add($stabilityMode); $controls.stabilityMode=$stabilityMode
$controls.pedal.Add_ValueChanged({ Publish-OperatorChange 'pedal' })
$controls.load.Add_ValueChanged({ Publish-OperatorChange 'carga' })
$controls.brake.Add_ValueChanged({ Publish-OperatorChange 'freio' })
$fuel.Add_SelectedIndexChanged({ Publish-OperatorChange 'combustivel' })
$coupling.Add_SelectedIndexChanged({ Publish-OperatorChange 'acoplamento' })
$stabilityMode.Add_SelectedIndexChanged({ Publish-OperatorChange 'estabilidade' })
$controlHelp=Add-Label 'Coerente: segue os padroes observados.`nAssistido: mantem sua RPM e adapta os demais sinais.`nLivre: usa estimativas sem exigir um padrao completo.' 18 335 300 65; $controlHelp.ForeColor=[Drawing.Color]::Silver
$scenarioLabel=Add-Label 'Cenarios prontos' 18 417 180 22 (New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold))
$profiles=@(@('Marcha lenta','idle'),@('Cruzeiro','cruise'),@('Aceleracao','accel'),@('Cutoff','cutoff'),@('Janela AutoCal','autocal'))
$x=18;$y=448;foreach($entry in $profiles){$b=New-Object Windows.Forms.Button;$b.Text=$entry[0];$b.Location="$x,$y";$b.Size='94,31';$mode=$entry[1];$b.Add_Click(({Set-Mode $mode}).GetNewClosure());$controlPane.Controls.Add($b);$x+=100;if($x -gt 220){$x=18;$y+=37}}

$script:activeSurface=$motorPane
$rpmHeadline=Add-Label '--- RPM' 18 28 410 55 (New-Object Drawing.Font('Segoe UI',27,[Drawing.FontStyle]::Bold)); $rpmHeadline.TextAlign='MiddleCenter'; $rpmHeadline.ForeColor=[Drawing.Color]::White
$motorSummary=Add-Label '' 22 94 400 130 (New-Object Drawing.Font('Consolas',11)); $motorSummary.ForeColor=[Drawing.Color]::Gainsboro
$coherenceTitle=Add-Label 'Coerencia do cenario' 22 240 180 22 (New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold))
$coherence=Add-Label '' 22 266 400 45; $coherence.ForeColor=[Drawing.Color]::LightGreen
$modelDescription=Add-Label '' 22 325 400 60; $modelDescription.ForeColor=[Drawing.Color]::LightSteelBlue
$stability=New-Object Windows.Forms.ProgressBar; $stability.Location='22,410'; $stability.Size='400,22'; $stability.Maximum=5; $motorPane.Controls.Add($stability)
$stabilityLabel=Add-Label 'AutoCal: aguardando condicao estavel' 22 439 400 24
$modelNotice=Add-Label 'Modelo de bancada: nao e formula da ECU.' 22 490 400 24; $modelNotice.ForeColor=[Drawing.Color]::Khaki

$script:activeSurface=$experimentPane
$connectionStatus=Add-Label 'ECU virtual: preparando' 18 30 330 24 (New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)); $connectionStatus.ForeColor=[Drawing.Color]::LightSkyBlue
$progbaseStatus=Add-Label 'ProgBase: aguardando primeira leitura' 18 60 330 24
$lastActionTitle=Add-Label 'Ultima acao observada' 18 101 300 22 (New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold))
$lastAction=Add-Label 'Aguardando atividade.' 18 128 330 48; $lastAction.ForeColor=[Drawing.Color]::Gainsboro
$noteLabel=Add-Label 'O que voce fez no ProgBase?' 18 190 320 22
$noteBox=New-Object Windows.Forms.TextBox; $noteBox.Location='18,215'; $noteBox.Size='335,27'; $experimentPane.Controls.Add($noteBox)
$markButton=New-Object Windows.Forms.Button; $markButton.Text='Registrar marcador'; $markButton.Location='18,250'; $markButton.Size='160,31'; $experimentPane.Controls.Add($markButton)
$quickPre=New-Object Windows.Forms.Button; $quickPre.Text='Antes'; $quickPre.Location='190,250'; $quickPre.Size='50,31'; $experimentPane.Controls.Add($quickPre)
$quickAction=New-Object Windows.Forms.Button; $quickAction.Text='Acao'; $quickAction.Location='245,250'; $quickAction.Size='50,31'; $experimentPane.Controls.Add($quickAction)
$quickAfter=New-Object Windows.Forms.Button; $quickAfter.Text='Depois'; $quickAfter.Location='300,250'; $quickAfter.Size='53,31'; $experimentPane.Controls.Add($quickAfter)
$timelineTitle=Add-Label 'Cronologia desta sessao' 18 300 320 22 (New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold))
$timeline=Add-Label 'Sessao iniciando...' 18 328 335 100; $timeline.ForeColor=[Drawing.Color]::Silver
$sessionLabel=Add-Label 'Sessao: preparando...' 18 455 335 46; $sessionLabel.ForeColor=[Drawing.Color]::DarkGray
$openSessionButton=New-Object Windows.Forms.Button; $openSessionButton.Text='Abrir arquivos da sessao'; $openSessionButton.Location='18,510'; $openSessionButton.Size='165,31'; $experimentPane.Controls.Add($openSessionButton)
$newSessionButton=New-Object Windows.Forms.Button; $newSessionButton.Text='Novo ensaio'; $newSessionButton.Location='190,510'; $newSessionButton.Size='163,31'; $experimentPane.Controls.Add($newSessionButton)

$script:activeSurface=$form
$footer=Add-Label 'BANCADA   |   Cenarios e telemetria ficam nesta tela. Os detalhes tecnicos continuam registrados nos arquivos da sessao.' 20 675 1195 24; $footer.ForeColor=[Drawing.Color]::Gray
$status=Add-Label 'ECU: iniciando...' 20 710 1190 26; $status.ForeColor=[Drawing.Color]::LightSteelBlue

$engineButton=New-Object Windows.Forms.Button; $engineButton.Text='Ligar motor'; $engineButton.Location='20,635'; $engineButton.Size='130,31'; $form.Controls.Add($engineButton)
$restartButton=New-Object Windows.Forms.Button; $restartButton.Text='Reiniciar ECU virtual'; $restartButton.Location='160,635'; $restartButton.Size='160,31'; $form.Controls.Add($restartButton)

$engineButton.Add_Click({
    $script:plant.running=-not $script:plant.running
    if ($script:plant.running) { $script:plant.rpm = [Math]::Max(820, $script:plant.rpm) } else { $script:plant.rpm = 0 }
    $engineButton.Text=if($script:plant.running){'Desligar motor'}else{'Ligar motor'}
    $state=Update-Plant; Publish-State $state
    Write-LabEvent @{type='engine-toggle'; running=$script:plant.running; state=$state}
})
$restartButton.Add_Click({Start-Engine; $status.Text='ECU virtual reiniciada com o estado atual da bancada.'})
$markButton.Add_Click({ $note=$noteBox.Text.Trim(); if([string]::IsNullOrWhiteSpace($note)){$note='Marcador sem descricao'}; Add-QuickMarker $note; $noteBox.Clear(); $status.Text='Marcador salvo nesta sessao.' })
$quickPre.Add_Click({Add-QuickMarker 'Antes da acao no ProgBase'})
$quickAction.Add_Click({Add-QuickMarker 'Acao executada no ProgBase'})
$quickAfter.Add_Click({Add-QuickMarker 'Depois da acao no ProgBase'})
$newSessionButton.Add_Click({ Write-SessionSummary; Start-NewSession; $status.Text='Novo ensaio iniciado.' })
$openSessionButton.Add_Click({ if(-not [string]::IsNullOrWhiteSpace($script:sessionRoot)){Start-Process explorer.exe -ArgumentList "`"$script:sessionRoot`""} })
$timer=New-Object Windows.Forms.Timer; $timer.Interval=120
$timer.Add_Tick({
    $state=Update-Plant; Publish-State $state; $protocol=Get-ProtocolSummary
    $rpmControl=if($state.manualRpm){"fixada em $($state.requestedRpm) rpm"}else{'dinamica'}
    $rpmHeadline.Text=('{0:N0} RPM' -f $state.rpm)
    $ratio=if($state.petrolMs -gt 0){[Math]::Round($state.gasMs/$state.petrolMs,2)}else{0}
    $differential=[Math]::Round($state.pressureBar-$state.mapBar,2)
    $motorSummary.Text="MAP                 $($state.mapBar) bar`nGasolina            $($state.petrolMs) ms`nGNV                 $($state.gasMs) ms`nRelacao GNV/Gas     $ratio x`nPressao diferencial $differential bar`nAgua $($state.waterC) C     Gas $($state.gasC) C"
    if($state.modelBucket -eq 'fallback' -or $controls.coupling.SelectedItem -eq 'Livre'){$coherence.Text='LIMITADA - alguns valores estao sendo estimados.';$coherence.ForeColor=[Drawing.Color]::Khaki;$modelDescription.Text='Nao foi encontrado um padrao completo para esta combinacao.'}else{$coherence.Text='ALTA - sinais formados por um padrao compativel.';$coherence.ForeColor=[Drawing.Color]::LightGreen;$modelDescription.Text="Padrao: $($state.behaviorState) / $($state.fuel)`nRPM: $rpmControl   |   Base: $($state.modelBucket)"}
    $stability.Value=[Math]::Min(5,$state.stableSeconds)
    $stabilityLabel.Text=if($state.stable){"AutoCal: estavel ha $($state.stableSeconds) s"}else{'AutoCal: fora da janela de estabilidade'}
    $online=($null -ne $script:engineProcess -and -not $script:engineProcess.HasExited)
    $connectionStatus.Text=if($online){'● ECU virtual: ATIVA - porta omegas-ecu'}else{'■ ECU virtual: OFFLINE'}; $connectionStatus.ForeColor=if($online){[Drawing.Color]::LightGreen}else{[Drawing.Color]::Tomato}
    $progbaseStatus.Text=if($protocol.transactions -gt 0){"● ProgBase: atividade observada ($($protocol.transactions) pedidos)"}else{'■ ProgBase: aguardando primeira leitura'}; $progbaseStatus.ForeColor=if($protocol.transactions -gt 0){[Drawing.Color]::LightGreen}else{[Drawing.Color]::Silver}
    $lastAction.Text="$($protocol.last)`nOrigem: $($protocol.source)    Desconhecidos: $($protocol.unknown)"
    $events=@(Read-JsonLines $script:sessionEventsPath | Where-Object {$_.type -in @('session-start','profile','marker','engine-toggle')} | Select-Object -Last 4)
    $timeline.Text=if($events.Count -eq 0){'Nenhum evento ainda.'}else{(($events | ForEach-Object { "$([datetimeoffset]$_.timestamp | ForEach-Object { $_.ToLocalTime().ToString('HH:mm:ss') })  $($_.type): $($_.note)$($_.profile)" }) -join "`n")}
    $sessionLabel.Text="Sessao: $(Split-Path $script:sessionRoot -Leaf)"
    $elapsed=if($null -eq $script:sessionStartedAt){[TimeSpan]::Zero}else{([DateTime]::UtcNow-$script:sessionStartedAt)}; $elapsedLabel.Text=('Sessao: {0:hh\:mm\:ss}' -f $elapsed)
    $topStatus.Text=if($online){"● ECU virtual: ATIVA     $(if($protocol.transactions -gt 0){'● ProgBase: CONECTADO'}else{'■ ProgBase: AGUARDANDO'})"}else{'■ ECU virtual: OFFLINE'}
    $status.Text="Estado: $($state.behaviorState) | Acoplamento: $($controls.coupling.SelectedItem) | Comportamento: $($controls.stabilityMode.SelectedItem) | Publicacao #$($state.sequence)"
})
$form.Add_Shown({Start-NewSession;$timer.Start()})
$form.Add_FormClosed({Write-LabEvent @{type='session-end'}; Write-SessionSummary; if($null -ne $script:engineProcess -and -not $script:engineProcess.HasExited){Stop-Process -Id $script:engineProcess.Id -Force -ErrorAction SilentlyContinue}})
[void]$form.ShowDialog()
