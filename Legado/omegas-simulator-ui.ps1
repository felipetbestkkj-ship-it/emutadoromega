Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
$engine = Join-Path $PSScriptRoot 'omegas-mp48-ecu.ps1'
$statePath = Join-Path $root 'build\captures\omegas-interactive-state.json'
$engineLog = Join-Path $root 'build\captures\omegas-mp48-ecu.log'
$script:engineProcess = $null

function Clamp([double]$Value, [double]$Min, [double]$Max) { [Math]::Max($Min, [Math]::Min($Max, $Value)) }
function Save-State {
    $state = [ordered]@{
        rpm = $controls.rpm.Value
        petrolMs = [Math]::Round($controls.petrol.Value / 10.0, 1)
        gasMs = [Math]::Round($controls.gas.Value / 10.0, 1)
        mapBar = [Math]::Round($controls.map.Value / 100.0, 2)
        pressureBar = [Math]::Round($controls.pressure.Value / 100.0, 2)
        waterC = $controls.water.Value
        gasC = $controls.gasTemp.Value
        levelPercent = $controls.level.Value
        dynamicCorrection = $controls.correction.Value
        fuel = $controls.fuel.SelectedItem.ToString()
    }
    $dir = Split-Path $statePath -Parent
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $temporary = "$statePath.tmp"
    $state | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
    $summary.Text = "RPM $($state.rpm)  |  $($state.fuel)  |  Gas $($state.gasMs) ms  |  Gasolina $($state.petrolMs) ms  |  MAP $($state.mapBar) bar"
}

function Set-Profile([string]$Name) {
    switch ($Name) {
        'Motor desligado' { $controls.rpm.Value=0; $controls.gas.Value=0; $controls.petrol.Value=0; $controls.map.Value=20; $controls.fuel.SelectedItem='PETROL' }
        'Marcha lenta GNV' { $controls.rpm.Value=850; $controls.gas.Value=41; $controls.petrol.Value=36; $controls.map.Value=40; $controls.pressure.Value=200; $controls.fuel.SelectedItem='CNG' }
        'Carga estável' { $controls.rpm.Value=2500; $controls.gas.Value=61; $controls.petrol.Value=54; $controls.map.Value=90; $controls.pressure.Value=238; $controls.fuel.SelectedItem='CNG' }
        'Cutoff' { $controls.rpm.Value=3200; $controls.gas.Value=0; $controls.petrol.Value=3; $controls.map.Value=25; $controls.pressure.Value=188; $controls.fuel.SelectedItem='CNG' }
        'Transição' { $controls.rpm.Value=1800; $controls.gas.Value=31; $controls.petrol.Value=42; $controls.map.Value=55; $controls.pressure.Value=219; $controls.fuel.SelectedItem='TRANSITION' }
    }
    Save-State
}

function Stop-ExistingEngine {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*omegas-mp48-ecu.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Engine {
    Stop-ExistingEngine
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$engine`" -Scenario interactive -ScenarioFile `"$statePath`""
    $script:engineProcess = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $start.Text = 'Reiniciar ECU simulada'
    $status.Text = 'Estado: iniciando ECU interativa na porta omegas-ecu...'
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Omegas MP48 — Central de Simulação'
$form.ClientSize = New-Object Drawing.Size(760, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.BackColor = [Drawing.Color]::FromArgb(24, 28, 36)
$form.ForeColor = [Drawing.Color]::White

$title = New-Object Windows.Forms.Label
$title.Text = 'ECU MP48 simulada — bancada virtual'
$title.Location = '20,15'; $title.Size = '700,30'; $title.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$summary = New-Object Windows.Forms.Label
$summary.Location = '20,50'; $summary.Size = '720,25'; $summary.ForeColor = [Drawing.Color]::FromArgb(130, 220, 255)
$form.Controls.Add($summary)

$controls = @{}
$definitions = @(
    @{ key='rpm'; label='RPM'; min=0; max=6000; value=850; suffix=' rpm' },
    @{ key='petrol'; label='Injeção gasolina'; min=0; max=150; value=36; suffix=' ms ÷ 10' },
    @{ key='gas'; label='Injeção GNV'; min=0; max=180; value=41; suffix=' ms ÷ 10' },
    @{ key='map'; label='MAP / carga'; min=0; max=150; value=40; suffix=' bar ÷ 100' },
    @{ key='pressure'; label='Pressão GNV absoluta'; min=0; max=350; value=200; suffix=' bar ÷ 100' },
    @{ key='water'; label='Temperatura água'; min=-20; max=120; value=90; suffix=' °C' },
    @{ key='gasTemp'; label='Temperatura GNV'; min=-20; max=100; value=35; suffix=' °C' },
    @{ key='level'; label='Nível GNV'; min=0; max=100; value=68; suffix=' %' },
    @{ key='correction'; label='Byte dinâmico 19'; min=0; max=255; value=0; suffix='' }
)
$y = 92
foreach ($definition in $definitions) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $definition.label; $label.Location = "20,$y"; $label.Size = '190,23'
    $form.Controls.Add($label)
    $bar = New-Object Windows.Forms.TrackBar
    $bar.Minimum=$definition.min; $bar.Maximum=$definition.max; $bar.Value=$definition.value; $bar.TickFrequency=[Math]::Max(1,[int](($definition.max-$definition.min)/10))
    $bar.Location = "205,$($y-5)"; $bar.Size='410,35'; $bar.AutoSize=$false
    $value = New-Object Windows.Forms.Label
    $value.Location="625,$y"; $value.Size='115,23'
    $renderValue = { $value.Text = "$($bar.Value)$($definition.suffix)" }.GetNewClosure()
    $refreshValue = { & $renderValue; Save-State }.GetNewClosure()
    $bar.Add_ValueChanged($refreshValue)
    $controls[$definition.key]=$bar
    $form.Controls.Add($bar); $form.Controls.Add($value)
    & $renderValue
    $y += 42
}

$fuelLabel = New-Object Windows.Forms.Label
$fuelLabel.Text='Combustível'; $fuelLabel.Location="20,$y"; $fuelLabel.Size='180,25'; $form.Controls.Add($fuelLabel)
$fuel = New-Object Windows.Forms.ComboBox
$fuel.Items.AddRange(@('CNG','PETROL','TRANSITION')); $fuel.SelectedItem='CNG'; $fuel.DropDownStyle='DropDownList'; $fuel.Location="205,$($y-4)"; $fuel.Size='170,28'; $fuel.Add_SelectedIndexChanged({ Save-State }); $controls.fuel=$fuel; $form.Controls.Add($fuel)

$profiles = @('Motor desligado','Marcha lenta GNV','Carga estável','Cutoff','Transição')
$x=20
foreach ($profile in $profiles) {
    $button = New-Object Windows.Forms.Button
    $button.Text=$profile; $button.Location="$x,$($y+42)"; $button.Size='135,34'; $button.FlatStyle='Flat'
    $copy = $profile; $button.Add_Click(({ Set-Profile $copy }).GetNewClosure()); $form.Controls.Add($button); $x += 142
}

$ramp = New-Object Windows.Forms.CheckBox
$ramp.Text='Rampa de aceleração'; $ramp.Location="20,$($y+90)"; $ramp.Size='180,28'; $form.Controls.Add($ramp)
$start = New-Object Windows.Forms.Button
$start.Text='Iniciar simulador'; $start.Location="500,$($y+84)"; $start.Size='200,38'; $start.FlatStyle='Flat'; $form.Controls.Add($start)
$status = New-Object Windows.Forms.Label
$status.Text='Estado: controles prontos. Inicie o simulador e conecte o Omegas na VM.'; $status.Location="20,$($y+130)"; $status.Size='700,28'; $form.Controls.Add($status)

$timer = New-Object Windows.Forms.Timer
$timer.Interval=250
$timer.Add_Tick({
    if ($ramp.Checked) {
        $controls.rpm.Value = [Math]::Min(5500, $controls.rpm.Value + 150)
        $controls.map.Value = [Math]::Min(145, $controls.map.Value + 4)
        $controls.gas.Value = [Math]::Min(170, $controls.gas.Value + 5)
        $controls.petrol.Value = [Math]::Min(145, $controls.petrol.Value + 4)
    }
})
$timer.Add_Tick({
    if ($null -ne $script:engineProcess) {
        if ($script:engineProcess.HasExited) {
            $status.Text = 'Estado: ECU OFFLINE. Clique em Reiniciar ECU simulada.'
            $status.ForeColor = [Drawing.Color]::Tomato
        } else {
            $status.Text = 'Estado: ECU ONLINE na porta omegas-ecu. Conecte o Omegas na VM.'
            $status.ForeColor = [Drawing.Color]::LightGreen
        }
    }
})
$timer.Start()
$start.Add_Click({ Start-Engine })
$form.Add_Shown({ Save-State; Start-Engine })
$form.Add_FormClosed({
    if ($null -ne $script:engineProcess -and -not $script:engineProcess.HasExited) {
        Stop-Process -Id $script:engineProcess.Id -Force -ErrorAction SilentlyContinue
    }
})
[void]$form.ShowDialog()
