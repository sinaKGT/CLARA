@echo off
REM  Double-click for the menu: install, start, stop, check, change model.
cd /d "%~dp0"
title CLARA
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utilities\clara.ps1"
