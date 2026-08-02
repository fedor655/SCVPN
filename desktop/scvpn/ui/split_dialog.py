"""Раздельное туннелирование: какие приложения пускать мимо VPN.

Работает только в TUN-режиме, и это не наше ограничение: системный прокси —
это строчка в настройках Windows, приложения ходят в него сами, и различить
их там нечем. В TUN-режиме трафик идёт через sing-box, а он умеет определять
процесс-владельца соединения и разводить его по разным маршрутам.

Список приложений набираем из запущенных процессов — так не нужно ходить по
диску за .exe и гадать, как называется нужный файл.
"""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QDialog,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QRadioButton,
    QVBoxLayout,
)

from ..tun import SPLIT_EXCLUDE, SPLIT_INCLUDE, SPLIT_OFF
from . import theme

# Системные процессы, которые в списке только мешают.
_HIDDEN = {
    "system", "system idle process", "registry", "memory compression", "svchost.exe",
    "csrss.exe", "wininit.exe", "winlogon.exe", "services.exe", "lsass.exe",
    "smss.exe", "fontdrvhost.exe", "dwm.exe", "ctfmon.exe", "sihost.exe",
    "taskhostw.exe", "runtimebroker.exe", "searchhost.exe", "conhost.exe",
    "dllhost.exe", "spoolsv.exe", "audiodg.exe", "wudfhost.exe",
}


def running_apps() -> list[str]:
    """Имена запущенных .exe, без системной мелочи и дубликатов."""
    names: set[str] = set()
    try:
        import subprocess

        out = subprocess.run(
            ["tasklist", "/fo", "csv", "/nh"],
            capture_output=True, text=True, encoding="cp866", errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
        for line in out.splitlines():
            if not line.startswith('"'):
                continue
            name = line.split('","')[0].strip('"')
            if name and name.lower() not in _HIDDEN:
                names.add(name)
    except Exception:  # noqa: BLE001
        pass
    return sorted(names, key=str.lower)


class SplitTunnelDialog(QDialog):
    """Режим раздельного туннелирования и список приложений."""

    def __init__(self, mode: str, apps: list[str], parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Раздельное туннелирование")
        self.resize(430, 520)

        self.mode = mode or SPLIT_OFF
        self._apps = list(apps)

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 16)
        root.setSpacing(12)

        note = QLabel(
            "Работает в режиме «TUN — весь трафик».\n"
            "В режиме системного прокси Windows не различает приложения."
        )
        note.setWordWrap(True)
        note.setStyleSheet(f"color: {theme.DIM}; font-size: 12px;")
        root.addWidget(note)

        self.rb_off = QRadioButton("Все приложения через VPN")
        self.rb_exclude = QRadioButton("Все через VPN, кроме выбранных")
        self.rb_include = QRadioButton("Только выбранные через VPN")
        for rb, value in (
            (self.rb_off, SPLIT_OFF),
            (self.rb_exclude, SPLIT_EXCLUDE),
            (self.rb_include, SPLIT_INCLUDE),
        ):
            rb.setChecked(self.mode == value)
            rb.toggled.connect(self._on_mode_changed)
            root.addWidget(rb)

        root.addWidget(QLabel("Приложения:"))

        self.search = QLineEdit()
        self.search.setPlaceholderText("Поиск по имени…")
        self.search.textChanged.connect(self._filter)
        root.addWidget(self.search)

        self.list = QListWidget()
        self.list.setSelectionMode(QAbstractItemView.NoSelection)
        root.addWidget(self.list, 1)
        self._fill()

        row = QHBoxLayout()
        add_btn = QPushButton("Добавить вручную…")
        add_btn.clicked.connect(self._add_manual)
        reload_btn = QPushButton("Обновить список")
        reload_btn.clicked.connect(self._fill)
        row.addWidget(add_btn)
        row.addWidget(reload_btn)
        row.addStretch(1)
        root.addLayout(row)

        buttons = QHBoxLayout()
        ok = QPushButton("Сохранить")
        ok.setDefault(True)
        ok.clicked.connect(self._save)
        cancel = QPushButton("Отмена")
        cancel.clicked.connect(self.reject)
        buttons.addStretch(1)
        buttons.addWidget(cancel)
        buttons.addWidget(ok)
        root.addLayout(buttons)

        self._on_mode_changed()

    # ------------------------------------------------------------------
    def _fill(self) -> None:
        """Запущенные приложения плюс уже выбранные (даже если сейчас закрыты)."""
        chosen = self._collect() or self._apps
        names = sorted(set(running_apps()) | set(chosen), key=str.lower)

        self.list.clear()
        for name in names:
            item = QListWidgetItem(name)
            item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
            item.setCheckState(Qt.Checked if name in chosen else Qt.Unchecked)
            self.list.addItem(item)
        self._filter(self.search.text())

    def _filter(self, text: str) -> None:
        needle = text.strip().lower()
        for i in range(self.list.count()):
            item = self.list.item(i)
            item.setHidden(bool(needle) and needle not in item.text().lower())

    def _collect(self) -> list[str]:
        return [
            self.list.item(i).text()
            for i in range(self.list.count())
            if self.list.item(i).checkState() == Qt.Checked
        ]

    def _on_mode_changed(self) -> None:
        enabled = not self.rb_off.isChecked()
        self.list.setEnabled(enabled)
        self.search.setEnabled(enabled)

    def _add_manual(self) -> None:
        name, ok = QInputDialog.getText(
            self, "Добавить приложение",
            "Имя исполняемого файла (например, Telegram.exe):",
        )
        name = name.strip()
        if not ok or not name:
            return
        if not name.lower().endswith(".exe"):
            name += ".exe"
        chosen = set(self._collect()) | {name}
        self._apps = sorted(chosen, key=str.lower)
        self._fill()

    def _save(self) -> None:
        if self.rb_off.isChecked():
            self.mode = SPLIT_OFF
        elif self.rb_exclude.isChecked():
            self.mode = SPLIT_EXCLUDE
        else:
            self.mode = SPLIT_INCLUDE
        self._apps = self._collect()
        self.accept()

    @property
    def apps(self) -> list[str]:
        return self._apps
