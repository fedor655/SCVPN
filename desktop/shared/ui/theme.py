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

# ----------------------------------------------------------------------
# Метрики окна
# ----------------------------------------------------------------------
# Те же числа, что в desktop/macOS/.../Views/Style.swift: окно обязано
# узнаваться на всех платформах, а разъезжаются размеры молча — их никто не
# сверяет тестом, в отличие от цветов. Поэтому один список на весь Qt-клиент,
# и правится он вместе со Style.swift.
#
# Цвета сюда не переезжают и остаются выше: их сверяет с colors.xml тест ядра,
# и второй список цветов разошёлся бы с Android незаметно.

# --- Шапка ---
# Вертикаль шапки менять нельзя: по этим же числам на macOS опускается
# светофор (native.titlebar.sink), и сдвиг разведёт кнопки окна с надписью.
HEADER_TOP = 12
HEADER_BOTTOM = 10
HEADER_BTN = 28
# Размер самого знака в кнопке шапки.
HEADER_ICON = 14
# Просвет между кнопками: ноль. Подложек у них больше нет, и только вплотную
# они читаются как одна группа, а не как четыре знака подряд.
HEADER_SPACING = 0
HEADER_TRAILING = 16
# От знака «S» до слова SCVPN. На macOS знака в шапке нет — там тесно от
# кнопок окна, — поэтому отступ живёт только в Windows-ветке.
HEADER_BADGE_GAP = 10

# Толщина разделительных линий.
HAIRLINE = 1
STROKE_W = 1

# --- Кнопка питания ---
# Кнопка — единственный объёмный элемент окна, поэтому она крупная.
POWER_SIDE = 156
# Центр радиальной заливки: свет падает сверху, к краям шайба уходит в фон.
POWER_LIGHT = (0.5, 0.34)
POWER_LIGHT_RADIUS = 0.62
# Внутренняя кромка шайбы: отступ от кольца состояния в долях стороны.
POWER_EDGE_INSET = 0.11
# Секунд на оборот бегущей дуги и её раскрытие в градусах.
POWER_SPIN = 1.4
POWER_ARC_DEG = 100
# Насколько притушено кольцо-подложка под бегущей дугой.
POWER_TRACK_OPACITY = 0.22
# Секунд на полный вдох-выдох кольца в простое и до какой яркости оно притухает.
POWER_BREATH = 3.6
POWER_BREATH_LOW = 0.5
# Частота перерисовки «дыхания». Двадцать четыре кадра хватает для медленного
# затухания, а окно висит открытым часами — гонять ради него полный refresh
# rate незачем.
POWER_BREATH_FPS = 24
# Кадр бегущей дуги: она заметно быстрее дыхания, ей нужен полный ход.
POWER_SPIN_FPS = 60

# Переход между состояниями, мс. Четверть секунды — столько, чтобы глаз успел
# заметить смену и не начал ждать.
STATE_CHANGE_MS = 250

# --- Блок статуса ---
POWER_BLOCK_PADDING = 14
STATUS_TOP = 12
SUBSTATUS_TOP = 4
SUBSTATUS_PADDING = 20
# Между строкой подробностей и подписью режима.
SUBSTATUS_LINE_GAP = 4
# Высота блока подробностей. Он переключается с одной строки на две, и без
# запаса список серверов подпрыгивал бы при каждой смене состояния.
SUBSTATUS_HEIGHT = 34

# --- Список серверов ---
# Просвета между строками нет: их разделяет линия, а не пустота.
LIST_SPACING = 0
# Поле слева и справа от содержимого строки. Подсветка под курсором при этом
# идёт от края до края — нажимается вся полоса, а не карточка.
LIST_PADDING = 16
LIST_BOTTOM = 10
ROW_HEIGHT = 52
# Ширина маркера выбранной строки и насколько он короче строки сверху и снизу.
ROW_MARKER = 2
ROW_MARKER_INSET = 13
# От маркера до текста.
ROW_TEXT_LEADING = 12
# Между именем сервера и строкой с адресом.
ROW_TEXT_SPACING = 3
# Между текстом и пингом.
ROW_GAP = 8
# Ширина колонки пинга. Постоянная: иначе правый край значений гуляет от
# строки к строке и колонки не получается вовсе. Считана по самой длинной
# подписи — «нет ответа».
PING_COLUMN = 72

# Заголовок раздела встаёт ровно над именами серверов, а не над краем строки:
# колонка текста — самая заметная вертикаль в списке.
SECTION_PADDING = LIST_PADDING + ROW_MARKER + ROW_TEXT_LEADING
SECTION_BOTTOM = 8

# --- Пустой список ---
# Между «что случилось» и «что делать».
EMPTY_GAP = 8
EMPTY_PADDING = 24

# --- Лог ---
# Свёрнутая полоса с последней строкой и развёрнутый лог.
LOG_STRIP_H = 26
LOG_HEIGHT = 130
LOG_PADDING = 8

# --- Окна поверх главного ---
# Ширина у всех одна. Раньше их было четыре — 420, 430, 440 и 520, — и окна
# прыгали по ширине, стоило открыть два подряд.
SHEET_WIDTH = 440
SHEET_PAD_H = 18
SHEET_PAD_V = 16
# Между блоками внутри окна.
SHEET_GAP = 10
# Скругление вложенных панелей: поля ввода, списки, карточки подписок.
# Одно на всё — прежде соседние панели скруглялись на 8 и на 10.
BOX_CORNER = 8

# ----------------------------------------------------------------------
# Шкала шрифтов
# ----------------------------------------------------------------------
# Шкала намеренно разорвана: 26 px на состояние подключения и 10–13 px на всё
# остальное. Промежуточных размеров нет — каждый лишний шаг снова размывает
# разницу между главной надписью окна и служебными.
FS_STATUS = 26        # состояние подключения
FS_ROW_TITLE = 13     # имя сервера, оно же базовый размер интерфейса
FS_BODY = 12          # подстатус, тексты в окнах
FS_DETAIL = 11        # адрес, пинг, пояснения
FS_SECTION = 10       # подписи разделов
FS_WORDMARK = 12      # знак SCVPN
FS_MONO = 10          # лог

# Разрядка тем шире, чем мельче и служебнее надпись: у знака и заголовков
# разделов она растягивает строку в полоску, у крупного статуса — наоборот
# стягивает, иначе 26 px рассыпаются на буквы.
#
# Живёт в QFont, а не в QSS: `letter-spacing` Qt в таблице стилей не понимает
# и молча выбрасывает — прежние `letter-spacing: 3px` у знака не рисовались
# вовсе.
SECTION_TRACKING = 2.0
WORDMARK_TRACKING = 4.0
STATUS_TRACKING = -0.4

QSS = f"""
QMainWindow, QWidget {{
    background: {BG};
    color: {TEXT};
    font-family: {UI_FONT}, sans-serif;
    font-size: {FS_ROW_TITLE}px;
}}

/* Подписи не красят фон: иначе на диалогах (они светлее окна) под каждой
   строкой проступала бы полоса цвета основного фона. */
QLabel {{ background: transparent; }}

/* Размеры и начертания дублируются в QFont (см. font_* ниже): таблица стилей
   перебивает шрифт виджета в тех свойствах, которые задаёт сама. Числа при
   этом одни и те же — и здесь, и там они берутся из шкалы выше. */
QLabel#wordmark  {{ font-size: {FS_WORDMARK}px; font-weight: 700; color: {TEXT}; }}
/* Состояние не красится по-разному: в чёрно-белой теме его различает форма
   кольца, а не яркость надписи. */
QLabel#status    {{ font-size: {FS_STATUS}px; font-weight: 600; color: {TEXT}; }}
QLabel#substatus {{ font-size: {FS_BODY}px; color: {DIM}; }}
QLabel#section   {{ font-size: {FS_SECTION}px; font-weight: 700; color: {DIM}; }}
/* Подпись режима — тот же вес, что у заголовка раздела, но приглушённее: она
   сообщает не о чём раздел, а о том, как именно идёт трафик. */
QLabel#mode      {{ font-size: {FS_SECTION}px; font-weight: 700; color: {MUTED}; }}
QLabel#emptyTitle {{ font-size: {FS_ROW_TITLE}px; font-weight: 500; color: {DIM}; }}
QLabel#emptyHint  {{ font-size: {FS_SECTION}px; font-weight: 700; color: {MUTED}; }}
QLabel#logLine   {{
    font-family: {MONO_FONT}, monospace;
    font-size: {FS_MONO}px;
    color: {DIM};
}}
QLabel#logChevron {{ font-size: {FS_SECTION}px; font-weight: 700; color: {MUTED}; }}

/* Кнопки шапки плоские: ни фона, ни рамки — при наведении светлеет сам знак.
   Подложка была раньше и ушла намеренно: объёмный элемент в окне ровно один,
   иначе четыре прямоугольника в шапке спорят с кнопкой питания за внимание.
   Область нажатия осталась прежней, 28x28 — её задаёт размер кнопки. */
QToolButton {{
    background: transparent;
    border: none;
    color: {DIM};
    font-size: {HEADER_ICON}px;
    padding: 0;
}}
QToolButton:hover   {{ color: {TEXT}; }}
QToolButton:pressed {{ color: {TEXT}; }}
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
    border-radius: {BOX_CORNER}px;
    padding: 6px;
}}
QMenu::item {{ padding: 6px 26px 6px 22px; border-radius: 6px; }}
QMenu::item:selected {{ background: {SURFACE_HI}; }}
QMenu::separator {{ height: 1px; background: {STROKE}; margin: 6px 8px; }}

QPlainTextEdit {{
    background: {SURFACE};
    border: 1px solid {STROKE};
    border-radius: {BOX_CORNER}px;
    color: {DIM};
    font-family: {MONO_FONT}, monospace;
    font-size: {FS_DETAIL}px;
    padding: {LOG_PADDING}px;
}}

/* Развёрнутый лог — не коробка, а нижняя часть полосы: рамка и скругление
   отрезали бы его от строки с последним сообщением, а это одно и то же. */
QPlainTextEdit#log {{
    background: {SURFACE};
    border: none;
    border-radius: 0;
    font-size: {FS_MONO}px;
}}
QWidget#logPane, QWidget#logStrip {{ background: {SURFACE}; }}

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
    border-radius: {BOX_CORNER}px;
    padding: 7px 10px;
    color: {TEXT};
    selection-background-color: {STROKE};
    selection-color: {TEXT};
}}
QLineEdit:focus {{ border-color: {ACCENT}; }}
QPushButton {{
    background: {SURFACE_HI};
    border: 1px solid {STROKE};
    border-radius: {BOX_CORNER}px;
    padding: 7px 16px;
    color: {TEXT};
}}
QPushButton:hover  {{ border-color: {DIM}; }}
QPushButton:default {{ border-color: {ACCENT}; }}
"""


# ----------------------------------------------------------------------
# Шрифты
# ----------------------------------------------------------------------
# То, чего таблица стилей Qt не умеет: разрядка и табличные цифры. Размер и
# начертание задаются и здесь, и в QSS одними и теми же числами — таблица
# стилей перебивает шрифт виджета в своих свойствах, а остальные (разрядку,
# набор цифр) берёт из шрифта, поставленного через setFont().
#
# PySide6 импортируется внутри функций: theme читается и там, где Qt ещё (или
# уже) нет — например, при сборке значков в setup/.

# Семейство для QFont. На macOS оставляем системное (пустой список): туда
# подставится SF, как и в QSS.
UI_FAMILIES: list[str] = [] if sys.platform == "darwin" else ["Segoe UI"]


def _tabular(font) -> None:
    """Табличные (моноширинные) цифры.

    Аптайм тикает раз в секунду, пинг меняется на каждом замере, и
    пропорциональные цифры дёргают разметку на каждом обновлении: «00:11:59»
    шире, чем «00:12:00». Фича OpenType появилась в Qt 6.7; на более старых
    сборках (requirements допускают 6.6) её нет — тогда столбик держат
    постоянная ширина колонки и выравнивание по правому краю, а Segoe UI и
    так рисует цифры одной ширины.
    """
    from PySide6.QtGui import QFont

    try:
        font.setFeature(QFont.Tag("tnum"), 1)
    except (AttributeError, TypeError):
        pass


def ui_font(size: int, weight: int = 400, tracking: float = 0.0, tabular: bool = False):
    """Шрифт интерфейса из шкалы. Размер — в пикселях, как и в QSS."""
    from PySide6.QtGui import QFont

    font = QFont()
    if UI_FAMILIES:
        font.setFamilies(UI_FAMILIES)
    font.setPixelSize(size)
    font.setWeight(QFont.Weight(weight))
    if tracking:
        font.setLetterSpacing(QFont.AbsoluteSpacing, tracking)
    if tabular:
        _tabular(font)
    return font


def mono_font(size: int = FS_MONO):
    """Моноширинный — для лога и ссылок подписки."""
    from PySide6.QtGui import QFont

    font = QFont()
    font.setFamilies([MONO_FONT, "monospace"])
    font.setPixelSize(size)
    return font


def font_wordmark():
    """Знак SCVPN: мелкий, но с широкой разрядкой — метка окна, а не заголовок."""
    return ui_font(FS_WORDMARK, 700, WORDMARK_TRACKING)


def font_status():
    """Состояние подключения — единственная крупная надпись в окне."""
    return ui_font(FS_STATUS, 600, STATUS_TRACKING)


def font_substatus():
    """Строка под состоянием: там аптайм, поэтому цифры табличные."""
    return ui_font(FS_BODY, tabular=True)


def font_section():
    """Подписи разделов и режима."""
    return ui_font(FS_SECTION, 700, SECTION_TRACKING)


def font_row_title():
    """Имя сервера. Полужирности хватает, чтобы имя отделилось от адреса под
    ним без увеличения размера."""
    return ui_font(FS_ROW_TITLE, 500)


def font_row_detail():
    """Адрес под именем сервера."""
    return ui_font(FS_DETAIL)


def font_row_ping():
    """Значение пинга: те же 11 px, но цифры табличные — колонка не пляшет
    при перезамере."""
    return ui_font(FS_DETAIL, tabular=True)


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
