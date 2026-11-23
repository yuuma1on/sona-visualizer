@echo off
cd /d "%~dp0"
if exist "%~dp0SonaVisualizer.exe" (
  start "" "%~dp0SonaVisualizer.exe"
  exit /b
)
echo Starting Sona Visualizer. Keep this window open while using the app.
where node.exe >nul 2>nul
if not errorlevel 1 (
  node.exe "%~dp0server.js"
) else (
  echo Node.js was not found in PATH. Trying the built-in PowerShell server...
  powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
)
if errorlevel 1 (
  echo.
  echo The app did not start. Check the message above.
  pause
)
