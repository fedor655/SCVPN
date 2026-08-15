"""Сдвиг кнопок окна (светофора) вниз, как в Electron trafficLightPosition.

Qt такого не умеет: положение кнопок задаёт AppKit. Дёргаем NSWindow напрямую
через ctypes — pyobjc ради трёх вызовов в зависимости тащить незачем.
AppKit переставляет кнопки обратно при каждой перекладке заголовка, поэтому
sink() зовут снова после resize.
"""
from __future__ import annotations

import ctypes
import ctypes.util

_objc = ctypes.CDLL(ctypes.util.find_library("objc"))


class _Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class _Size(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class _Rect(ctypes.Structure):
    _fields_ = [("origin", _Point), ("size", _Size)]


def _sel(name: str) -> ctypes.c_void_p:
    _objc.sel_registerName.restype = ctypes.c_void_p
    _objc.sel_registerName.argtypes = [ctypes.c_char_p]
    return _objc.sel_registerName(name.encode())


def _send(obj, selector: str, restype, argtypes=(), *args):
    # objc_msgSend вариативный: без явных argtypes ctypes раскладывает
    # аргументы не по тем регистрам, на arm64 это молча ломает вызов.
    fn = ctypes.CDLL(None).objc_msgSend
    fn.restype = restype
    fn.argtypes = [ctypes.c_void_p, ctypes.c_void_p, *argtypes]
    return fn(ctypes.c_void_p(obj), _sel(selector), *args)


def sink(win_id: int, center_from_top: float, left: float) -> None:
    """Опустить светофор и отодвинуть его от левого края.

    center_from_top — где должен оказаться центр кнопок, left — отступ первой
    кнопки от края окна. win_id — то, что вернул QWidget.winId(): NSView окна.
    """
    window = _send(win_id, "window", ctypes.c_void_p)
    if not window:
        return
    buttons = [_send(window, "standardWindowButton:", ctypes.c_void_p,
                     [ctypes.c_long], ctypes.c_long(tag))
               for tag in (0, 1, 2)]      # close, miniaturize, zoom
    if not all(buttons):
        return

    # Просто сдвинуть кнопки вниз мало: они уедут за пределы контейнера
    # заголовка и пропадут. Растим сам контейнер (верх его остаётся на месте,
    # координаты AppKit растут вверх) и ставим кнопки в его центр.
    container = _send(_send(buttons[0], "superview", ctypes.c_void_p),
                      "superview", ctypes.c_void_p)
    if not container:
        return
    frame = _send(container, "frame", _Rect)
    height = center_from_top * 2
    _send(container, "setFrame:", None, [_Rect],
          _Rect(_Point(frame.origin.x, frame.origin.y + frame.size.height - height),
                _Size(frame.size.width, height)))

    # Расстояние между кнопками не трогаем — двигаем всю тройку на одну дельту.
    shift = left - _send(buttons[0], "frame", _Rect).origin.x
    for button in buttons:
        box = _send(button, "frame", _Rect)
        _send(button, "setFrameOrigin:", None, [_Point],
              _Point(box.origin.x + shift, (height - box.size.height) / 2))
