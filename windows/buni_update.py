"""
Buni 앱 안 업데이트 — GitHub 릴리스에서 새 버전을 확인하고, 내려받아 설치한 뒤 다시 시작한다.

- 설치형(설치 마법사로 깔린 경우): 릴리스의 Setup.exe 를 받아 조용히(/VERYSILENT) 실행한다.
  설치가 끝나면 installer.iss 의 [Run] 이 앱을 다시 켠다.
- 포터블(Buni-Windows.exe 만 쓰는 경우): 새 exe 를 받아 앱이 종료된 뒤 보조 배치 파일이 바꿔치기하고 다시 켠다.
- 소스로 실행 중이면 자동 설치는 하지 않고 릴리스 페이지만 연다.
받은 파일은 GitHub 가 알려 주는 sha256 과 대조하고, 실패하면 지금 앱은 그대로 둔다.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

API_URL = 'https://api.github.com/repos/EloyYang/buni/releases/latest'
RELEASE_PAGE = 'https://github.com/EloyYang/buni/releases/latest'
CHECK_INTERVAL = 6 * 3600
USER_AGENT = 'Buni-Updater'


class UpdateError(Exception):
    pass


# ── 버전 ─────────────────────────────────────────────────────

def current_version() -> str:
    """exe 안에 들어간(또는 저장소의) VERSION 파일 — 없으면 '0.0.0'."""
    candidates = []
    base = getattr(sys, '_MEIPASS', None)
    if base:
        candidates.append(Path(base) / 'VERSION')
    here = Path(__file__).resolve().parent
    candidates += [here / 'VERSION', here.parent / 'VERSION']
    for p in candidates:
        try:
            v = p.read_text(encoding='utf-8').strip()
            if re.fullmatch(r'\d+(\.\d+)*', v):
                return v
        except OSError:
            continue
    return '0.0.0'


def parse_version(v: str) -> tuple:
    v = (v or '').strip().lstrip('vV')
    try:
        return tuple(int(x) for x in v.split('.'))
    except ValueError:
        return (0,)


def is_newer(latest: str, current: str) -> bool:
    a, b = parse_version(latest), parse_version(current)
    n = max(len(a), len(b))
    return a + (0,) * (n - len(a)) > b + (0,) * (n - len(b))


# ── 릴리스 정보 ──────────────────────────────────────────────

def pick_assets(release: dict) -> dict:
    """릴리스 JSON 에서 설치 파일·포터블 exe 를 고른다 → {'setup': {...}, 'portable': {...}}"""
    out = {}
    for a in release.get('assets') or []:
        name = a.get('name') or ''
        url = a.get('browser_download_url') or ''
        if not url.startswith('https://'):
            continue
        digest = a.get('digest') or ''
        item = {'name': name, 'url': url, 'size': a.get('size') or 0,
                'sha256': digest[7:].lower() if digest.startswith('sha256:') else None}
        low = name.lower()
        if low.startswith('buni-windows-setup') and low.endswith('.exe'):
            out['setup'] = item
        elif low == 'buni-windows.exe':
            out['portable'] = item
    return out


def fetch_latest(timeout=10):
    """새 버전이 있으면 {'version', 'assets', 'page'}, 없거나 확인 실패면 None."""
    req = urllib.request.Request(API_URL, headers={'Accept': 'application/vnd.github+json',
                                                   'User-Agent': USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode('utf-8'))
    except Exception:
        return None
    tag = data.get('tag_name') or ''
    if not is_newer(tag, current_version()):
        return None
    return {'version': tag.lstrip('vV'), 'assets': pick_assets(data), 'page': data.get('html_url') or RELEASE_PAGE}


# ── 설치 방식 ────────────────────────────────────────────────

def install_kind() -> str:
    """'installed'(설치 마법사) · 'portable'(exe 만) · 'source'(파이썬으로 실행 — 자동 설치 불가)"""
    if not getattr(sys, 'frozen', False):
        return 'source'
    exe = Path(sys.executable)
    if (exe.parent / 'unins000.exe').exists():
        return 'installed'
    return 'portable'


# ── 내려받기 ─────────────────────────────────────────────────

def download(item: dict, dest: Path, progress=None, timeout=30) -> Path:
    """item 의 url 을 dest 로 내려받고 sha256 이 맞는지 확인한다. progress(received, total)."""
    req = urllib.request.Request(item['url'], headers={'User-Agent': USER_AGENT})
    h = hashlib.sha256()
    received = 0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, 'wb') as f:
            total = int(r.headers.get('Content-Length') or item.get('size') or 0)
            while True:
                chunk = r.read(1 << 18)
                if not chunk:
                    break
                f.write(chunk)
                h.update(chunk)
                received += len(chunk)
                if progress:
                    progress(received, total)
    except Exception as e:
        dest.unlink(missing_ok=True)
        raise UpdateError(f'download: {e}')
    want = item.get('sha256')
    if want and h.hexdigest() != want:
        dest.unlink(missing_ok=True)
        raise UpdateError('checksum')
    with open(dest, 'rb') as f:
        if f.read(2) != b'MZ':                         # 실행 파일이 맞는지
            dest.unlink(missing_ok=True)
            raise UpdateError('not an executable')
    return dest


# ── 설치 ─────────────────────────────────────────────────────

_DETACHED = 0x00000008 | 0x00000200          # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def portable_swap_script(new_exe: Path, target_exe: Path, pid: int) -> str:
    """앱이 끝난 뒤 새 exe 로 바꾸고 다시 켜는 배치 파일 내용."""
    return (
        '@echo off\r\n'
        'setlocal\r\n'
        f'set "NEW={new_exe}"\r\n'
        f'set "DST={target_exe}"\r\n'
        'set /a TRIES=0\r\n'
        ':wait\r\n'
        f'tasklist /FI "PID eq {pid}" 2>nul | find "{pid}" >nul\r\n'
        'if not errorlevel 1 (\r\n'
        '  set /a TRIES+=1\r\n'
        '  if %TRIES% GEQ 60 goto restart\r\n'
        '  ping -n 2 127.0.0.1 >nul\r\n'
        '  goto wait\r\n'
        ')\r\n'
        'set /a TRIES=0\r\n'
        ':swap\r\n'
        'move /y "%NEW%" "%DST%" >nul 2>&1\r\n'
        'if errorlevel 1 (\r\n'
        '  set /a TRIES+=1\r\n'
        '  if %TRIES% GEQ 30 goto restart\r\n'
        '  ping -n 2 127.0.0.1 >nul\r\n'
        '  goto swap\r\n'
        ')\r\n'
        ':restart\r\n'
        'start "" "%DST%"\r\n'
        '(goto) 2>nul & del "%~f0"\r\n'
    )


def apply(kind: str, downloaded: Path) -> None:
    """내려받은 파일로 업데이트를 시작한다. 호출한 쪽은 곧바로 앱을 종료해야 한다."""
    if kind == 'installed':
        subprocess.Popen([str(downloaded), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
                         creationflags=_DETACHED, close_fds=True)
    elif kind == 'portable':
        target = Path(sys.executable)
        if not os.access(target.parent, os.W_OK):
            raise UpdateError('not writable')
        bat = Path(tempfile.gettempdir()) / f'buni-update-{os.getpid()}.bat'
        bat.write_text(portable_swap_script(downloaded, target, os.getpid()), encoding='utf-8')
        subprocess.Popen(['cmd', '/c', str(bat)], creationflags=_DETACHED | 0x08000000, close_fds=True)   # CREATE_NO_WINDOW
    else:
        raise UpdateError('source')


def run_update(info: dict, progress=None) -> str:
    """새 버전을 내려받아 설치를 시작한다 → 설치 방식. 실패하면 UpdateError."""
    kind = install_kind()
    if kind == 'source':
        raise UpdateError('source')
    item = info['assets'].get('setup' if kind == 'installed' else 'portable')
    if not item:
        raise UpdateError('no asset')
    work = Path(tempfile.mkdtemp(prefix='buni-update-'))
    dest = work / item['name']
    download(item, dest, progress)
    apply(kind, dest)
    return kind
