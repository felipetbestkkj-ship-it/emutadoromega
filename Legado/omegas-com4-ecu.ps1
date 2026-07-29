param([string]$PortName = 'COM4', [string]$LogPath = '.\build\captures\ecu-com4.log')

$ErrorActionPreference = 'Stop'
$log = [IO.Path]::GetFullPath($LogPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($log)) | Out-Null
function Log([string]$m) { [IO.File]::AppendAllText($log, "$(Get-Date -Format o) $m`r`n") }

$serial = [IO.Ports.SerialPort]::new($PortName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$serial.ReadTimeout = 1000
$serial.Open()
Log "ecu-emulator-open port=$PortName"
$buf = [byte[]]::new(256)
try {
  while ($serial.IsOpen) {
    try { $n = $serial.Read($buf, 0, $buf.Length) } catch [TimeoutException] { continue }
    if ($n -le 0) { continue }
    $rx = [BitConverter]::ToString($buf,0,$n).Replace('-',' ')
    Log "rx length=$n hex=$rx"
    $serial.Write($buf,0,$n)
    $serial.Write([byte[]](0x53),0,1)
    Log "tx echo=$rx ack=53"
  }
}
finally { if ($serial.IsOpen) {$serial.Close()}; Log 'ecu-emulator-close' }
