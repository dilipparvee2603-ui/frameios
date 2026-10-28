@echo off
title Frame Exporter for Windows
echo ====================================================
echo Starting Frame Exporter...
echo ====================================================

python "%~dp0main.py" %*

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Application exited with error code %ERRORLEVEL%.
    pause
)
