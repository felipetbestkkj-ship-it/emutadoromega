param(
    [string]$PipeName = 'omegas-ecu',
    [string]$LogPath = (Join-Path $PSScriptRoot '..\build\captures\progbase-serial.log')
)

$ErrorActionPreference = 'Stop'
$resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
$logDirectory = [System.IO.Path]::GetDirectoryName($resolvedLogPath)
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null

function Write-CaptureLine {
    param([string]$Message)

    $timestamp = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    [System.IO.File]::AppendAllText(
        $resolvedLogPath,
        "$timestamp $Message$([Environment]::NewLine)",
        [System.Text.Encoding]::UTF8
    )
}

Write-CaptureLine "capture-start pipe=\\.\pipe\$PipeName"

$pipeSecurity = [System.IO.Pipes.PipeSecurity]::new()
$world = [System.Security.Principal.SecurityIdentifier]::new(
    [System.Security.Principal.WellKnownSidType]::WorldSid,
    $null
)
$pipeSecurity.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
    $world,
    [System.IO.Pipes.PipeAccessRights]::ReadWrite,
    [System.Security.AccessControl.AccessControlType]::Allow
))

while ($true) {
    $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::None
        ,4096,4096,$pipeSecurity
    )

    try {
        $pipe.WaitForConnection()
        Write-CaptureLine 'connected'
        $buffer = [byte[]]::new(4096)

        while ($pipe.IsConnected) {
            $count = $pipe.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) {
                break
            }

            $hex = [BitConverter]::ToString($buffer, 0, $count).Replace('-', ' ')
            Write-CaptureLine "rx length=$count hex=$hex"

            # Minimal ECU behavior: acknowledge each request so ProgBase advances
            # through its discovery sequence. Payloads are added only after the
            # real request/response pairs are observed in the capture.
            $pipe.Write($buffer, 0, $count)
            $pipe.Flush()
            Write-CaptureLine "tx length=$count hex=$hex"
            $ack = [byte[]](0x53)
            $pipe.Write($ack, 0, $ack.Length)
            $pipe.Flush()
            Write-CaptureLine 'tx length=1 hex=53'
        }
    }
    catch [TimeoutException] {
        # The VMware pipe is not available yet. Retry without filling the log.
    }
    catch {
        Write-CaptureLine "error=$($_.Exception.Message)"
    }
    finally {
        $pipe.Dispose()
    }

    Write-CaptureLine 'disconnected'
    Start-Sleep -Milliseconds 500
}
