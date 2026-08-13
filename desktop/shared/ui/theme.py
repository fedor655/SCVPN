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
