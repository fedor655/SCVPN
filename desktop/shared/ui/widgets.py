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
from PySide6.QtGui import QColor, QFont, QIcon, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import QAbstractButton, QStyle, QStyledItemDelegate

from . import theme
from .brandmark import paint_mark


def pulse_icon(color: str, size: int = 20) -> QIcon:
    """Значок «пульс» для кнопки пинга — та же кардиограмма, что на Android."""
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing, True)
    pen = QPen(QColor(color), max(1.4, size * 0.10))
    pen.setCapStyle(Qt.RoundCap)
    pen.setJoinStyle(Qt.RoundJoin)
    p.setPen(pen)
    s = size / 24.0
    pts = [(3, 12), (8, 12), (10.5, 6.5), (14, 17.5), (16, 12), (21, 12)]
    path = QPainterPath()
    path.moveTo(pts[0][0] * s, pts[0][1] * s)
    for x, y in pts[1:]:
        path.lineTo(x * s, y * s)
    p.drawPath(path)
    p.end()
    return QIcon(pm)

# Роли данных для строк списка.
ROLE_SERVER = Qt.UserRole + 1
ROLE_SUBTITLE = Qt.UserRole + 2
ROLE_PING = Qt.UserRole + 3      # int (мс) | None (не мерили) | False (не ответил)


class PowerButton(QAbstractButton):
    """Круглая кнопка подключения. `state`: idle | connecting | connected | error."""

    # Цветом состояния в чёрно-белой теме не различить, поэтому кольцо меняет
    # ещё и вид: подключено — толстое сплошное, ошибка — пунктир, простой —
    # тонкое приглушённое.
    _RING = {
        "idle": (theme.MUTED, 3.0, Qt.SolidLine),
        "connecting": (theme.TEXT, 3.0, Qt.SolidLine),
        "connected": (theme.ACCENT, 5.0, Qt.SolidLine),
        "error": (theme.TEXT, 3.0, Qt.DashLine),
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

        name, ring_w, style = self._RING[self._state]
        color = QColor(name)
        inset = ring_w
        box = QRectF(self.rect()).adjusted(inset, inset, -inset, -inset)

        # заливка (чуть светлее при наведении — единственная реакция на мышь)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(theme.SURFACE_HI if self.underMouse() else theme.SURFACE))
        p.drawEllipse(box)

        # кольцо
        p.setBrush(Qt.NoBrush)
        if self._state == "connecting":
            dim = QColor(color)
            dim.setAlpha(55)
            p.setPen(QPen(dim, ring_w))
            p.drawEllipse(box)
            p.setPen(QPen(color, ring_w, Qt.SolidLine, Qt.RoundCap))
            # Qt считает углы в 1/16 градуса и против часовой стрелки.
            p.drawArc(box, int((90 - self._spin) * 16), -100 * 16)
        else:
            pen = QPen(color, ring_w, style)
            if style == Qt.DashLine:
                pen.setDashPattern([3, 3])   # в долях толщины линии
            p.setPen(pen)
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

        painter.setPen(QPen(QColor(theme.ACCENT if selected else theme.STROKE), 1))
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
    """(текст, цвет) для значения пинга.

    В чёрно-белой теме «хорошо/плохо» показывается яркостью: чем медленнее,
    тем тусклее. Отсутствие ответа подписано словами — одной яркости для
    такого важного случая мало.
    """
    if ping is None:
        return "", theme.DIM
    if ping is False:
        return "нет ответа", theme.MUTED
    ms = int(ping)
    if ms < 200:
        return f"{ms} мс", theme.TEXT
    if ms < 500:
        return f"{ms} мс", theme.DIM
    return f"{ms} мс", theme.MUTED
