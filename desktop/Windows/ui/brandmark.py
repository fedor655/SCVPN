"""Фирменный знак «S», нарисованный средствами Qt.

Геометрия та же, что у готовых иконок и у macOS/Android-версий:
две касающиеся окружности, осевая обводится штрихом с круглыми концами,
каждая чаша раскрыта на 255°. Здесь рисуем векторно, чтобы знак был чётким
на любом масштабе и его можно было перекрашивать под состояние.

Про углы: у PIL точка дуги — center + r·(cos a, sin a) при оси Y вниз, а Qt
считает углы против часовой (center + r·(cos θ, −sin θ)). Поэтому θ = −a, и
дуги ниже заданы уже в системе Qt.
"""
from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QBrush, QColor, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap

# Палитра — общая с иконкой и с Android. Знак белый; лёгкий переход к светло-
# серому нужен только чтобы крупная фигура не выглядела плоской заливкой.
MARK_TOP = "#FFFFFF"
MARK_BOTTOM = "#C4C4C4"

_R = 0.155      # радиус осевой в долях канвы
_W = 0.090      # толщина штриха в долях канвы
_SWEEP = 255    # раскрытие каждой чаши, градусов


def mark_path(size: float) -> tuple[QPainterPath, float]:
    """Путь знака, вписанный в квадрат size×size. Возвращает (путь, толщина)."""
    r = size * _R
    w = size * _W
    cx = cy = size / 2.0

    def rect(centre_y: float) -> QRectF:
        return QRectF(cx - r, centre_y - r, 2 * r, 2 * r)

    top = rect(cy - r)
    bottom = rect(cy + r)

    path = QPainterPath()
    # Верхняя чаша: от свободного конца (θ=15°) по дуге до точки касания (θ=270°).
    path.arcMoveTo(top, 15)
    path.arcTo(top, 15, _SWEEP)
    # Нижняя — от той же точки касания (θ=90° своей окружности) в обратную сторону.
    path.arcTo(bottom, 90, -_SWEEP)
    return path, w


def paint_mark(
    painter: QPainter,
    rect: QRectF,
    color: QColor | None = None,
    width_scale: float = 1.0,
) -> None:
    """Нарисовать знак внутри rect. Без `color` — фирменный градиент."""
    side = min(rect.width(), rect.height())
    path, w = mark_path(side)

    if color is None:
        grad = QLinearGradient(QPointF(0, side * 0.2), QPointF(0, side * 0.8))
        grad.setColorAt(0.0, QColor(MARK_TOP))
        grad.setColorAt(1.0, QColor(MARK_BOTTOM))
        brush = QBrush(grad)
    else:
        brush = QBrush(color)

    pen = QPen(brush, w * width_scale)
    pen.setCapStyle(Qt.RoundCap)
    pen.setJoinStyle(Qt.RoundJoin)

    painter.save()
    painter.setRenderHint(QPainter.Antialiasing, True)
    painter.translate(
        rect.left() + (rect.width() - side) / 2,
        rect.top() + (rect.height() - side) / 2,
    )
    painter.setPen(pen)
    painter.setBrush(Qt.NoBrush)
    painter.drawPath(path)
    painter.restore()


def mark_pixmap(size: int, color: QColor | None = None) -> QPixmap:
    """Знак как готовая картинка на прозрачном фоне."""
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    paint_mark(p, QRectF(0, 0, size, size), color)
    p.end()
    return pm
