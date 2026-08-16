"""Маленький помощник для фоновых задач, чтобы интерфейс не подвисал.

Worker запускает переданную функцию в отдельном потоке и присылает результат
или ошибку через сигналы Qt (их можно безопасно ловить в главном потоке).
Функция получает первым аргументом колбэк log() для промежуточных сообщений.
"""
from __future__ import annotations

import traceback
from typing import Callable

from PySide6.QtCore import QThread, Signal

from native import paths
from connect import ping_delay
from ping import tcp_ping


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
    """Меряет задержку до серверов по очереди и шлёт результат по каждому.

    Замер идёт запросом **через сам сервер** (ping_delay), а не установкой
    TCP-соединения: второй отвечает на вопрос «порт открыт», а не «сервер
    работает», и мёртвый VLESS на живом 443 показывал честные 42 мс.

    По очереди, а не веером: каждая проба поднимает своё ядро.
    """

    result = Signal(str, object)  # (Server.key(), задержка_мс или None)
    done = Signal()
    log = Signal(str)

    def __init__(self, servers, route_mode: str = "global") -> None:
        super().__init__()
        self._servers = list(servers)
        self._route_mode = route_mode

    def run(self) -> None:
        # Ядра нет — мерить через сервер нечем. Откатываемся на TCP: числа
        # означают меньше, но список серверов остаётся полезным, а не
        # заполняется сплошным «нет ответа».
        through_core = paths.xray_exe().exists()
        if not through_core:
            self.log.emit("[!] Ядра нет — меряю пинг по TCP, "
                          "это проверка порта, а не работоспособности сервера.")
        for s in self._servers:
            ms = (ping_delay(s, route_mode=self._route_mode) if through_core
                  else tcp_ping(s.address, s.port))
            self.result.emit(s.key(), ms)
        self.done.emit()
