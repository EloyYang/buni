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
