:: This batch file is intended to be run in a Command Prompt or PowerShell environment on Windows.
:: It will install the necessary dependencies for the project: Scoop, Sudo, SQLite ODBC Driver, Caddy, ollama
:: The script will also try to register Caddy certificates and download the Ollama models:
::   qwen3-vl:8b-instruct           vision model (photo descriptions, Step 15)
::   qwen3-embedding:0.6b  embedding model, 1024 dimensions (Steps 17-22)
:: The script also runs Caddy and Ollama in background
::
:: Notes:
::   - "if errorlevel 1" is used inside ( ) blocks: %errorlevel% would be expanded
::     when the whole block is parsed, i.e. before the command inside it runs.
::   - scoop and sudo are Scoop shims (.cmd): they must be invoked with "call",
::     otherwise control does not return to this script after the first call.
::   - Model tags are pinned explicitly: embeddings computed on one machine are
::     only comparable with query vectors computed by the same model build.

@echo off
setlocal

:: Model tags (keep in sync with 14/15/22 and 17/18 SQL scripts)
::   VISION_MODEL       vision model on both machines (Steps 15 and 22)
::   VISION_MODEL_DEMO  fallback for the live import in Step 22 if the 8B model times out
set VISION_MODEL=qwen3-vl:8b-instruct
set VISION_MODEL_DEMO=qwen3-vl:4b-instruct
set EMBED_MODEL=qwen3-embedding:0.6b

:: Install Scoop if not already installed
where scoop >nul 2>&1
if errorlevel 1 (
    echo Installing Scoop...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; Invoke-RestMethod https://get.scoop.sh | Invoke-Expression"
    if errorlevel 1 (
        echo ERROR: Scoop installation failed.
        exit /b 1
    )
    :: Refresh PATH in current session so scoop is available
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i;%PATH%"
    echo Scoop installed successfully.
) else (
    echo Scoop is already installed.
)

:: Install sudo via Scoop if not already installed
where sudo >nul 2>&1
if errorlevel 1 (
    echo Installing sudo via Scoop...
    call scoop install sudo
    if errorlevel 1 (
        echo ERROR: sudo installation failed.
        exit /b 1
    )
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i;%PATH%"
    echo sudo installed successfully.
) else (
    echo sudo is already installed.
)

:: Install SQLite ODBC Driver (Christian Werner) if not already installed
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\SQLite3 ODBC Driver" >nul 2>&1
if errorlevel 1 (
    echo Installing SQLite ODBC Driver...
    powershell -NoProfile -Command "Invoke-WebRequest -Uri 'http://www.ch-werner.de/sqliteodbc/sqliteodbc_w64.exe' -OutFile \"$env:TEMP\sqliteodbc_w64.exe\""
    if errorlevel 1 (
        echo ERROR: Download of SQLite ODBC Driver failed.
        exit /b 1
    )
    call sudo "%TEMP%\sqliteodbc_w64.exe" /S
    if errorlevel 1 (
        echo ERROR: SQLite ODBC Driver installation failed.
        exit /b 1
    )
    del "%TEMP%\sqliteodbc_w64.exe"
    echo SQLite ODBC Driver installed successfully.
) else (
    echo SQLite ODBC Driver is already installed.
)

:: Install Caddy via Scoop if not already installed
where caddy >nul 2>&1
if errorlevel 1 (
    echo Installing Caddy via Scoop...
    call scoop install caddy
    if errorlevel 1 (
        echo ERROR: Caddy installation failed.
        exit /b 1
    )
    :: Refresh PATH in current session so caddy is available
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i;%PATH%"
    echo Caddy installed successfully.
) else (
    echo Caddy is already installed.
)

:: Start Caddy reverse proxy (HTTPS localhost:11435 -> Ollama HTTP localhost:11434)
tasklist /FI "IMAGENAME eq caddy.exe" 2>nul | find /I "caddy.exe" >nul
if errorlevel 1 (
    echo Starting Caddy reverse proxy...
    start "" /B caddy run --config "%~dp0Caddyfile"
    :: Wait for Caddy to initialize and generate its local root CA
    timeout /t 5 /nobreak >nul
    echo Caddy started on https://localhost:11435 -^> http://localhost:11434
) else (
    echo Caddy is already running.
)

:: Trust Caddy local root CA in the machine certificate store (LocalMachine\Root).
:: SQL Server runs as a service and reads only the machine store, not the current-user store.
set CADDY_CERT=%APPDATA%\Caddy\pki\authorities\local\root.crt
if exist "%CADDY_CERT%" (
    call sudo certutil -addstore -f "Root" "%CADDY_CERT%"
    if errorlevel 1 (
        echo ERROR: Failed to add Caddy root CA to machine store.
        exit /b 1
    )
    echo Caddy root CA installed in machine trust store.
) else (
    echo ERROR: Caddy root CA not found at %CADDY_CERT%. Caddy may not have started correctly.
    exit /b 1
)

:: Install Ollama via Scoop if not already installed
where ollama >nul 2>&1
if errorlevel 1 (
    echo Installing Ollama via Scoop...
    call scoop install ollama
    if errorlevel 1 (
        echo ERROR: Ollama installation failed.
        exit /b 1
    )
    :: Refresh PATH in current session so ollama is available
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i;%PATH%"
    echo Ollama installed successfully.
) else (
    echo Ollama is already installed.
)

:: Start Ollama service in background only if not already running
tasklist /FI "IMAGENAME eq ollama.exe" 2>nul | find /I "ollama.exe" >nul
if errorlevel 1 (
    echo Starting Ollama service...
    start "" /B ollama serve
    timeout /t 5 /nobreak >nul
) else (
    echo Ollama service is already running.
)

:: Pull vision model via Ollama
echo Pulling %VISION_MODEL% (this may take a while)...
ollama pull %VISION_MODEL%
if errorlevel 1 (
    echo ERROR: pull of %VISION_MODEL% failed.
    exit /b 1
)

:: Pull smaller vision model used for the live import on the demo laptop
echo Pulling %VISION_MODEL_DEMO% (this may take a while)...
ollama pull %VISION_MODEL_DEMO%
if errorlevel 1 (
    echo ERROR: pull of %VISION_MODEL_DEMO% failed.
    exit /b 1
)

:: Pull embedding model via Ollama
echo Pulling %EMBED_MODEL% (this may take a while)...
ollama pull %EMBED_MODEL%
if errorlevel 1 (
    echo ERROR: pull of %EMBED_MODEL% failed.
    exit /b 1
)

:: Print model IDs (digests): compare them between dev and demo machines.
:: Embeddings restored from the .bak are only consistent with query vectors
:: computed by the same embedding model ID.
echo.
echo Installed models (compare the ID column between dev and demo HW):
ollama list

endlocal
