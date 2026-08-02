"""Два самодельных виджета, ради которых экран и стал спокойным.

* `PowerButton` — единственная крупная кнопка: кольцо + фирменный знак,
  цвет кольца и есть индикатор состояния (серый / синий / бирюзовый / красный).
  Пока идёт подключение, по кольцу бежит дуга — видно, что процесс живой.
* `ServerDelegate` — рисует строку списка карточкой: имя, под ним транспорт,
  справа пинг. Обычный QListWidget с таким делегатом выглядит как список
  карточек, но остаётся списком со всеми клавишами и прокруткой.
"""
from __future__ import annotations

from PySide6.QtCore import QRectF, QSize, Qt, QTimer
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import QAbstractButton, QStyle, QStyledItemDelegate

from . import theme
from .brandmark import paint_mark

# Роли данных для строк списка.
ROLE_SERVER = Qt.UserRole + 1
ROLE_SUBTITLE = Qt.UserRole + 2
ROLE_PING = Qt.UserRole + 3      # int (мс) | None (не мерили) | False (не ответил)


class PowerButton(QAbstractButton):
    """Круглая кнопка подключения. `state`: idle | connecting | connected | error."""

    _COLORS = {
        "idle": theme.DIM,
        "connecting": theme.BLUE,
        "connected": theme.TEAL,
        "error": theme.RED,
    }

    def __init__(self, size: int = 132, parent=None) -> None:
        super().__init__(parent)
        self._state = "idle"
        self._spin = 0
        self.setFixedSize(size, size)
        self.setCursor(Qt.PointingHandCursor)

        self._timer = QTimer(self)
        self._timer.setInterval(16)
        self._timer.timeout.connect(self._advance)

    def set_state(self, state: str) -> None:
        if state == self._state:
            return
        self._state = state
        if state == "connecting":
            self._spin = 0
            self._timer.start()
        else:
            self._timer.stop()
        self.update()

    def _advance(self) -> None:
        self._spin = (self._spin + 4) % 360
        self.update()

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)

        color = QColor(self._COLORS[self._state])
        ring_w = 3.0
        box = QRectF(self.rect()).adjusted(ring_w, ring_w, -ring_w, -ring_w)

        # заливка (чуть светлее при наведении — единственная реакция на мышь)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(theme.SURFACE_HI if self.underMouse() else theme.SURFACE))
        p.drawEllipse(box)

        # кольцо
        p.setBrush(Qt.NoBrush)
        if self._state == "connecting":
            dim = QColor(color)
            dim.setAlpha(60)
            p.setPen(QPen(dim, ring_w))
            p.drawEllipse(box)
            p.setPen(QPen(color, ring_w, Qt.SolidLine, Qt.RoundCap))
            # Qt считает углы в 1/16 градуса и против часовой стрелки.
            p.drawArc(box, int((90 - self._spin) * 16), -100 * 16)
        else:
            p.setPen(QPen(color, ring_w))
            p.drawEllipse(box)

        mark = QRectF(self.rect()).adjusted(
            self.width() * 0.26, self.height() * 0.26,
            -self.width() * 0.26, -self.height() * 0.26,
        )
        paint_mark(p, mark, None if self._state == "connected" else color)
        p.end()


class ServerDelegate(QStyledItemDelegate):
    """Строка списка серверов как карточка."""

    HEIGHT = 58
    GAP = 4

    def sizeHint(self, option, index) -> QSize:  # noqa: N802
        return QSize(option.rect.width(), self.HEIGHT + self.GAP)

    def paint(self, painter: QPainter, option, index) -> None:
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing, True)

        card = QRectF(option.rect).adjusted(0, 0, 0, -self.GAP)
        selected = bool(option.state & QStyle.State_Selected)
        hovered = bool(option.state & QStyle.State_MouseOver)

        painter.setPen(QPen(QColor(theme.TEAL if selected else theme.STROKE), 1))
        painter.setBrush(QColor(
            theme.SURFACE_HI if (selected or hovered) else theme.SURFACE
        ))
        painter.drawRoundedRect(card.adjusted(0.5, 0.5, -0.5, -0.5), 12, 12)

        pad = 14
        text_rect = card.adjusted(pad, 10, -pad, -10)

        name_font = QFont(painter.font())
        name_font.setPointSizeF(10.0)
        painter.setFont(name_font)

        ping = index.data(ROLE_PING)
        ping_text, ping_color = _ping_label(ping)
        ping_w = 0.0
        if ping_text:
            ping_w = painter.fontMetrics().horizontalAdvance(ping_text) + 10

        painter.setPen(QColor(theme.TEXT))
        name = painter.fontMetrics().elidedText(
            index.data(Qt.DisplayRole) or "", Qt.ElideRight,
            int(text_rect.width() - ping_w),
        )
        painter.drawText(text_rect, Qt.AlignLeft | Qt.AlignTop, name)

        if ping_text:
            painter.setPen(QColor(ping_color))
            painter.drawText(text_rect, Qt.AlignRight | Qt.AlignTop, ping_text)

        sub_font = QFont(painter.font())
        sub_font.setPointSizeF(8.5)
        painter.setFont(sub_font)
        painter.setPen(QColor(theme.DIM))
        painter.drawText(
            text_rect, Qt.AlignLeft | Qt.AlignBottom,
            index.data(ROLE_SUBTITLE) or "",
        )

        painter.restore()


def _ping_label(ping) -> tuple[str, str]:
    """(текст, цвет) для значения пинга."""
    if ping is None:
        return "", theme.DIM
    if ping is False:
        return "нет ответа", theme.RED
    ms = int(ping)
    if ms < 200:
        return f"{ms} мс", theme.TEAL
    if ms < 500:
        return f"{ms} мс", theme.TEXT
    return f"{ms} мс", theme.RED
