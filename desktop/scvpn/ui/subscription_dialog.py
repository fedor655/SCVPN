"""Экран подписки: что это за подписка, сколько осталось и как ею поделиться.

Всё, что показано, приходит от панели в заголовках ответа (см. subinfo.py) —
приложение ничего не досчитывает. Дата «добавлена» — единственная местная:
даты активации панели не присылают, поэтому она честно подписана как момент
добавления подписки в SCVPN, а не как начало оплаченного периода.
"""
from __future__ import annotations

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QDesktopServices, QGuiApplication, QPainter, QPixmap
from PySide6.QtWidgets import (
    QDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from ..storage import Subscription
from ..subinfo import human_bytes, human_interval
from . import theme


def qr_pixmap(text: str, size: int = 220) -> QPixmap | None:
    """QR-код ссылки. Рисуем матрицу сами, чтобы не тащить Pillow в рантайм."""
    try:
        import qrcode
    except ImportError:
        return None

    qr = qrcode.QRCode(border=2)
    qr.add_data(text)
    qr.make(fit=True)
    matrix = qr.get_matrix()
    n = len(matrix)

    pm = QPixmap(size, size)
    pm.fill(QColor("#FFFFFF"))          # QR читается надёжнее на белом
    p = QPainter(pm)
    p.setPen(Qt.NoPen)
    p.setBrush(QColor("#0A0E13"))
    cell = size / n
    for y, row in enumerate(matrix):
        for x, dark in enumerate(row):
            if dark:
                # +1 к размеру, чтобы между модулями не просвечивали щели
                p.drawRect(QRectF(x * cell, y * cell, cell + 0.5, cell + 0.5))
    p.end()
    return pm


class SubscriptionDialog(QDialog):
    """Одна подписка: статистика, ссылка, QR, удаление."""

    def __init__(self, sub: Subscription, parent=None) -> None:
        super().__init__(parent)
        self.sub = sub
        self.deleted = False
        self.refresh_requested = False

        self.setWindowTitle("Подписка")
        self.setMinimumWidth(420)

        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 18)
        root.setSpacing(14)

        info = sub.info
        title = QLabel(info.title or sub.name or "Подписка")
        title.setStyleSheet(f"font-size: 17px; font-weight: 700; color: {theme.TEXT};")
        title.setWordWrap(True)
        root.addWidget(title)

        if info.account:
            account = QLabel(info.account)
            account.setStyleSheet(f"color: {theme.DIM}; font-size: 12px;")
            root.addWidget(account)

        if info.announce:
            note = QLabel(info.announce)
            note.setWordWrap(True)
            note.setStyleSheet(
                f"color: {theme.TEXT}; background: {theme.SURFACE_HI};"
                f"border: 1px solid {theme.STROKE}; border-radius: 10px; padding: 10px;"
            )
            root.addWidget(note)

        root.addWidget(self._stats_block())
        root.addWidget(self._divider())
        root.addLayout(self._link_block())
        root.addWidget(self._divider())
        root.addLayout(self._buttons())

    # ------------------------------------------------------------------
    def _divider(self) -> QFrame:
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setStyleSheet(f"color: {theme.STROKE};")
        return line

    def _row(self, label: str, value: str, color: str | None = None) -> QHBoxLayout:
        row = QHBoxLayout()
        left = QLabel(label)
        left.setStyleSheet(f"color: {theme.DIM}; font-size: 12px;")
        right = QLabel(value)
        right.setStyleSheet(f"color: {color or theme.TEXT}; font-size: 12px; font-weight: 600;")
        right.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        right.setTextInteractionFlags(Qt.TextSelectableByMouse)
        row.addWidget(left)
        row.addStretch(1)
        row.addWidget(right)
        return row

    def _stats_block(self) -> QWidget:
        info = self.sub.info
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(7)

        # --- трафик ---
        if info.unlimited:
            lay.addLayout(self._row("Потрачено", human_bytes(info.used)))
            lay.addLayout(self._row("Лимит трафика", "безлимит"))
        else:
            lay.addLayout(self._row(
                "Потрачено", f"{human_bytes(info.used)} из {human_bytes(info.total)}"
            ))
            lay.addWidget(self._traffic_bar(info.used_ratio))
        if info.upload or info.download:
            lay.addLayout(self._row(
                "  из них отдано / принято",
                f"{human_bytes(info.upload)} / {human_bytes(info.download)}",
                theme.DIM,
            ))

        # --- срок ---
        expires = info.expires_at
        if expires:
            # Цветом тревожность не показать — пишем словами.
            left = info.days_left
            tail = ""
            if left is not None:
                if left < 0:
                    tail = "  ·  истекла"
                elif left <= 5:
                    tail = f"  ·  осталось {left} дн. — скоро истечёт"
                else:
                    tail = f"  ·  осталось {left} дн."
            lay.addLayout(self._row("Действует до", f"{expires:%d.%m.%Y}{tail}"))
        else:
            lay.addLayout(self._row("Действует до", "бессрочно"))

        lay.addLayout(self._row("Автообновление", human_interval(info.update_interval)))
        lay.addLayout(self._row("Серверов", str(len(self.sub.servers))))

        if self.sub.added:
            lay.addLayout(self._row("Добавлена в SCVPN", self.sub.added, theme.DIM))
        if info.fetched:
            lay.addLayout(self._row("Данные обновлены", info.fetched, theme.DIM))

        # --- устройства ---
        if info.hwid:
            if info.device_limit_reached:
                lay.addLayout(self._row("Устройства", "лимит исчерпан"))
            elif info.hwid.get("x-hwid-limit") == "true":
                lay.addLayout(self._row("Устройства", "есть ограничение", theme.DIM))
        return box

    def _traffic_bar(self, ratio: float) -> QWidget:
        bar = QWidget()
        bar.setFixedHeight(6)
        bar.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        color = theme.ACCENT if ratio < 0.9 else theme.DIM

        def paint(event, w=bar, r=ratio, c=color):  # noqa: ARG001
            p = QPainter(w)
            p.setRenderHint(QPainter.Antialiasing, True)
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(theme.STROKE))
            p.drawRoundedRect(QRectF(0, 0, w.width(), 6), 3, 3)
            if r > 0:
                p.setBrush(QColor(c))
                p.drawRoundedRect(QRectF(0, 0, max(6.0, w.width() * r), 6), 3, 3)
            p.end()

        bar.paintEvent = paint
        return bar

    def _link_block(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(14)

        left = QVBoxLayout()
        cap = QLabel("Ссылка подписки")
        cap.setStyleSheet(f"color: {theme.DIM}; font-size: 12px;")
        left.addWidget(cap)

        link = QLabel(self.sub.url)
        link.setWordWrap(True)
        link.setTextInteractionFlags(Qt.TextSelectableByMouse)
        link.setStyleSheet(
            f"color: {theme.TEXT}; font-size: 11px; font-family: Consolas, monospace;"
            f"background: {theme.BG}; border: 1px solid {theme.STROKE};"
            "border-radius: 8px; padding: 8px;"
        )
        left.addWidget(link)

        copy_row = QHBoxLayout()
        copy_btn = QPushButton("Копировать ссылку")
        copy_btn.clicked.connect(self._copy_link)
        copy_row.addWidget(copy_btn)
        if self.sub.info.support_url:
            sup = QPushButton("Поддержка")
            sup.clicked.connect(
                lambda: QDesktopServices.openUrl(self.sub.info.support_url)
            )
            copy_row.addWidget(sup)
        copy_row.addStretch(1)
        left.addLayout(copy_row)
        left.addStretch(1)
        row.addLayout(left, 1)

        # --- QR ---
        pm = qr_pixmap(self.sub.url, 190)
        qr_box = QVBoxLayout()
        if pm is not None:
            qr = QLabel()
            qr.setPixmap(pm)
            qr.setFixedSize(pm.size())
            qr.setStyleSheet("border-radius: 8px;")
            qr_box.addWidget(qr)
            hint = QLabel("Наведи камерой,\nчтобы перенести на телефон")
            hint.setAlignment(Qt.AlignCenter)
            hint.setStyleSheet(f"color: {theme.DIM}; font-size: 11px;")
            qr_box.addWidget(hint)
        else:
            miss = QLabel("QR недоступен:\nне установлен модуль qrcode")
            miss.setAlignment(Qt.AlignCenter)
            miss.setStyleSheet(f"color: {theme.DIM}; font-size: 11px;")
            qr_box.addWidget(miss)
        qr_box.addStretch(1)
        row.addLayout(qr_box)
        return row

    def _buttons(self) -> QHBoxLayout:
        row = QHBoxLayout()
        refresh = QPushButton("Обновить")
        refresh.clicked.connect(self._refresh)
        delete = QPushButton("Удалить подписку")
        delete.setStyleSheet(f"color: {theme.DIM};")
        delete.clicked.connect(self._delete)
        close = QPushButton("Закрыть")
        close.setDefault(True)
        close.clicked.connect(self.accept)

        row.addWidget(refresh)
        row.addWidget(delete)
        row.addStretch(1)
        row.addWidget(close)
        return row

    # ------------------------------------------------------------------
    def _copy_link(self) -> None:
        QGuiApplication.clipboard().setText(self.sub.url)
        QMessageBox.information(self, "Скопировано", "Ссылка подписки в буфере обмена.")

    def _refresh(self) -> None:
        self.refresh_requested = True
        self.accept()

    def _delete(self) -> None:
        if QMessageBox.question(
            self, "Удалить подписку",
            f"Удалить «{self.sub.name}» и её {len(self.sub.servers)} серверов?",
        ) != QMessageBox.Yes:
            return
        self.deleted = True
        self.accept()
