"""Маленький помощник для фоновых задач, чтобы интерфейс не подвисал.

Worker запускает переданную функцию в отдельном потоке и присылает результат
или ошибку через сигналы Qt (их можно безопасно ловить в главном потоке).
Функция получает первым аргументом колбэк log() для промежуточных сообщений.
"""
from __future__ import annotations

import traceback
from typing import Callable

from PySide6.QtCore import QThread, Signal

from shared.ping import tcp_ping


class Worker(QThread):
    done = Signal(object)   # успешный результат
    failed = Signal(str)    # текст ошибки
    log = Signal(str)       # промежуточные сообщения
    # Скачано/всего в байтах. Отдельно от log намеренно: полоске нужны числа, а
    # выковыривать их обратно из русской строки лога — гадание. Кто не умеет
    # считать байты (на macOS sing-box качает демон у себя), просто молчит, и
    # полоска остаётся бегущей.
    progress = Signal(int, int)

    def __init__(self, fn: Callable[[Callable[[str], None]], object]) -> None:
        super().__init__()
        self._fn = fn
        # Само исключение, а не только его текст: по нему вызывающий код
        # отличает понятную пользователю ошибку от неожиданной поломки.
        self.error: Exception | None = None

    def run(self) -> None:  # выполняется в отдельном потоке
        try:
            result = self._fn(self.log.emit)
            self.done.emit(result)
        except Exception as e:  # noqa: BLE001
            self.error = e
            self.failed.emit(f"{e}\n{traceback.format_exc()}")


class PingWorker(QThread):
    """Пингует список серверов по очереди и шлёт результат по каждому."""

    result = Signal(str, object)  # (Server.key(), задержка_мс или None)
    done = Signal()

    def __init__(self, servers) -> None:
        super().__init__()
        self._servers = list(servers)

    def run(self) -> None:
        for s in self._servers:
            ms = tcp_ping(s.address, s.port)
            self.result.emit(s.key(), ms)
        self.done.emit()
