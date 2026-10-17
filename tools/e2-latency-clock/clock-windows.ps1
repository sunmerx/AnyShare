<#
.SYNOPSIS
    E-2 glass-to-glass latency measurement rig (Windows side).

.DESCRIPTION
    Opens two synchronized millisecond clocks:
      * reference clock on the primary (physical) screen - visible to a camera
      * stream clock on the virtual display (VDD) - captured and streamed to the
        target device
    Take one phone photo containing BOTH screens; the difference between the two
    clock readings is the end-to-end (glass-to-glass) latency of the pipeline.

.PARAMETER VirtualScreenIndex
    Screen index (as reported by [System.Windows.Forms.Screen]::AllScreens) of the
    virtual display. Default -1 picks the smallest screen automatically.

.PARAMETER Seconds
    0 = run until Ctrl+C / window closed. Otherwise auto-close after N seconds.

.EXAMPLE
    powershell -sta -File clock-windows.ps1
    powershell -sta -File clock-windows.ps1 -VirtualScreenIndex 2 -Seconds 120
#>
param(
    [int]$VirtualScreenIndex = -1,
    [int]$Seconds = 0
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

if ($Seconds -lt 0 -or $Seconds -gt 2147483) {
    Fail "-Seconds must be 0 (run forever) or 1..2147483."
}

$screens = [System.Windows.Forms.Screen]::AllScreens

$autoPicked = $false
if ($VirtualScreenIndex -lt 0) {
    $virtual = $screens | Sort-Object { $_.Bounds.Width * $_.Bounds.Height } | Select-Object -First 1
    $autoPicked = $true
} else {
    if ($VirtualScreenIndex -ge $screens.Count) {
        Fail "VirtualScreenIndex $VirtualScreenIndex out of range (0..$($screens.Count - 1))."
    }
    $virtual = $screens[$VirtualScreenIndex]
}

$reference = $screens | Where-Object { $_.Primary } | Select-Object -First 1
if (-not $reference) {
    $reference = $screens | Where-Object { $_.DeviceName -ne $virtual.DeviceName } | Select-Object -First 1
}
if (-not $reference) {
    Fail "No reference (physical) screen found - need at least two screens (primary + virtual)."
}
if ($reference.DeviceName -eq $virtual.DeviceName) {
    Fail "Reference and virtual screens resolve to the same display ($($reference.DeviceName)). Pass -VirtualScreenIndex explicitly (run without args to list screens)."
}

$width = 640
$height = 200

function New-ClockWindow {
    param(
        [System.Drawing.Rectangle]$ScreenBounds,
        [string]$Title
    )

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::Black
    $form.Text = $Title
    $x = $ScreenBounds.X + [int](($ScreenBounds.Width - $width) / 2)
    $y = $ScreenBounds.Y + 40
    $form.Bounds = New-Object System.Drawing.Rectangle($x, $y, $width, $height)

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 128)
    $label.BackColor = [System.Drawing.Color]::Black
    $label.Font = New-Object System.Drawing.Font('Consolas', 44, [System.Drawing.FontStyle]::Bold)
    $label.Text = '--:--:--.---'
    $form.Controls.Add($label)

    @{ Form = $form; Label = $label }
}

$refWindow = New-ClockWindow -ScreenBounds $reference.Bounds -Title 'E2 latency REFERENCE (physical)'
$strWindow = New-ClockWindow -ScreenBounds $virtual.Bounds -Title 'E2 latency STREAM (virtual display)'

# Closing EITHER window ends the tool.
$refWindow.Form.Add_FormClosed({ [System.Windows.Forms.Application]::Exit() })
$strWindow.Form.Add_FormClosed({ $refWindow.Form.Close() })

# Escape closes the reference window (Ctrl+C does not reliably reach the message loop).
$refWindow.Form.KeyPreview = $true
$refWindow.Form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $sender.Close()
    }
})

Write-Host ""
if ($autoPicked) {
    Write-Host "WARNING: virtual display auto-picked as the SMALLEST screen - verify it is really the VDD screen!" -ForegroundColor Red
    Write-Host "         If wrong, rerun with -VirtualScreenIndex <n>." -ForegroundColor Red
}
Write-Host "reference screen : $($reference.DeviceName) $($reference.Bounds)" -ForegroundColor Cyan
Write-Host "virtual screen   : $($virtual.DeviceName) $($virtual.Bounds)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Procedure:" -ForegroundColor Yellow
Write-Host "  1. Start the video stream to the target device."
Write-Host "  2. Take ONE phone photo containing BOTH the physical screen and the target screen."
Write-Host "  3. The clock difference (target minus physical) is the glass-to-glass latency."
Write-Host "  4. Take 5+ photos, discard outliers (camera shutter/refresh beat), take the median."
Write-Host ""
Write-Host "Press Escape or close either window to stop." -ForegroundColor Yellow

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 16
$timer.Add_Tick({
    $now = (Get-Date).ToString('HH:mm:ss.fff')
    $refWindow.Label.Text = $now
    $strWindow.Label.Text = $now
})
$timer.Start()

if ($Seconds -gt 0) {
    $close = New-Object System.Windows.Forms.Timer
    $close.Interval = $Seconds * 1000
    $close.Add_Tick({
        $close.Stop()
        $refWindow.Form.Close()
    })
    $close.Start()
}

$strWindow.Form.Show()
[System.Windows.Forms.Application]::Run($refWindow.Form)
