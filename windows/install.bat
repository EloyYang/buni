@echo off
chcp 65001 >nul
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo   Buni for Windows 설치
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: 1. Python 확인
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [오류] Python이 설치되어 있지 않습니다.
    echo https://www.python.org 에서 Python 3.10 이상을 설치하세요.
    pause & exit /b 1
)

:: 2. 의존성 설치
echo [1/3] 패키지 설치 중...
pip install -r "%~dp0requirements.txt" --quiet
if %errorlevel% neq 0 (
    echo [오류] pip install 실패
    pause & exit /b 1
)
echo       완료

:: 3. Claude Code 훅 설치
echo [2/3] Claude Code 훅 설치 중...
python "%~dp0install_hooks.py"
if %errorlevel% neq 0 (
    echo [오류] 훅 설치 실패
    pause & exit /b 1
)
echo       완료

:: 4. 앱 실행
echo [3/3] Buni 시작...
start "" "%~dp0Buni.exe"
echo       완료
echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo   설치 완료! 화면 오른쪽 하단에 부니가 나타납니다.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
pause
