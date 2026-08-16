"""Самодельные виджеты, ради которых экран и стал спокойным.

* `PowerButton` — единственный объёмный элемент окна: шайба с радиальной
  заливкой, кромкой и кольцом состояния. Форму кольца задаёт состояние, а не
  цвет: в чёрно-белой теме «подключено» и «ошибка» иначе неотличимы.
* `ServerDelegate` — рисует строку списка плоской: маркер выбора, имя, под ним
  адрес, справа колонка пинга. Карточек нет — строки разделяет волосяная
  линия. Обычный QListWidget с таким делегатом остаётся списком со всеми
  клавишами и прокруткой.
* `LogPane` — полоса с последней строкой лога, разворачивающаяся по щелчку.
* `hairline` — тот самый разделитель в один пиксель.
"""
from __future__ import annotations

import math
import time

from PySide6.QtCore import (
    QEasingCurve,
    QPointF,
    QPropertyAnimation,
    QRectF,
    QSize,
    Qt,
    QTimer,
    QVariantAnimation,
)
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFontMetrics,
    QIcon,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QRadialGradient,
)
from PySide6.QtWidgets import (
    QAbstractButton,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QSizePolicy,
    QStyle,
    QStyledItemDelegate,
    QVBoxLayout,
    QWidget,
)

from . import theme
from .brandmark import paint_mark


def hairline(parent=None) -> QFrame:
    """Разделитель в один пиксель цветом stroke.

    Полосы заголовка у окна нет, и без линии шапка сливается с содержимым;
    строки списка без неё слипаются в одно пятно.
    """
    line = QFrame(parent)
    line.setFixedHeight(theme.HAIRLINE)
    line.setStyleSheet(f"background: {theme.STROKE}; border: none;")
    return line


def _pulse_pixmap(color: str, size: int) -> QPixmap:
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
    return pm


def pulse_icon(color: str = theme.DIM, hover: str = theme.TEXT, size: int = 20) -> QIcon:
    """Значок «пульс» для кнопки пинга — та же кардиограмма, что на Android.

    Две картинки на один значок: подложки под кнопками шапки больше нет, и
    подсветить наведение можно только самим знаком. Qt берёт вариант `Active`,
    когда курсор над кнопкой.
    """
    icon = QIcon()
    icon.addPixmap(_pulse_pixmap(color, size), QIcon.Normal)
    icon.addPixmap(_pulse_pixmap(hover, size), QIcon.Active)
    return icon


# Роли данных для строк списка.
ROLE_SERVER = Qt.UserRole + 1
ROLE_SUBTITLE = Qt.UserRole + 2
ROLE_PING = Qt.UserRole + 3      # int (мс) | None (не мерили) | False (не ответил)


class PowerButton(QAbstractButton):
    """Круглая кнопка подключения. `state`: idle | connecting | connected | error.

    Единственная вещь в окне, у которой есть объём: заливка идёт радиальным
    переходом, будто свет падает сверху, а внутри кольца проходит кромка
    шайбы. Всё остальное на экране плоское, поэтому взгляд идёт сюда первым.

    Состояние показывается формой кольца, а не цветом: подключено — толстое
    сплошное, ошибка — пунктир, простой — тонкое приглушённое. В чёрно-белой
    теме иначе никак, и это осознанное решение доступности.
    """

    # Формы колец приходят из ядра (SCVPNCore.ConnectionState.ring) и одинаковы
    # на всех платформах — здесь их копия для Qt. Менять только вместе с ядром.
    _RING = {
        "idle": (theme.MUTED, 3.0, Qt.SolidLine),
        "connecting": (theme.TEXT, 3.0, Qt.SolidLine),
        "connected": (theme.ACCENT, 5.0, Qt.SolidLine),
        "error": (theme.TEXT, 3.0, Qt.DashLine),
        # Просили отключиться, а туннель остался поднятым: кольцо толстое,
        # как у «подключено» (трафик и правда идёт через VPN), но пунктиром —
        # это не рабочее состояние, а то, что надо разбирать.
        "tun_stuck": (theme.TEXT, 5.0, Qt.DashLine),
    }

    def __init__(self, size: int = theme.POWER_SIDE, parent=None) -> None:
        super().__init__(parent)
        self._state = "idle"
        # Состояние, из которого сейчас растворяемся, и доля перехода.
        self._prev_state = "idle"
        self._fade = 1.0
        self._hover = False
        # Фазы дыхания и дуги считаются от времени, а не от счётчика кадров:
        # иначе они сбивались бы при каждой перерисовке по другому поводу.
        self._since = time.monotonic()

        self.setFixedSize(size, size)
        # Наведение считаем сами, по расстоянию до центра (см. _update_hover).
        self.setMouseTracking(True)

        # Один таймер на всю анимацию — частоту выбирает то, что сейчас
        # показывается: дуга требует полного хода, дыхание обходится 24
        # кадрами, в остальных состояниях не двигается ничего.
        self._timer = QTimer(self)
        self._timer.timeout.connect(self.update)

        # Кольца разных состояний — разные фигуры, поэтому смена идёт
        # растворением одного в другое. Толщину и пунктир между собой не
        # «доанимировать»: пунктир не интерполируется вовсе, а рывок с 3 на 5
        # читался бы как подёргивание.
        self._fade_anim = QVariantAnimation(self)
        self._fade_anim.setDuration(theme.STATE_CHANGE_MS)
        self._fade_anim.setStartValue(0.0)
        self._fade_anim.setEndValue(1.0)
        self._fade_anim.setEasingCurve(QEasingCurve.InOutQuad)
        self._fade_anim.valueChanged.connect(self._on_fade)
        self._fade_anim.finished.connect(self._fade_done)
        self._retune()

    # ------------------------------------------------------------------
    # Состояние
    # ------------------------------------------------------------------
    def set_state(self, state: str) -> None:
        if state == self._state:
            return
        self._prev_state = self._state
        self._state = state
        self._fade_anim.stop()
        self._fade = 0.0
        self._fade_anim.start()
        self._retune()
        self.update()

    def _on_fade(self, value) -> None:
        self._fade = float(value)
        self.update()

    def _fade_done(self) -> None:
        self._fade = 1.0
        self._prev_state = self._state
        self._retune()
        self.update()

    def _retune(self) -> None:
        """Частота перерисовки под то, что сейчас на экране."""
        live = {self._state}
        if self._fade < 1.0:
            live.add(self._prev_state)

        if "connecting" in live:
            interval = int(1000 / theme.POWER_SPIN_FPS)
        elif "idle" in live:
            interval = int(1000 / theme.POWER_BREATH_FPS)
        else:
            interval = 0

        if not interval:
            self._timer.stop()
        elif not self._timer.isActive() or self._timer.interval() != interval:
            self._timer.start(interval)

    # ------------------------------------------------------------------
    # Мышь
    # ------------------------------------------------------------------
    def hitButton(self, pos) -> bool:  # noqa: N802
        """Нажимается ровно круг, а не квадрат вокруг него."""
        radius = self.width() / 2 - self._RING[self._state][1]
        dx = pos.x() - self.width() / 2
        dy = pos.y() - self.height() / 2
        return dx * dx + dy * dy <= radius * radius

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        # Наведение считается по расстоянию до центра, а не по underMouse():
        # тот отвечает за прямоугольную рамку виджета, и курсор в её углу — за
        # сотню пикселей от кольца — зажигал бы заливку.
        self._update_hover(self.hitButton(event.position().toPoint()))
        super().mouseMoveEvent(event)

    def leaveEvent(self, event) -> None:  # noqa: N802
        self._update_hover(False)
        super().leaveEvent(event)

    def _update_hover(self, inside: bool) -> None:
        if inside == self._hover:
            return
        self._hover = inside
        self.setCursor(Qt.PointingHandCursor if inside else Qt.ArrowCursor)
        self.update()

    # ------------------------------------------------------------------
    # Отрисовка
    # ------------------------------------------------------------------
    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)

        fading = self._fade < 1.0 and self._prev_state != self._state
        prev_w = self._RING[self._prev_state][1]
        cur_w = self._RING[self._state][1]
        # Шайба одна на все состояния, меняется только её кромка вместе с
        # толщиной кольца — поэтому рисуем её один раз и по промежуточной
        # толщине: иначе на переходе радиус прыгал бы на два пикселя.
        self._paint_disc(p, prev_w + (cur_w - prev_w) * self._fade if fading else cur_w)

        if fading:
            p.setOpacity(1.0 - self._fade)
            self._paint_state(p, self._prev_state)
            p.setOpacity(self._fade)
            self._paint_state(p, self._state)
        else:
            self._paint_state(p, self._state)
        p.end()

    def _paint_disc(self, p: QPainter, inset: float) -> None:
        side = self.width()
        box = QRectF(self.rect()).adjusted(inset, inset, -inset, -inset)

        # Свет сверху: центр перехода смещён вверх, к краям шайба уходит в фон.
        # При наведении заливка светлеет на ступень — единственная реакция на
        # мышь, подложек и рамок у кнопки нет.
        cx, cy = theme.POWER_LIGHT
        grad = QRadialGradient(
            QPointF(box.left() + box.width() * cx, box.top() + box.height() * cy),
            side * theme.POWER_LIGHT_RADIUS,
        )
        grad.setColorAt(0.0, QColor(theme.STROKE if self._hover else theme.SURFACE_HI))
        grad.setColorAt(1.0, QColor(theme.SURFACE))
        p.setPen(Qt.NoPen)
        p.setBrush(QBrush(grad))
        p.drawEllipse(box)

        # Кромка шайбы. Тонкая и заметно меньше кольца состояния — спутать их
        # нельзя, а плоский круг она превращает в предмет.
        edge = side * theme.POWER_EDGE_INSET
        p.setBrush(Qt.NoBrush)
        p.setPen(QPen(QColor(theme.STROKE), theme.HAIRLINE))
        p.drawEllipse(box.adjusted(edge, edge, -edge, -edge))

    def _paint_state(self, p: QPainter, state: str) -> None:
        name, ring_w, style = self._RING[state]
        color = QColor(name)
        box = QRectF(self.rect()).adjusted(ring_w, ring_w, -ring_w, -ring_w)
        elapsed = time.monotonic() - self._since

        p.setBrush(Qt.NoBrush)
        if state == "connecting":
            # Тусклое кольцо целиком плюс яркая дуга, бегущая по нему.
            track = QColor(color)
            track.setAlphaF(theme.POWER_TRACK_OPACITY)
            p.setPen(QPen(track, ring_w))
            p.drawEllipse(box)

            turn = (elapsed % theme.POWER_SPIN) / theme.POWER_SPIN
            p.setPen(QPen(color, ring_w, Qt.SolidLine, Qt.RoundCap))
            # Qt считает углы в 1/16 градуса и против часовой стрелки.
            p.drawArc(box, int((90 - turn * 360) * 16), int(-theme.POWER_ARC_DEG * 16))
        elif state == "idle":
            # Дыхание нужно затем, что в простое окно выглядит замёрзшим: ни
            # одного движущегося пикселя, и непонятно, живо ли приложение.
            # Меняется только яркость — форма кольца, по которой состояния и
            # различаются, остаётся прежней.
            t = (elapsed % theme.POWER_BREATH) / theme.POWER_BREATH
            # Синус даёт плавный разворот на обоих концах: без него вдох и
            # выдох стыкуются рывком.
            wave = (1 - math.cos(2 * math.pi * t)) / 2
            low = theme.POWER_BREATH_LOW
            breath = QColor(color)
            breath.setAlphaF(low + (1 - low) * wave)
            p.setPen(QPen(breath, ring_w))
            p.drawEllipse(box)
        else:
            pen = QPen(color, ring_w, style)
            if style == Qt.DashLine:
                pen.setDashPattern([3, 3])   # в долях толщины линии
            p.setPen(pen)
            p.drawEllipse(box)

        # При «подключено» знак рисуется фирменным градиентом, в остальных
        # состояниях — цветом состояния.
        mark = self.width() * 0.48
        centre = QRectF(
            (self.width() - mark) / 2, (self.height() - mark) / 2, mark, mark
        )
        paint_mark(p, centre, None if state == "connected" else color)


class ServerDelegate(QStyledItemDelegate):
    """Плоская строка списка серверов.

    Карточки с рамками не осталось: строки разделяет волосяная линия. Так
    список весит меньше кнопки питания — единственного объёмного элемента
    окна, — а раньше десяток одинаково обведённых карточек забирал внимание на
    себя.

    Выбор показывается маркером слева и яркостью имени, а не обводкой: разница
    между рамкой в 1 и 1.5 пикселя того же белого на чёрном почти не читалась.
    """

    def sizeHint(self, option, index) -> QSize:  # noqa: N802
        return QSize(option.rect.width(), theme.ROW_HEIGHT)

    def paint(self, painter: QPainter, option, index) -> None:
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing, True)

        row = QRectF(option.rect)
        selected = bool(option.state & QStyle.State_Selected)
        hovered = bool(option.state & QStyle.State_MouseOver)
        pressed = bool(option.state & QStyle.State_Sunken)

        # Подсветка идёт от края до края окна: нажимается вся полоса, и это
        # должно быть видно. Поля живут внутри строки, а не в отступах списка.
        if pressed or hovered:
            painter.fillRect(
                row, QColor(theme.SURFACE_HI if pressed else theme.SURFACE)
            )

        if selected:
            marker = QRectF(
                row.left() + theme.LIST_PADDING,
                row.top() + theme.ROW_MARKER_INSET,
                theme.ROW_MARKER,
                row.height() - 2 * theme.ROW_MARKER_INSET,
            )
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(theme.ACCENT))
            painter.drawRoundedRect(marker, theme.ROW_MARKER / 2, theme.ROW_MARKER / 2)

        # Колонка пинга постоянной ширины: значения выравниваются по правому
        # краю и читаются столбиком, а не пляшут за именем.
        ping_right = row.right() - theme.LIST_PADDING
        ping_left = ping_right - theme.PING_COLUMN
        text_left = row.left() + theme.SECTION_PADDING
        text_width = max(0.0, ping_left - theme.ROW_GAP - text_left)

        name_font = theme.font_row_title()
        detail_font = theme.font_row_detail()
        fm_name = QFontMetrics(name_font)
        fm_detail = QFontMetrics(detail_font)
        block = fm_name.height() + theme.ROW_TEXT_SPACING + fm_detail.height()
        top = row.top() + (row.height() - block) / 2

        painter.setFont(name_font)
        # Имя приглушено у невыбранных строк: выбор — это яркость и маркер.
        painter.setPen(QColor(theme.TEXT if selected else theme.DIM))
        painter.drawText(
            QRectF(text_left, top, text_width, fm_name.height()),
            Qt.AlignLeft | Qt.AlignVCenter,
            fm_name.elidedText(index.data(Qt.DisplayRole) or "", Qt.ElideRight, int(text_width)),
        )

        # Адрес яркость не теряет: иначе он уходит под порог читаемости.
        painter.setFont(detail_font)
        painter.setPen(QColor(theme.DIM))
        painter.drawText(
            QRectF(
                text_left,
                top + fm_name.height() + theme.ROW_TEXT_SPACING,
                text_width,
                fm_detail.height(),
            ),
            Qt.AlignLeft | Qt.AlignVCenter,
            fm_detail.elidedText(index.data(ROLE_SUBTITLE) or "", Qt.ElideRight, int(text_width)),
        )

        text, color = _ping_label(index.data(ROLE_PING))
        painter.setFont(theme.font_row_ping())
        painter.setPen(QColor(color))
        painter.drawText(
            QRectF(ping_left, row.top(), theme.PING_COLUMN, row.height()),
            Qt.AlignRight | Qt.AlignVCenter,
            text,
        )

        # У последней строки линии нет: под ней и так край списка.
        model = index.model()
        if model is not None and index.row() < model.rowCount() - 1:
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(theme.STROKE))
            painter.drawRect(QRectF(
                row.left() + theme.LIST_PADDING,
                row.bottom() - theme.STROKE_W,
                row.width() - theme.LIST_PADDING,
                theme.STROKE_W,
            ))

        painter.restore()


def _ping_label(ping) -> tuple[str, str]:
    """(текст, цвет) для значения пинга.

    В чёрно-белой теме «хорошо/плохо» показывается яркостью: чем медленнее,
    тем тусклее. Отсутствие ответа подписано словами — одной яркости для
    такого важного случая мало. До замера стоит прочерк, а не пустота: пустое
    место справа выглядит так, будто строку не дорисовали.
    """
    if ping is None:
        return "—", theme.MUTED
    if ping is False:
        return "нет ответа", theme.MUTED
    ms = int(ping)
    if ms < 200:
        return f"{ms} мс", theme.TEXT
    if ms < 500:
        return f"{ms} мс", theme.DIM
    return f"{ms} мс", theme.MUTED


class _HeadElidedLabel(QLabel):
    """Однострочная подпись, обрезанная С НАЧАЛА.

    У сообщения ядра важен хвост: «[!] Не удалось…» с обрезанным концом не
    говорит ничего, а начало строки — это метка уровня, которую видно и так.
    """

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._full = ""
        # Ширину подписи спрашивать нельзя: длинная строка ядра требовала бы
        # её целиком и растягивала окно. Полосе даёт ширину раскладка, а текст
        # под неё подрезается.
        self.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)

    def set_full_text(self, text: str) -> None:
        self._full = text
        self._relayout()

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        self._relayout()

    def _relayout(self) -> None:
        metrics = QFontMetrics(self.font())
        super().setText(metrics.elidedText(self._full, Qt.ElideLeft, max(0, self.width())))


class LogPane(QWidget):
    """Лог ядра: полоса с последней строкой, по щелчку — разворот.

    Раньше это была коробка в 130 px, занимавшая низ окна всегда — в том числе
    пустая, пока ядро не запущено. Читают лог ради последней строки, поэтому по
    умолчанию видна ровно она.

    Развёрнутость нигде не сохраняется: это состояние взгляда, а не
    приложения — лог разворачивают, чтобы посмотреть здесь и сейчас.
    """

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("logPane")
        # Обычный QWidget фон из таблицы стилей не красит, пока не сказано.
        self.setAttribute(Qt.WA_StyledBackground, True)
        self._expanded = False

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(hairline(self))

        strip = QWidget()
        strip.setObjectName("logStrip")
        strip.setAttribute(Qt.WA_StyledBackground, True)
        strip.setFixedHeight(theme.LOG_STRIP_H)
        strip.setCursor(Qt.PointingHandCursor)
        line = QHBoxLayout(strip)
        line.setContentsMargins(theme.LIST_PADDING, 0, theme.LIST_PADDING, 0)
        line.setSpacing(theme.ROW_GAP)

        self._chevron = QLabel("▸")
        self._chevron.setObjectName("logChevron")
        line.addWidget(self._chevron)

        self._last = _HeadElidedLabel()
        self._last.setObjectName("logLine")
        self._last.setFont(theme.mono_font())
        self._last.set_full_text("Лог ядра пуст")
        line.addWidget(self._last, 1)
        root.addWidget(strip)

        self._body = QPlainTextEdit()
        self._body.setObjectName("log")
        self._body.setReadOnly(True)
        self._body.setFont(theme.mono_font())
        self._body.setMaximumBlockCount(2000)
        self._body.setFrameShape(QFrame.NoFrame)
        # Свёрнутый лог занимает ноль по высоте, а не прячется: так его можно
        # разворачивать тем же растворением, что и смену состояния.
        self._body.setMinimumHeight(0)
        self._body.setMaximumHeight(0)
        root.addWidget(self._body)

        self._anim = QPropertyAnimation(self._body, b"maximumHeight", self)
        self._anim.setDuration(theme.STATE_CHANGE_MS)
        self._anim.setEasingCurve(QEasingCurve.InOutQuad)

        # Щелчок по всей полосе, а не по галочке: попадать мышью в знак в
        # девять пикселей — работа, которой пользователь не просил.
        self._strip = strip
        strip.mousePressEvent = self._strip_clicked

    # ------------------------------------------------------------------
    def append(self, text: str) -> None:
        self._body.appendPlainText(text)
        # В свёрнутом виде видна ровно последняя строка — она и есть весь лог
        # для того, кто на него смотрит.
        self._last.set_full_text(text)

    def _strip_clicked(self, event) -> None:
        self.set_expanded(not self._expanded)
        event.accept()

    def set_expanded(self, expanded: bool) -> None:
        self._expanded = expanded
        self._chevron.setText("▾" if expanded else "▸")
        self._strip.setToolTip("Свернуть лог" if expanded else "Развернуть лог")
        self._anim.stop()
        self._anim.setStartValue(self._body.maximumHeight())
        self._anim.setEndValue(theme.LOG_HEIGHT if expanded else 0)
        self._anim.start()
