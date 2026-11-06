"""Playwright가 띄운 Edge 창을 지정한 가상 데스크톱으로 보낸다 (Alt+Tab·작업 표시줄에서 안 보이게).

Edge는 Playwright 임시 프로필(--user-data-dir=...playwright_chromiumdev_profile-*)로 뜨므로,
그 command line을 가진 프로세스의 보이는 최상위 창만 옮긴다. 사용자의 평소 Edge는 건드리지 않는다.
가상 데스크톱 API는 비공개 COM이라 pyvda에 맡기고, 실패해도 감시는 계속한다.
"""
import ctypes, ctypes.wintypes as wt, subprocess

user32 = ctypes.windll.user32
EnumWindowsProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)


def playwright_edge_pids():
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | "
          "Where-Object CommandLine -like '*playwright_chromiumdev_profile*' | ForEach-Object ProcessId")
    out = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps], capture_output=True,
                         text=True, creationflags=0x08000000).stdout
    return {int(x) for x in out.split()}


def windows_of(pids):
    hwnds = []

    def cb(hwnd, _):
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in pids and user32.IsWindowVisible(hwnd) and not user32.GetWindow(hwnd, 4):  # GW_OWNER
            hwnds.append(hwnd)
        return True

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return hwnds


def move_edge_to_desktop(number):
    """number번 데스크톱으로 옮긴 창 수를 돌려준다. 데스크톱이 모자라면 마지막 데스크톱으로."""
    from pyvda import AppView, get_virtual_desktops
    desktops = get_virtual_desktops()
    target = desktops[min(number, len(desktops)) - 1]
    moved = 0
    for hwnd in windows_of(playwright_edge_pids()):
        view = AppView(hwnd)
        if view.desktop.id != target.id:
            view.move(target)
            moved += 1
    return moved


if __name__ == "__main__":
    import sys
    print("moved:", move_edge_to_desktop(int(sys.argv[1]) if len(sys.argv) > 1 else 3))
