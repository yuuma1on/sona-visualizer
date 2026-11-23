$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$renderRoot = Join-Path $appRoot 'renders'
New-Item -ItemType Directory -Force -Path $renderRoot | Out-Null
$prefix = 'http://127.0.0.1:4173/'

function Send-Text($response, [int]$status, [string]$text, [string]$contentType = 'text/plain; charset=utf-8') {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $response.StatusCode = $status
  $response.ContentType = $contentType
  $response.ContentLength64 = $bytes.Length
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
  $response.Close()
}

function Get-SafeTitle([string]$value) {
  $clean = [regex]::Replace($value, '[^\p{L}\p{N}\-_ ]', '').Trim()
  if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'sona-visualizer' }
  if ($clean.Length -gt 70) { $clean = $clean.Substring(0, 70).Trim() }
  return $clean
}

try {
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($prefix)
  $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
  $listener.Start()
  Write-Host ''
  Write-Host 'Sona Visualizer is running at http://127.0.0.1:4173/' -ForegroundColor Cyan
  Write-Host 'Close this window to stop the local server.'
  if ($env:SONA_LAUNCHER -ne '1') { Start-Process $prefix }

  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
      if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/status') {
        Send-Text $response 200 '{"ready":true}' 'application/json; charset=utf-8'
        continue
      }
      if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/render') {
        if ($request.ContentLength64 -gt 5368709120) {
          Send-Text $response 413 '録画データが大きすぎます。720p にしてもう一度お試しください。'
          continue
        }
        $title = Get-SafeTitle($request.QueryString['name'])
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $base = "$title-$stamp"
        $tempPath = Join-Path $renderRoot ("upload-" + [guid]::NewGuid().ToString('N') + '.webm')
        $mp4Path = Join-Path $renderRoot ($base + '.mp4')
        $inputStream = $request.InputStream
        $fileStream = [System.IO.File]::Create($tempPath)
        try { $inputStream.CopyTo($fileStream) } finally { $fileStream.Dispose() }
        Write-Host "Converting $base.mp4 ..."
        & $ffmpeg -hide_banner -loglevel error -y -i $tempPath -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart $mp4Path
        $exitCode = $LASTEXITCODE
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $mp4Path)) {
          Remove-Item -LiteralPath $mp4Path -Force -ErrorAction SilentlyContinue
          Send-Text $response 500 'MP4 変換に失敗しました。音源を確認してもう一度お試しください。'
          continue
        }
        $response.StatusCode = 200
        $response.ContentType = 'video/mp4'
        $response.ContentLength64 = (Get-Item -LiteralPath $mp4Path).Length
        $encodedName = [Uri]::EscapeDataString("$base.mp4")
        $response.Headers.Add('Content-Disposition', "attachment; filename=sona-visualizer.mp4; filename*=UTF-8''$encodedName")
        $outputStream = [System.IO.File]::OpenRead($mp4Path)
        try { $outputStream.CopyTo($response.OutputStream) } finally { $outputStream.Dispose(); $response.Close() }
        Write-Host "Saved $mp4Path" -ForegroundColor Green
        continue
      }
      if ($request.HttpMethod -ne 'GET' -and $request.HttpMethod -ne 'HEAD') {
        Send-Text $response 405 'Method not allowed'
        continue
      }
      $relative = [Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart('/'))
      if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }
      $fullPath = [System.IO.Path]::GetFullPath((Join-Path $appRoot $relative))
      $rootPrefix = [System.IO.Path]::GetFullPath($appRoot) + [System.IO.Path]::DirectorySeparatorChar
      if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Send-Text $response 404 'Not found'
        continue
      }
      $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
      $contentType = switch ($extension) {
        '.html' { 'text/html; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.js' { 'text/javascript; charset=utf-8' }
        '.svg' { 'image/svg+xml' }
        '.png' { 'image/png' }
        '.ico' { 'image/x-icon' }
        default { 'application/octet-stream' }
      }
      $response.StatusCode = 200
      $response.ContentType = $contentType
      $response.Headers.Add('Cache-Control', 'no-store')
      if ($request.HttpMethod -eq 'HEAD') { $response.Close(); continue }
      $staticStream = [System.IO.File]::OpenRead($fullPath)
      $response.ContentLength64 = $staticStream.Length
      try { $staticStream.CopyTo($response.OutputStream) } finally { $staticStream.Dispose(); $response.Close() }
    } catch {
      Write-Host $_.Exception.Message -ForegroundColor Red
      try { $response.StatusCode = 500; $response.Close() } catch { }
    }
  }
} catch {
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host 'FFmpeg が見つからないか、ローカルサーバーを起動できませんでした。' -ForegroundColor Yellow
  Write-Host 'FFmpeg のインストール状況と、ポート 4173 が使用中でないか確認してください。'
  Read-Host 'Enter キーで閉じる'
} finally {
  if ($listener) {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
  }
}
