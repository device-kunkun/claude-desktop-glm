@echo off
cd /d "%~dp0"
start "glm-gateway" /min node proxy.mjs
echo gateway started on 127.0.0.1:8787
