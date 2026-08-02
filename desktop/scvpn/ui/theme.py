"""Палитра и таблица стилей SCVPN — одно место на всё приложение.

Тема одна, тёмная. Светлого варианта нет намеренно: у приложения ровно один
экран, и второй набор цветов пришлось бы поддерживать без всякой пользы.
Цвета те же, что у иконки и у Android-версии.
"""
from __future__ import annotations

BG = "#0A0E13"
SURFACE = "#131A24"
SURFACE_HI = "#1B2430"
STROKE = "#22303F"

TEXT = "#E6EDF3"
DIM = "#7D8B9C"

TEAL = "#2DD4BF"
BLUE = "#3B82F6"
RED = "#F87171"

QSS = f"""
QMainWindow, QWidget {{
    background: {BG};
    color: {TEXT};
    font-family: "Segoe UI", sans-serif;
    font-size: 13px;
}}

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
    font-family: Consolas, monospace;
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
    selection-background-color: {BLUE};
}}
QLineEdit:focus {{ border-color: {TEAL}; }}
QPushButton {{
    background: {SURFACE_HI};
    border: 1px solid {STROKE};
    border-radius: 8px;
    padding: 7px 16px;
    color: {TEXT};
}}
QPushButton:hover  {{ border-color: {DIM}; }}
QPushButton:default {{ border-color: {TEAL}; }}
"""
