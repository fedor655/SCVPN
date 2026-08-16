"""Добавление сервера или подписки: вставить ссылку или отсканировать QR.

Одно поле на оба случая — тип определяется по самой строке, а не выбором
пользователя: ссылку сервера парсер узнаёт, всё остальное с http(s) считается
подпиской. Спрашивать «это ссылка или подписка?» значило бы перекладывать на
человека то, что программа выясняет сама.
"""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QPushButton,
    QVBoxLayout,
)

from . import theme
from .qr_scanner import scan_qr


class AddDialog(QDialog):
    """Поле ввода + кнопка сканирования QR. Результат — в `value`."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Добавить")
        # Ширина и поля общие у всех окон поверх главного: разные ширины
        # заметны, когда окна открывают подряд.
        self.setMinimumWidth(theme.SHEET_WIDTH)
        self.value: str = ""

        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.SHEET_PAD_H, theme.SHEET_PAD_V, theme.SHEET_PAD_H, theme.SHEET_PAD_V
        )
        root.setSpacing(theme.SHEET_GAP)

        caption = QLabel(
            "Вставь ссылку сервера (vless:// / vmess:// / trojan:// / ss://)\n"
            "или URL подписки — либо отсканируй QR-код."
        )
        caption.setWordWrap(True)
        caption.setStyleSheet(f"color: {theme.DIM}; font-size: {theme.FS_BODY}px;")
        root.addWidget(caption)

        self.input = QPlainTextEdit()
        self.input.setPlaceholderText("vless://…  или  https://…")
        self.input.setFixedHeight(78)
        self.input.setStyleSheet(
            f"background: {theme.BG}; border: 1px solid {theme.STROKE};"
            f"border-radius: {theme.BOX_CORNER}px; color: {theme.TEXT}; padding: 8px;"
            f"font-family: {theme.MONO_FONT}, monospace; font-size: {theme.FS_DETAIL}px;"
        )
        root.addWidget(self.input)

        row = QHBoxLayout()
        scan = QPushButton("Сканировать QR…")
        scan.clicked.connect(self._scan)
        row.addWidget(scan)
        row.addStretch(1)

        cancel = QPushButton("Отмена")
        cancel.clicked.connect(self.reject)
        ok = QPushButton("Добавить")
        ok.setDefault(True)
        ok.clicked.connect(self._accept)
        row.addWidget(cancel)
        row.addWidget(ok)
        root.addLayout(row)

    def _scan(self) -> None:
        text = scan_qr(self)
        if text:
            self.input.setPlainText(text)
            # Сразу не закрываем: пусть видно, что именно распозналось —
            # QR может оказаться не тем, что человек ожидал.
            self.input.setFocus()

    def _accept(self) -> None:
        self.value = self.input.toPlainText().strip()
        if self.value:
            self.accept()

    def keyPressEvent(self, event) -> None:  # noqa: N802
        # В многострочном поле Enter вставляет перенос, поэтому подтверждаем
        # по Ctrl+Enter — иначе кнопку «Добавить» пришлось бы искать мышью.
        if event.key() in (Qt.Key_Return, Qt.Key_Enter) and event.modifiers() & Qt.ControlModifier:
            self._accept()
        else:
            super().keyPressEvent(event)
