"""Палитра и таблица стилей SCVPN — одно место на всё приложение.

Тема одна: чёрно-белая. Цвета нет вообще, только градации серого — поэтому
состояния приходится различать не оттенком, а формой: кольцо кнопки при ошибке
рисуется пунктиром, при подключении — толще, а «плохой» пинг вдобавок к
приглушённому серому подписан словами. Если бы состояния отличались только
яркостью, «подключено» и «ошибка» читались бы одинаково.

Те же значения продублированы в android/app/src/main/res/values/colors.xml.
"""
from __future__ import annotations

import sys

# Системный шрифт интерфейса: на macOS это SF, на Windows — Segoe UI.
UI_FONT = '-apple-system, "SF Pro Text"' if sys.platform == "darwin" else '"Segoe UI"'
MONO_FONT = "Menlo" if sys.platform == "darwin" else "Consolas"

BG = "#000000"
SURFACE = "#0D0D0D"
SURFACE_HI = "#1C1C1C"
STROKE = "#333333"

TEXT = "#FFFFFF"
DIM = "#8C8C8C"
MUTED = "#5A5A5A"

# Акцент — тоже белый: выделение показывается яркостью и рамкой, не цветом.
ACCENT = "#FFFFFF"

QSS = f"""
QMainWindow, QWidget {{
    background: {BG};
    color: {TEXT};
    font-family: {UI_FONT}, sans-serif;
    font-size: 13px;
}}

/* Подписи не красят фон: иначе на диалогах (они светлее окна) под каждой
   строкой проступала бы полоса цвета основного фона. */
QLabel {{ background: transparent; }}

QLabel#wordmark {{
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 3px;
    color: {TEXT};
}}
QLabel#status    {{ font-size: 20px; font-weight: 700; }}
QLabel#substatus {{ font-size: 12px; color: {DIM}; }}
QLabel#section   {{
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 1.5px;
    color: {DIM};
}}

/* Плоские кнопки шапки */
QToolButton {{
    background: transparent;
    border: none;
    border-radius: 8px;
    color: {DIM};
    font-size: 17px;
    padding: 0;
}}
QToolButton:hover   {{ background: {SURFACE_HI}; color: {TEXT}; }}
QToolButton:pressed {{ background: {STROKE}; }}
QToolButton::menu-indicator {{ image: none; }}

QListWidget {{
    background: transparent;
    border: none;
    outline: none;
}}

/* Переключатели: системная отрисовка на тёмном фоне даёт тёмное на тёмном,
   поэтому индикаторы рисуем сами. */
QRadioButton, QCheckBox {{ background: transparent; spacing: 9px; padding: 3px 0; }}
QRadioButton::indicator, QCheckBox::indicator,
QListWidget::indicator {{
    width: 15px; height: 15px;
    border: 1px solid {DIM};
    background: {BG};
}}
QRadioButton::indicator {{ width: 16px; height: 16px; border-radius: 9px; }}
QRadioButton::indicator:checked {{
    /* Точку рисуем градиентом, а не толстой рамкой: Qt не скругляет широкую
       рамку и вместо кружка получается квадрат со скруглениями. */
    border: 1px solid {ACCENT};
    border-radius: 9px;
    background: qradialgradient(cx:0.5, cy:0.5, radius:0.5, fx:0.5, fy:0.5,
                stop:0 {ACCENT}, stop:0.45 {ACCENT}, stop:0.5 {BG}, stop:1 {BG});
}}
QCheckBox::indicator, QListWidget::indicator {{ border-radius: 4px; }}
QCheckBox::indicator:checked, QListWidget::indicator:checked {{
    background: {ACCENT};
    border-color: {ACCENT};
}}
QRadioButton::indicator:hover, QCheckBox::indicator:hover,
QListWidget::indicator:hover {{ border-color: {ACCENT}; }}

QMenu {{
    background: {SURFACE};
    border: 1px solid {STROKE};
    border-radius: 8px;
    padding: 6px;
}}
QMenu::item {{ padding: 6px 26px 6px 22px; border-radius: 6px; }}
QMenu::item:selected {{ background: {SURFACE_HI}; }}
QMenu::separator {{ height: 1px; background: {STROKE}; margin: 6px 8px; }}

QPlainTextEdit {{
    background: {SURFACE};
    border: 1px solid {STROKE};
    border-radius: 10px;
    color: {DIM};
    font-family: {MONO_FONT}, monospace;
    font-size: 11px;
    padding: 8px;
}}

QScrollBar:vertical {{
    background: transparent; width: 8px; margin: 0;
}}
QScrollBar::handle:vertical {{
    background: {STROKE}; border-radius: 4px; min-height: 30px;
}}
QScrollBar::handle:vertical:hover {{ background: {DIM}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

/* Диалоги (ввод ссылки, вопросы) в той же гамме */
QDialog, QMessageBox, QInputDialog {{ background: {SURFACE}; }}
QLineEdit {{
    background: {BG};
    border: 1px solid {STROKE};
    border-radius: 8px;
    padding: 7px 10px;
    color: {TEXT};
    selection-background-color: {STROKE};
    selection-color: {TEXT};
}}
QLineEdit:focus {{ border-color: {ACCENT}; }}
QPushButton {{
    background: {SURFACE_HI};
    border: 1px solid {STROKE};
    border-radius: 8px;
    padding: 7px 16px;
    color: {TEXT};
}}
QPushButton:hover  {{ border-color: {DIM}; }}
QPushButton:default {{ border-color: {ACCENT}; }}
"""


# ----------------------------------------------------------------------
# Значки диалогов и полоса заголовка
# ----------------------------------------------------------------------
# Системные значки QMessageBox нарисованы для светлой темы: на чёрном фоне
# вопросительный знак получается тёмно-серым на чёрном и почти не виден.
# Рисуем свои — в той же гамме, что и всё остальное: кольцо приглушённое,
# сам знак белый.
_MSG_GLYPHS = {
    "SP_MessageBoxQuestion": "?",
    "SP_MessageBoxInformation": "i",
    "SP_MessageBoxWarning": "!",
    "SP_MessageBoxCritical": "✕",
}

_ICON_PX = 64


def _glyph_icon(glyph: str) -> "QIcon":
    from PySide6.QtCore import QRectF, Qt
    from PySide6.QtGui import QColor, QFont, QIcon, QPainter, QPen, QPixmap

    # Рисуем вдвое крупнее и говорим Qt, что это ретина: иначе на экране с
    # масштабом 2 значок размывается.
    scale = 2
    pm = QPixmap(_ICON_PX * scale, _ICON_PX * scale)
    pm.fill(Qt.transparent)
    pm.setDevicePixelRatio(scale)

    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    # Рисуем в логических точках, а не в пикселях: QPainter по ретинному
    # QPixmap сам домножает координаты на devicePixelRatio, и side в пикселях
    # дал бы круг вчетверо больше холста — от него в кадр попадала бы четверть.
    side = _ICON_PX
    inset = side * 0.08
    ring = QRectF(inset, inset, side - 2 * inset, side - 2 * inset)
    p.setPen(QPen(QColor(DIM), side * 0.045))
    p.drawEllipse(ring)

    font = QFont()
    font.setPixelSize(int(side * 0.56))
    font.setWeight(QFont.DemiBold)
    p.setFont(font)
    p.setPen(QColor(TEXT))
    p.drawText(ring, Qt.AlignCenter, glyph)
    p.end()
    return QIcon(pm)


def _icon_style():
    """Стиль, подменяющий только значки диалогов. Всё прочее — как было."""
    from PySide6.QtWidgets import QProxyStyle, QStyle

    glyphs = {getattr(QStyle, name): glyph for name, glyph in _MSG_GLYPHS.items()}

    class _MessageIconStyle(QProxyStyle):
        def standardIcon(self, standard_icon, option=None, widget=None):  # noqa: N802
            glyph = glyphs.get(standard_icon)
            if glyph is None:
                return super().standardIcon(standard_icon, option, widget)
            return _glyph_icon(glyph)

    return _MessageIconStyle()


def _titlebar_filter():
    """Фильтр, гасящий фон полосы заголовка у диалогов (только macOS).

    Главное окно делает это у себя в __init__ теми же двумя флагами, а
    диалоги создаёт Qt — до их окон дотянуться можно только по событию показа.
    Флага мало одного: NoTitleBarBackgroundHint убирает фон полосы, а
    ExpandedClientAreaHint заводит под неё содержимое окна, и только вместе
    они дают полосу цвета самого диалога, а не дыру и не системный серый.
    Раз содержимое уезжает под полосу, ему добавляется верхний отступ — иначе
    первая строка текста оказалась бы под светофором.
    """
    from PySide6.QtCore import QEvent, QObject, Qt
    from PySide6.QtWidgets import QDialog

    class _TitleBar(QObject):
        def eventFilter(self, obj, event) -> bool:  # noqa: N802
            if event.type() == QEvent.Show and isinstance(obj, QDialog):
                obj.winId()                      # без этого окна ещё нет
                handle = obj.windowHandle()
                if handle is not None and not obj.property("_scvpn_chrome"):
                    obj.setProperty("_scvpn_chrome", True)
                    handle.setFlags(
                        handle.flags()
                        | Qt.ExpandedClientAreaHint
                        | Qt.NoTitleBarBackgroundHint
                    )
                    layout = obj.layout()
                    if layout is not None:
                        m = layout.contentsMargins()
                        layout.setContentsMargins(
                            m.left(), m.top() + TITLEBAR_H, m.right(), m.bottom()
                        )
            return False

    return _TitleBar()


# Фильтр живёт здесь, а не родителем у QApplication: приложение приходит в
# apply() каким угодно (в проверках — заглушкой), а фильтр без ссылки на себя
# соберётся сборщиком мусора сразу после apply(), и диалоги останутся с
# системной серой полосой.
_filters: list = []


# Высота системной полосы заголовка, на которую опускается содержимое диалога.
TITLEBAR_H = 28


def apply(app) -> None:
    """Одна точка входа: палитра, значки диалогов, полоса заголовка."""
    app.setStyle(_icon_style())
    app.setStyleSheet(QSS)
    if sys.platform == "darwin":
        _filters.append(_titlebar_filter())
        app.installEventFilter(_filters[-1])
