@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_all.ps1" %*
if errorlevel 1 (
    echo.
    echo ERROR: el proceso termino con fallos. Revise la salida anterior.
    exit /b 1
)
echo.
echo Proceso completado.
endlocal
