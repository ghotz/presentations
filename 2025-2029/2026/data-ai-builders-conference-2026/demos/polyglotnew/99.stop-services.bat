@echo off
:: sudo is a Scoop shim (.cmd): "call" is required, otherwise the script
:: ends after the first sudo and Ollama is never stopped.
call sudo taskkill /F /T /IM caddy.exe
call sudo taskkill /F /T /IM ollama.exe
