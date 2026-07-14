@echo off
setlocal

if /I "%USERNAME%"=="Imagem" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Execucao bloqueada. O instalador nao pode ser executado pelo usuario Imagem. Faca logoff e entre com a conta do colaborador, depois execute novamente.','Instalador bloqueado - usuario nao permitido','OK','Warning') | Out-Null"
  echo Execucao bloqueada: usuario Imagem nao e permitido. Faca logoff e entre com a conta do colaborador.
  exit /b 2
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Executar-Instalador.ps1" -Mode Manual -RepositoryRoot "%~dp0"
pause
exit /b %errorlevel%
