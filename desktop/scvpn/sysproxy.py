"""Управление системным прокси Windows.

Windows хранит настройки прокси в реестре:
  HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
Мы выставляем ProxyServer на наш локальный HTTP-вход (127.0.0.1:порт) и
поднимаем флаг ProxyEnable. При отключении — всё возвращаем как было.

Это «режим как в браузере»: его уважают почти все приложения, права админа
не нужны. TUN-режим (весь трафик) — отдельный модуль.
"""
from __future__ import annotations

import ctypes
import os

if os.name == "nt":
    import winreg

_INTERNET_SETTINGS = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"

# Обход прокси для локальных адресов.
_BYPASS = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;192.168.*;<local>"


def _refresh() -> None:
    """Сказать Windows перечитать настройки прокси (WinINet)."""
    if os.name != "nt":
        return
    INTERNET_OPTION_SETTINGS_CHANGED = 39
    INTERNET_OPTION_REFRESH = 37
    internet_set_option = ctypes.windll.Wininet.InternetSetOptionW
    internet_set_option(0, INTERNET_OPTION_SETTINGS_CHANGED, 0, 0)
    internet_set_option(0, INTERNET_OPTION_REFRESH, 0, 0)


def enable(host: str = "127.0.0.1", port: int = 10809) -> None:
    """Включить системный HTTP-прокси на host:port."""
    if os.name != "nt":
        raise RuntimeError("Системный прокси поддержан только на Windows")
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _INTERNET_SETTINGS, 0, winreg.KEY_WRITE) as key:
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(key, "ProxyServer", 0, winreg.REG_SZ, f"{host}:{port}")
        winreg.SetValueEx(key, "ProxyOverride", 0, winreg.REG_SZ, _BYPASS)
    _refresh()


def disable() -> None:
    """Выключить системный прокси."""
    if os.name != "nt":
        return
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _INTERNET_SETTINGS, 0, winreg.KEY_WRITE) as key:
            winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 0)
    except FileNotFoundError:
        pass
    _refresh()


def is_enabled() -> bool:
    if os.name != "nt":
        return False
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _INTERNET_SETTINGS, 0, winreg.KEY_READ) as key:
            val, _ = winreg.QueryValueEx(key, "ProxyEnable")
            return bool(val)
    except FileNotFoundError:
        return False
