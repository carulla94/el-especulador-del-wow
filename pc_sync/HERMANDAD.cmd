@echo off
setlocal
title Oro de Hermandad - Subidor de precios
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 goto usepython
py -3 hermandad.py %*
goto finished
:usepython
where python >nul 2>nul
if errorlevel 1 goto nopython
python hermandad.py %*
if errorlevel 9009 goto nopython
goto finished
:nopython
echo.
echo No se encuentra Python 3 en este PC.
echo 1. Descarga Python 3.10 o superior de https://www.python.org/downloads/windows/
echo 2. Al instalarlo, marca la casilla "Add python.exe to PATH" y deja marcado el lanzador "py".
echo 3. Cierra esta ventana y vuelve a abrir HERMANDAD.cmd.
echo No sirve el acceso directo "python" de Microsoft Store que solo abre la tienda.
echo.
pause
exit /b 1
:finished
if errorlevel 1 pause
