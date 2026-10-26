@echo off
chcp 65001 >nul
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo   Buni.exe 빌드 (PyInstaller)
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: PyInstaller 설치 확인
pyinstaller --version >nul 2>&1
if %errorlevel% neq 0 (
    echo PyInstaller 설치 중...
    pip install pyinstaller --quiet
)

:: 계정 연동 설정(선택) — 저장소 루트나 windows 폴더에 cloud-config.json이 있으면 exe 안에 넣는다.
:: 없으면 계정 연동은 꺼진 채로 빌드된다.
set CLOUDDATA=
if exist "%~dp0..\cloud-config.json" set CLOUDDATA=--add-data "%~dp0..\cloud-config.json;."
if exist "%~dp0cloud-config.json" set CLOUDDATA=--add-data "%~dp0cloud-config.json;."

:: 빌드
pyinstaller ^
    --onefile ^
    --windowed ^
    --name Buni ^
    --icon "%~dp0buni_icon.ico" ^
    --hidden-import pystray ^
    --hidden-import PIL ^
    --hidden-import PIL.Image ^
    --hidden-import PIL.ImageDraw ^
    %CLOUDDATA% ^
    "%~dp0buni.py"

if %errorlevel% equ 0 (
    echo.
    echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    echo   빌드 완료: dist\Buni.exe
    echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
) else (
    echo [오류] 빌드 실패
)
pause
