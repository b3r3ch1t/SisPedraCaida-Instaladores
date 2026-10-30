@echo off
rem ==========================================================================================
rem  montar-instalador.cmd - remonta o instalador versionado em partes (PRD-ELGPRE-02).
rem
rem  Duplo clique na pasta que tem as partes <Instalador>.zip.001, .002... e este arquivo: junta as
rem  partes na ordem, extrai o .exe e o .sha256 de dentro do zip e confere o SHA-256 do .exe. Se o
rem  hash nao bater, o .exe e apagado - instalador corrompido nao fica na pasta parecendo bom.
rem
rem  So usa o que o Windows 10+ ja traz (copy /b, tar, certutil): funciona com a pasta baixada
rem  avulsa do GitHub, sem o repositorio e sem PowerShell. As partes sao DESCOBERTAS (contiguas a
rem  partir de .001): a receita antiga do copy /b listava tres partes fixas e falhava no pacote de
rem  duas com "O sistema nao pode encontrar o arquivo especificado".
rem
rem  Sem acentos de proposito: o cmd le o arquivo na pagina de codigo do console (850), nao em UTF-8.
rem  CRLF no proprio blob do git (.gitattributes -text): baixado pelo "raw" do GitHub, um .cmd com LF
rem  erra o goto para rotulo.
rem
rem  /semPausa  nao espera tecla no fim (testes e uso pelo console).
rem ==========================================================================================
setlocal EnableExtensions

set "PAUSAR=1"
if /i "%~1"=="/semPausa" set "PAUSAR=0"

rem pushd ANTES do EnableDelayedExpansion: uma "!" no caminho da pasta sumiria com ele ligado.
pushd "%~dp0" || (echo Nao foi possivel abrir a pasta %~dp0 & set "FALHAS=1" & goto fim)

setlocal EnableDelayedExpansion
set "ACHADOS=0"
set "FALHAS=0"

for %%P in (*.zip.001) do (
    set /a ACHADOS+=1
    call :montar "%%~nP"
    if errorlevel 1 set /a FALHAS+=1
)

if !ACHADOS! equ 0 (
    echo Nenhuma parte .zip.001 nesta pasta: !CD!
    echo Coloque este arquivo na mesma pasta das partes ^(Instalador.zip.001, .002...^).
    set "FALHAS=1"
)

popd
goto fim

rem ------------------------------------------------------------------------------------------
rem  :montar <Instalador.zip> - junta <Instalador.zip>.001.., extrai e confere. errorlevel 1 = falhou.
rem ------------------------------------------------------------------------------------------
:montar
set "ZIP=%~1"
set "EXE=%~n1.exe"
echo.
echo Montando !EXE! ...

set "LISTA="
set "N=0"
:proximaParte
set /a N+=1
set "SUF=00!N!"
set "SUF=!SUF:~-3!"
if exist "!ZIP!.!SUF!" (
    if defined LISTA (set "LISTA=!LISTA!+"!ZIP!.!SUF!"") else (set "LISTA="!ZIP!.!SUF!"")
    echo   parte !ZIP!.!SUF!
    goto proximaParte
)
set /a PARTES=N-1

rem Parte faltando no meio (.001 e .003 sem a .002) daria um zip truncado: conta todas e compara.
set "TOTAL=0"
for %%F in ("!ZIP!.???") do set /a TOTAL+=1
if !TOTAL! gtr !PARTES! (
    echo ERRO: falta a parte !ZIP!.!SUF! - as partes precisam ser contiguas a partir de .001.
    exit /b 1
)

if exist "!EXE!" del /f /q "!EXE!"
copy /b !LISTA! "!ZIP!" >nul
if errorlevel 1 (
    echo ERRO: nao foi possivel juntar as partes em !ZIP!.
    if exist "!ZIP!" del /f /q "!ZIP!"
    exit /b 1
)

rem tar.exe (Windows 10 1803+) le zip; sem ele, o Expand-Archive do PowerShell.
tar -xf "!ZIP!" >nul 2>&1
if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '!ZIP!' -DestinationPath '.' -Force" >nul 2>&1
del /f /q "!ZIP!"

if not exist "!EXE!" (
    echo ERRO: o pacote nao trouxe !EXE! - parte corrompida ou de outra versao.
    exit /b 1
)
if not exist "!EXE!.sha256" (
    echo ERRO: sem !EXE!.sha256 no pacote - nao ha como conferir o instalador.
    del /f /q "!EXE!"
    exit /b 1
)

set "ESPERADO="
for /f "usebackq tokens=1" %%a in ("!EXE!.sha256") do if not defined ESPERADO set "ESPERADO=%%a"

rem certutil imprime o hash na segunda linha (com espacos entre os bytes em Windows antigos).
set "CALCULADO="
for /f "skip=1 delims=" %%h in ('certutil -hashfile "!EXE!" SHA256') do if not defined CALCULADO set "CALCULADO=%%h"
if defined CALCULADO set "CALCULADO=!CALCULADO: =!"

if /i not "!CALCULADO!"=="!ESPERADO!" (
    echo ERRO: o SHA-256 de !EXE! nao confere com !EXE!.sha256 - o .exe foi apagado.
    echo   esperado:  !ESPERADO!
    echo   calculado: !CALCULADO!
    del /f /q "!EXE!"
    exit /b 1
)

echo OK: !EXE!
echo SHA-256: !CALCULADO!  ^(confere com o .sha256^)
exit /b 0

:fim
if "%PAUSAR%"=="1" (
    echo.
    pause
)
if "%FALHAS%"=="0" (exit /b 0) else (exit /b 1)
