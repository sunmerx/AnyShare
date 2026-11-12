param(
    [int]$OutputIndex = 2,
    [string]$UbuntuIp = '192.168.1.180',
    [int]$DurationSeconds = 60,
    [string]$Ffmpeg = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe"
)

Write-Host " Streaming VDD (output_idx=$OutputIndex) -> ${UbuntuIp}:53319 for ${DurationSeconds}s"
Write-Host " Tip: identify the VDD output index by capturing single frames:"
Write-Host "  0..N | ffmpeg -filter_complex `"ddagrab=output_idx=<i>,hwdownload,format=bgra`" -frames:v 1 out<i>.png"
Write-Host " The 800x600 (or your configured VDD resolution) frame is the virtual display."

& $Ffmpeg -hide_banner -loglevel warning `
    -filter_complex "ddagrab=output_idx=$OutputIndex,hwdownload,format=bgra,fps=60" `
    -c:v libx264 -preset ultrafast -tune zerolatency `
    -b:v 8000k -maxrate 9000k -bufsize 2000k -pix_fmt yuv420p -g 60 `
    -muxdelay 0 -muxpreload 0 -flush_packets 1 `
    -t $DurationSeconds -f mpegts "udp://${UbuntuIp}:53319?pkt_size=1316"

Write-Host " done"
