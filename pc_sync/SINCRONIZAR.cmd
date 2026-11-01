@echo off
setlocal
title El Especulador del WoW - Sincronizador
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 goto usepython
py -3 sincronizar.py
goto finished
:usepython
python sincronizar.py
:finished
if errorlevel 1 pause
