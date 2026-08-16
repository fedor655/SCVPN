"""Главное окно SCVPN.

Экран сведён к трём вещам: кнопка подключения, статус, список серверов.
Всё, что нажимают редко (маршрутизация, TUN, отпечаток, скачивание ядра, лог),
убрано в меню «⋯» — настройки никуда не делись, просто не занимают место.
Логика подключения по-прежнему целиком в connect_vpn()/disconnect_vpn();
ничего в фоне без твоего действия не происходит.
"""
from __future__ import annotations

import sys
import time

from PySide6.QtCore import QSize, Qt, QTimer, Signal
from PySide6.QtGui import QActionGroup, QColor, QIcon
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QProgressDialog,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from shared import __version__
from shared.connect import find_working_fingerprint
from shared.core_runner import XrayRunner, find_free_port
from shared.models import Server
from shared.storage import (
    Profiles,
    Subscription,
    load_profiles,
    load_settings,
    now_iso,
    save_profiles,
    save_settings,
)
from shared.subscription import SubscriptionError, fetch_subscription_full, parse_link
from shared.xray_config import ROUTE_BYPASS_RU, ROUTE_GLOBAL, build_config
from native import sysproxy
from native.downloader import (
    core_present,
    download_core,
    download_tun,
    remove_tun,
    tun_present,
)
from native.tun import (
    PRIVILEGE_QUESTION,
    SPLIT_OFF,
    Tun,
    acquire_privilege,
    cleanup_stray,
    last_privilege_error,
    privileged,
)
from . import theme
from .add_dialog import AddDialog
from .brandmark import mark_pixmap
from .split_dialog import SplitTunnelDialog
from .subscription_dialog import SubscriptionDialog
from .widgets import ROLE_PING, ROLE_SERVER, ROLE_SUBTITLE, PowerButton, ServerDelegate, pulse_icon
from .workers import PingWorker, Worker

STATE_COLORS = {
    "idle": theme.DIM,
    "connecting": theme.TEXT,
    "connected": theme.ACCENT,
    "error": theme.TEXT,
    "tun_stuck": theme.TEXT,
}
STATE_TEXTS = {
    "idle": "Отключено",
    "connecting": "Подключение…",
    "connected": "Подключено",
    "error": "Не подключилось",
    # Отдельное состояние, а не "error": ошибка подключения и «отключиться не
    # вышло» — разные новости, и вторая опаснее. См. _report_tun_stuck().
    "tun_stuck": "Туннель не снят",
}

# Шапка macOS: отступы, высота кнопок, итоговая высота ряда. Светофор
# опускаем в центр этого ряда и отодвигаем от края (см. native.titlebar.sink).
MAC_HEADER_TOP = 12
MAC_HEADER_LEFT = 88
MAC_BTN = 28
MAC_HEADER_H = MAC_HEADER_TOP + MAC_BTN + 10
MAC_LIGHTS_LEFT = 18

TUN_STUCK_TEXT = (
    "sing-box пережил остановку: TUN-адаптер поднят, весь трафик по-прежнему\n"
    "идёт через него, а туннель уже никем не обслуживается.\n\n"
    "Перезагрузка компьютера снимет адаптер наверняка."
)


class MainWindow(QMainWindow):
    # Сигналы для безопасного обновления UI из фоновых потоков ядра.
    log_signal = Signal(str)
    state_signal = Signal(bool)
    tun_state_signal = Signal(bool)

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(f"SCVPN {__version__}")
        self.resize(420, 700)
        self.setMinimumSize(360, 540)
        if sys.platform == "darwin":
            # Контент уезжает под заголовок, сама полоса пропадает — светофор
            # остаётся плавать поверх шапки, слева от логотипа. Нужен Qt 6.9+,
            # и флаги ставим на нативное окно: QWidget их до создания теряет.
            self.setWindowTitle("")
            self.setAttribute(Qt.WA_ContentsMarginsRespectsSafeArea, False)
            self.winId()
            handle = self.windowHandle()
            handle.setFlags(
                handle.flags() | Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint
            )

        self.profiles: Profiles = load_profiles()
        self.settings: dict = load_settings()
        self.row_servers: list[Server] = []
        self._workers: list = []        # держим ссылки, чтобы потоки не удалялись
        self._want_connected = False
        self._state = "idle"
        self._connected_since: float | None = None
        self._active_http_port = int(self.settings.get("http_port", 10809))
        self._active_socks_port = int(self.settings.get("socks_port", 10808))

        self.runner = XrayRunner(
            on_log=self.log_signal.emit,
            on_state=self.state_signal.emit,
        )
        self.tun = Tun(
            on_log=self.log_signal.emit,
            on_state=self.tun_state_signal.emit,
        )
        self.log_signal.connect(self._append_log)
        self.state_signal.connect(self._on_state)
        self.tun_state_signal.connect(self._on_tun_state)

        # Тикает раз в секунду, пока подключены, — считает время сессии.
        self._clock = QTimer(self)
        self._clock.setInterval(1000)
        self._clock.timeout.connect(self._update_substatus)

        self._build_ui()
        self._refresh_list()
        self._render_state("idle")

        # Если прошлый запуск завершился аварийно, TUN мог остаться поднятым и
        # сейчас забирать весь трафик в никуда — разбираем это до всего прочего.
        cleanup_stray(self._append_log)

        if not core_present():
            self._append_log("[!] Ядро Xray-core не найдено. Меню «⋯» → «Скачать ядро Xray».")

    # ------------------------------------------------------------------
    # Построение интерфейса
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        central = QWidget()
        # Иначе Qt сам отодвинет содержимое вниз от «безопасной зоны» заголовка.
        central.setAttribute(Qt.WA_ContentsMarginsRespectsSafeArea, False)
        root = QVBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        root.addLayout(self._build_header())
        root.addLayout(self._build_power_block())

        section = QLabel("СЕРВЕРЫ")
        section.setObjectName("section")
        section.setContentsMargins(22, 0, 22, 8)
        root.addWidget(section)

        self.list = QListWidget()
        self.list.setItemDelegate(ServerDelegate(self.list))
        self.list.setMouseTracking(True)          # чтобы делегат видел наведение
        self.list.setSpacing(0)
        self.list.setViewportMargins(16, 0, 10, 10)
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list.setSelectionMode(QListWidget.SingleSelection)
        self.list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self._list_context_menu)
        self.list.itemSelectionChanged.connect(self._on_selection_changed)
        self.list.itemDoubleClicked.connect(lambda *_: self._on_connect_clicked())
        root.addWidget(self.list, 1)

        self.empty_label = QLabel("Серверов пока нет.\nДобавь ссылку или подписку кнопкой  +")
        self.empty_label.setAlignment(Qt.AlignCenter)
        self.empty_label.setObjectName("substatus")
        self.empty_label.setContentsMargins(20, 24, 20, 24)
        root.addWidget(self.empty_label, 1)

        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setMaximumBlockCount(2000)
        self.log_view.setFixedHeight(130)
        self._log_wrap = QWidget()
        log_layout = QVBoxLayout(self._log_wrap)
        log_layout.setContentsMargins(16, 4, 16, 16)
        log_layout.addWidget(self.log_view)
        self._log_wrap.setVisible(bool(self.settings.get("show_log", False)))
        root.addWidget(self._log_wrap)

        self.setCentralWidget(central)

    def mousePressEvent(self, event) -> None:
        # Полосы заголовка на macOS больше нет, тащить окно не за что —
        # отдаём под перетаскивание всю шапку.
        if sys.platform == "darwin" and event.position().y() < MAC_HEADER_H:
            self.windowHandle().startSystemMove()
            return
        super().mousePressEvent(event)

    def _sink_traffic_lights(self) -> None:
        # AppKit возвращает кнопки на штатную высоту при каждой перекладке
        # заголовка, поэтому опускаем их снова после показа и после resize.
        # resize прилетает и из __init__, когда UI ещё не собран, — там нечего
        # двигать и некуда писать ошибку.
        if sys.platform != "darwin" or not self.isVisible():
            return
        from native.titlebar import sink

        try:
            sink(int(self.winId()), MAC_HEADER_TOP + MAC_BTN / 2, MAC_LIGHTS_LEFT)
        except Exception as exc:          # чужая внутренняя кухня AppKit
            self._append_log(f"[!] Не удалось опустить кнопки окна: {exc}")

    def _schedule_sink(self) -> None:
        # Двигаем не сразу: AppKit доперекладывает заголовок после события и
        # вернул бы кнопки на место. Второй заход — ради выхода из полного
        # экрана, там перекладка приезжает уже после анимации.
        QTimer.singleShot(0, self._sink_traffic_lights)
        QTimer.singleShot(400, self._sink_traffic_lights)

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._schedule_sink()

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self._schedule_sink()

    def changeEvent(self, event) -> None:
        super().changeEvent(event)
        self._schedule_sink()

    def _build_header(self) -> QHBoxLayout:
        mac = sys.platform == "darwin"
        header = QHBoxLayout()
        # На macOS шапка — это и есть полоса заголовка: слева место кнопкам
        # окна, а ряд ниже (28 против 34) ставит надпись на их высоту.
        if mac:
            header.setContentsMargins(MAC_HEADER_LEFT, MAC_HEADER_TOP, 12, 10)
        else:
            header.setContentsMargins(22, 16, 12, 10)
        header.setSpacing(2)
        btn = QSize(MAC_BTN, MAC_BTN) if mac else QSize(34, 34)

        # Значок рядом с кнопками окна тесно — на macOS оставляем одну надпись.
        if not mac:
            badge = QLabel()
            badge.setPixmap(mark_pixmap(20, QColor(theme.TEXT)))
            header.addWidget(badge)

        title = QLabel("SCVPN")
        title.setObjectName("wordmark")
        title.setContentsMargins(0 if mac else 10, 0, 0, 0)
        header.addWidget(title, 1)

        def tool(text: str, tip: str, slot) -> QToolButton:
            b = QToolButton()
            b.setText(text)
            b.setToolTip(tip)
            b.setFixedSize(btn)
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(slot)
            header.addWidget(b)
            return b

        # Пинг — отдельной кнопкой в шапке, а не только в меню: его ищут глазами.
        ping_btn = QToolButton()
        ping_btn.setIcon(pulse_icon(theme.DIM))
        ping_btn.setIconSize(QSize(20, 20))
        ping_btn.setToolTip("Измерить пинг серверов")
        ping_btn.setFixedSize(btn)
        ping_btn.setCursor(Qt.PointingHandCursor)
        ping_btn.clicked.connect(self._ping_all)
        header.addWidget(ping_btn)

        tool("+", "Добавить сервер или подписку", self._add_something)
        tool("↻", "Обновить подписки", self._update_subscriptions)

        self.menu_btn = tool("⋯", "Настройки и подписки", lambda: None)
        self.menu_btn.setPopupMode(QToolButton.InstantPopup)
        self.menu_btn.setMenu(self._build_menu())

        self.setWindowIcon(QIcon(mark_pixmap(64)))
        return header

    def _build_power_block(self) -> QVBoxLayout:
        block = QVBoxLayout()
        block.setContentsMargins(0, 24, 0, 24)
        block.setSpacing(0)

        self.power = PowerButton(132)
        self.power.clicked.connect(self._on_connect_clicked)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(self.power)
        row.addStretch(1)
        block.addLayout(row)

        self.status_label = QLabel(STATE_TEXTS["idle"])
        self.status_label.setObjectName("status")
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setContentsMargins(0, 18, 0, 0)
        block.addWidget(self.status_label)

        self.substatus_label = QLabel("")
        self.substatus_label.setObjectName("substatus")
        self.substatus_label.setAlignment(Qt.AlignCenter)
        self.substatus_label.setContentsMargins(20, 5, 20, 0)
        block.addWidget(self.substatus_label)
        return block

    def _build_menu(self) -> QMenu:
        menu = QMenu(self)

        # Маршрутизация целиком живёт в «Раздельном туннелировании» — это один
        # и тот же вопрос «что идёт в туннель», и двумя меню он только путал.
        self._radio_group(
            menu.addMenu("Способ подключения"),
            [("Системный прокси", "proxy"),
             ("TUN — весь трафик (нужен админ)", "tun")],
            "vpn_mode", "proxy", on_change=self._on_mode_changed,
        )
        self._radio_group(
            menu.addMenu("Отпечаток TLS"),
            [("Авто — подобрать", "auto")]
            + [(n, n) for n in ("chrome", "firefox", "safari", "edge", "ios", "randomized")],
            "tls_fingerprint", "auto",
        )

        if sys.platform == "darwin":
            # Сетевой стек TUN — тот самый винт, который приходится крутить,
            # когда туннель ведёт себя странно на конкретной сети.
            self._radio_group(
                menu.addMenu("Сетевой стек TUN"),
                [("gvisor — самый предсказуемый", "gvisor"),
                 ("system — быстрее", "system"),
                 ("mixed — TCP системный, UDP gvisor", "mixed")],
                "tun_stack", "gvisor",
            )

        menu.addSeparator()

        self.sysproxy_action = self._check_item(
            menu, "Включать системный прокси", "system_proxy", True
        )
        self.sysproxy_action.setEnabled(self.settings.get("vpn_mode", "proxy") == "proxy")
        self._check_item(menu, "Блокировать рекламу", "block_ads", False)

        menu.addSeparator()
        menu.addAction("Раздельное туннелирование…", self._edit_split_tunnel)
        menu.addAction("Подписки…", self._manage_subscriptions)
        menu.addAction("Измерить пинг", self._ping_all)
        menu.addAction("Скачать ядро Xray", self._download_core)
        menu.addAction("Скачать компоненты TUN", self._download_tun)
        # Показываем, только когда есть что удалять: пункт «удалить» над пустым
        # местом — обещание действия, которое ничего не сделает.
        if tun_present():
            menu.addAction("Удалить компоненты TUN…", self._remove_tun)
        if sys.platform == "darwin":
            menu.addAction("Удалить системный компонент…", self._remove_helper)

        menu.addSeparator()
        log_action = menu.addAction("Показывать лог ядра")
        log_action.setCheckable(True)
        log_action.setChecked(bool(self.settings.get("show_log", False)))
        log_action.toggled.connect(self._toggle_log)
        return menu

    def _check_item(self, menu: QMenu, label: str, key: str, default: bool):
        action = menu.addAction(label)
        action.setCheckable(True)
        action.setChecked(bool(self.settings.get(key, default)))
        action.toggled.connect(lambda v: self._set_setting(key, v))
        return action

    def _radio_group(self, menu: QMenu, options, key: str, default, on_change=None) -> None:
        """Взаимоисключающие пункты меню, привязанные к ключу настроек."""
        group = QActionGroup(menu)
        group.setExclusive(True)
        current = self.settings.get(key, default)
        for label, value in options:
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(current == value)
            group.addAction(action)
            action.triggered.connect(
                lambda _checked=False, v=value: self._pick(key, v, on_change)
            )

    def _pick(self, key: str, value, on_change) -> None:
        self._set_setting(key, value)
        if on_change:
            on_change()

    def _set_setting(self, key: str, value) -> None:
        self.settings[key] = value
        save_settings(self.settings)

    def _toggle_log(self, visible: bool) -> None:
        self._set_setting("show_log", visible)
        self._log_wrap.setVisible(visible)

    # ------------------------------------------------------------------
    # Список серверов
    # ------------------------------------------------------------------
    def _refresh_list(self, keep_pings: bool = True) -> None:
        # Пинги переживают обычное перечитывание списка: сервер тот же, мерить
        # незачем. А вот после обновления подписки их надо сбросить: за тем же
        # именем может стоять уже другой сервер, и старое число врало бы.
        previous_pings = {
            self.list.item(i).data(ROLE_SERVER).key(): self.list.item(i).data(ROLE_PING)
            for i in range(self.list.count())
        } if keep_pings else {}

        servers = self.profiles.all_servers()
        self.row_servers = servers
        selected_key = self.settings.get("selected_key", "")

        self.list.blockSignals(True)
        self.list.clear()
        for s in servers:
            item = QListWidgetItem(s.title)
            item.setData(ROLE_SERVER, s)
            item.setData(ROLE_SUBTITLE, self._proto_label(s))
            item.setData(ROLE_PING, previous_pings.get(s.key()))
            self.list.addItem(item)
            if s.key() == selected_key:
                self.list.setCurrentItem(item)
        if self.list.currentRow() < 0 and servers:
            self.list.setCurrentRow(0)
        self.list.blockSignals(False)

        self.empty_label.setVisible(not servers)
        self.list.setVisible(bool(servers))
        self._update_substatus()

    @staticmethod
    def _proto_label(s: Server) -> str:
        sec = f"+{s.security}" if s.security not in ("", "none") else ""
        return f"{s.protocol}{sec} / {s.network}"

    def _current_server(self) -> Server | None:
        item = self.list.currentItem()
        return item.data(ROLE_SERVER) if item else None

    def _on_selection_changed(self) -> None:
        s = self._current_server()
        if s:
            self._set_setting("selected_key", s.key())
            self._update_substatus()

    def _list_context_menu(self, pos) -> None:
        item = self.list.itemAt(pos)
        if item is None:
            return
        self.list.setCurrentItem(item)
        menu = QMenu(self)
        menu.addAction("Подключиться", self._on_connect_clicked)
        menu.addAction("Удалить", self._remove_selected)
        menu.exec(self.list.viewport().mapToGlobal(pos))

    # ------------------------------------------------------------------
    # Подключение / отключение
    # ------------------------------------------------------------------
    def _on_connect_clicked(self) -> None:
        if self._state == "connecting":
            return                      # подбор отпечатка уже идёт — не мешаем
        if self.runner.running:
            self.disconnect_vpn()
        else:
            self.connect_vpn()

    def connect_vpn(self) -> None:
        server = self._current_server()
        if server is None:
            QMessageBox.warning(self, "Нет сервера", "Сначала добавь и выбери сервер из списка.")
            return
        if not core_present():
            QMessageBox.warning(self, "Нет ядра", "Меню «⋯» → «Скачать ядро Xray».")
            return

        mode = self.settings.get("vpn_mode", "proxy")
        if mode == "tun" and not self._tun_preflight():
            return

        self._want_connected = True
        self._render_state("connecting")
        self._append_log(f"[*] Подключаюсь к: {server.title}")

        override = self.settings.get("tls_fingerprint", "auto")
        needs_fp = server.security in ("reality", "tls")

        if not needs_fp or override != "auto":
            # конкретный отпечаток или транспорт без TLS — стартуем сразу
            self._start_with_fingerprint(server, override if override != "auto" else "")
            return

        # авто: в фоне подбираем рабочий отпечаток, потом стартуем
        route_mode = self.settings.get("route_mode", ROUTE_GLOBAL)
        block_ads = bool(self.settings.get("block_ads", False))

        def task(log):
            return find_working_fingerprint(server, "auto", route_mode, block_ads, log)

        w = Worker(task)
        w.log.connect(self._append_log)

        def on_done(fp):
            self._workers.remove(w)
            if self._want_connected:
                self._start_with_fingerprint(server, fp)

        def on_fail(err):
            self._want_connected = False
            self._render_state("error")
            self._append_log(f"[!] Ошибка подбора отпечатка: {err.splitlines()[0]}")
            self._workers.remove(w)

        w.done.connect(on_done)
        w.failed.connect(on_fail)
        self._workers.append(w)
        w.start()

    # ------------------------------------------------------------------
    # Префлайт TUN: компоненты и права
    # ------------------------------------------------------------------
    def _tun_preflight(self) -> bool:
        """Всё ли готово для TUN. False — идти дальше нельзя, пользователю сказано.

        Порядок шагов разный на разных платформах, и это не вкусовщина.

        На Windows компоненты TUN — два файла рядом с приложением (sing-box и
        wintun.dll), которые кладёт установщик, а права — независимый от них
        UAC. Проверять файлы первыми правильно: иначе пользователь крутил бы
        круг UAC только затем, чтобы следом прочитать «нет компонентов».

        На macOS независимости нет. sing-box обязан лежать в root-овой папке
        (иначе его подменил бы любой процесс и получил root), кладёт его туда
        сам привилегированный демон, а ставит демона ровно эта ветка прав.
        То есть права — не «ещё одно требование рядом с компонентами», а их
        предусловие. Windows-порядок здесь давал неснимаемый круг: «нет
        компонентов» → меню «Скачать компоненты TUN» → «сначала установи
        системный компонент (включи TUN-режим)» → обратно в «нет
        компонентов», и ни один из двух входов в TUN не проходим на чистой
        машине. Поэтому на darwin сперва права (они же — установка демона),
        и только потом перепроверка компонентов.
        """
        if sys.platform == "darwin":
            return self._ensure_privilege() and self._ensure_tun_components()
        return self._ensure_tun_components() and self._ensure_privilege()

    def _ensure_tun_components(self) -> bool:
        if tun_present():
            return True
        QMessageBox.warning(
            self, "Нет компонентов TUN",
            "Меню «⋯» → «Скачать компоненты TUN».",
        )
        return False

    def _ensure_privilege(self) -> bool:
        """Права на TUN: есть — True; получили — True; иначе False."""
        if privileged():
            return True
        r = QMessageBox.question(self, "Нужны права администратора", PRIVILEGE_QUESTION)
        if r != QMessageBox.Yes:
            return False
        outcome = acquire_privilege()
        if outcome == "restart":
            QApplication.quit()
            return False
        if outcome != "ok":
            # last_privilege_error() — настоящая причина от install()
            # (helper/install.py): «Установка отменена.» или stderr
            # launchctl. Зашитая фраза ни о чём — ровно то, из-за чего
            # первое включение TUN на macOS било пользователя мимо цели.
            detail = last_privilege_error()
            self._append_log(
                f"[!] Не удалось поставить системный компонент: {detail}"
                if detail else "[!] Не удалось поставить системный компонент."
            )
            QMessageBox.warning(
                self, "Не вышло",
                detail or "Не удалось получить права администратора.",
            )
            return False
        return True

    def _start_with_fingerprint(self, server: Server, fingerprint: str) -> None:
        """Собрать конфиг с выбранным отпечатком и запустить ядро."""
        import copy

        srv = copy.deepcopy(server)
        if fingerprint:
            srv.fingerprint = fingerprint

        mode = self.settings.get("vpn_mode", "proxy")
        route_mode = self.settings.get("route_mode", ROUTE_GLOBAL)

        # Свободные порты, чтобы не конфликтовать с другими клиентами (Happ и т.п.).
        socks_port = find_free_port(int(self.settings.get("socks_port", 10808)))
        http_port = find_free_port(max(int(self.settings.get("http_port", 10809)), socks_port + 1))
        self._active_socks_port = socks_port
        self._active_http_port = http_port

        cfg = build_config(
            srv,
            socks_port=socks_port,
            http_port=http_port,
            route_mode=route_mode,
            block_ads=bool(self.settings.get("block_ads", False)),
            log_level="warning",
        )
        self._append_log(f"[*] Порты SOCKS={socks_port}, HTTP={http_port}, отпечаток={srv.fingerprint}")
        try:
            self.runner.start(cfg)
        except Exception as e:  # noqa: BLE001
            self._want_connected = False
            self._render_state("error")
            QMessageBox.critical(self, "Ошибка запуска ядра", str(e))
            return

        if mode == "tun":
            try:
                self.tun.start(
                    srv, self._active_socks_port,
                    split_mode=self.settings.get("split_mode", SPLIT_OFF),
                    split_apps=list(self.settings.get("split_apps", [])),
                )
            except Exception as e:  # noqa: BLE001
                self._append_log(f"[!] Не удалось включить TUN: {e}")
                QMessageBox.critical(self, "Ошибка TUN", str(e))
                self.disconnect_vpn()
        elif self.settings.get("system_proxy", True):
            try:
                sysproxy.enable("127.0.0.1", self._active_http_port)
                self._append_log(f"[*] Системный прокси включён (127.0.0.1:{self._active_http_port})")
            except Exception as e:  # noqa: BLE001
                self._append_log(f"[!] Не удалось включить системный прокси: {e}")

    def disconnect_vpn(self) -> None:
        self._want_connected = False
        tun_down = self.tun.stop()  # сначала TUN — он вернёт маршруты в исходное состояние
        if sysproxy.is_enabled():
            sysproxy.disable()
            self._append_log("[*] Системный прокси выключён")
        self.runner.stop()
        # После runner.stop(): она синхронно приводит к _on_state(False), а та
        # рисует "idle" — то самое «Отключено», которое здесь было бы ложью.
        if not tun_down:
            self._report_tun_stuck()

    def _report_tun_stuck(self) -> None:
        """Туннель не снялся, и об этом сказал не наш домысел, а сам демон.

        Tun.stop() возвращает False только по правдивому ответу системного
        компонента: sing-box пережил и SIGTERM, и SIGKILL, utun поднят,
        маршруты держатся. Показать «Отключено» в этот момент — соврать ровно
        там, где правду специально добывали.
        """
        self._append_log("[!] ТРЕВОГА: туннель не снят — sing-box пережил остановку.")
        self._render_state("tun_stuck")
        QMessageBox.warning(self, "Туннель не снят", TUN_STUCK_TEXT)

    def _on_state(self, running: bool) -> None:
        if running:
            self._connected_since = time.monotonic()
            self._clock.start()
            self._render_state("connected")
            return

        self._connected_since = None
        self._clock.stop()
        # если ядро упало само, а мы думали что подключены — приберём всё
        if self._want_connected:
            self._want_connected = False
            tun_down = self.tun.stop()
            if sysproxy.is_enabled():
                sysproxy.disable()
            self._append_log("[!] Соединение разорвано (ядро остановилось).")
            self._render_state("error")
            if not tun_down:
                self._report_tun_stuck()
        else:
            self._render_state("idle")

    def _on_tun_state(self, running: bool) -> None:
        if running:
            self._append_log("[tun] TUN-адаптер активен — весь трафик идёт через VPN.")
        elif self._want_connected and self.settings.get("vpn_mode") == "tun":
            # TUN упал во время сессии — рвём всё, чтобы не остаться без сети.
            #
            # self._want_connected = False ОБЯЗАН стоять раньше self.tun.stop()
            # и self.runner.stop() — не только по смыслу, а из-за реального
            # переплетения сигналов. self.runner.stop() синхронно (тот же
            # поток, то же соединение сигнал-слот) может дёрнуть _on_state(False)
            # прямо изнутри этого же вызова — а у _on_state() своя ветка
            # `if self._want_connected: ... self.tun.stop() ...`, дословно
            # повторяющая эту уборку. Если _want_connected к этому моменту всё
            # ещё True, _on_state отработает её ЕЩЁ РАЗ поверх текущей —
            # повторные tun.stop()/sysproxy.disable(), конфликтующий лог и
            # render_state("error") поверх состояния, которое ещё не
            # доделали здесь. Сбросив флаг первой строкой, вторая ветка видит
            # его уже False и просто откатывается в "idle", не начиная свою
            # уборку заново.
            self._append_log("[!] TUN остановился — отключаюсь.")
            self._want_connected = False
            # закрыть соединение с демоном (Tun уже знает, что не жив)
            tun_down = self.tun.stop()
            self.runner.stop()
            if sysproxy.is_enabled():
                sysproxy.disable()
            if not tun_down:
                self._report_tun_stuck()

    # ------------------------------------------------------------------
    # Статус
    # ------------------------------------------------------------------
    def _render_state(self, state: str) -> None:
        self._state = state
        self.power.set_state(state)
        self.status_label.setText(STATE_TEXTS[state])
        self.status_label.setStyleSheet(f"color: {STATE_COLORS[state]};")
        self._update_substatus()

    def _update_substatus(self) -> None:
        server = self._current_server()
        text = server.title if server else ""
        if self._state == "connected" and self._connected_since:
            secs = int(time.monotonic() - self._connected_since)
            clock = (
                f"{secs // 3600}:{secs // 60 % 60:02d}:{secs % 60:02d}"
                if secs >= 3600 else f"{secs // 60:02d}:{secs % 60:02d}"
            )
            mode = "TUN" if self.settings.get("vpn_mode") == "tun" else "прокси"
            text = f"{text}  ·  {clock}  ·  {mode}" if text else clock
        self.substatus_label.setText(text)

    # ------------------------------------------------------------------
    # Управление серверами
    # ------------------------------------------------------------------
    def _add_something(self) -> None:
        """Одно поле на оба случая: ссылка распознаётся сама, иначе это подписка."""
        dlg = AddDialog(self)
        if dlg.exec() != AddDialog.Accepted:
            return
        text = dlg.value
        if not text:
            return

        s = parse_link(text)
        if s is not None:
            self.profiles.servers.append(s)
            save_profiles(self.profiles)
            self._refresh_list()
            self._append_log(f"[+] Добавлен сервер: {s.title}")
            return

        if not text.startswith(("http://", "https://")):
            QMessageBox.warning(
                self, "Не распознано",
                "Это не похоже ни на ссылку сервера, ни на URL подписки.",
            )
            return

        name, ok = QInputDialog.getText(
            self, "Имя подписки", "Название (как показывать):", text="Моя подписка"
        )
        if not ok:
            return
        sub = Subscription(name=name.strip() or "Подписка", url=text, added=now_iso())
        # В профиль подписка попадает только после успешной загрузки (это
        # делает _fetch_one_subscription): иначе опечатка в адресе оставляла
        # мёртвую запись навсегда — она не грузится, но занимает место и
        # удаляется только руками.
        self._fetch_one_subscription(sub)

    def _update_subscriptions(self) -> None:
        if not self.profiles.subscriptions:
            QMessageBox.information(self, "Нет подписок", "Сначала добавь подписку кнопкой  +")
            return
        for sub in self.profiles.subscriptions:
            self._fetch_one_subscription(sub)

    def _edit_split_tunnel(self) -> None:
        dlg = SplitTunnelDialog(
            self.settings.get("route_mode", ROUTE_GLOBAL),
            self.settings.get("split_mode", SPLIT_OFF),
            list(self.settings.get("split_apps", [])),
            self,
        )
        if dlg.exec() != SplitTunnelDialog.Accepted:
            return
        self._set_setting("route_mode", dlg.route_mode)
        self._set_setting("split_mode", dlg.mode)
        self._set_setting("split_apps", dlg.apps)
        self._append_log(f"[*] Маршрутизация: {dlg.summary}")

        # Разбор по приложениям делает sing-box, а он поднимается только в TUN.
        needs_tun = dlg.mode != SPLIT_OFF and dlg.apps
        if needs_tun and self.settings.get("vpn_mode") != "tun":
            QMessageBox.information(
                self, "Нужен TUN-режим",
                "Разбор по приложениям работает только в режиме\n"
                "«TUN — весь трафик». Переключи способ подключения в этом же меню.\n\n"
                "Режимы «Авто» и «Всё через VPN» работают в обоих способах.",
            )
        elif self.runner.running:
            self._append_log("[i] Изменения применятся при следующем подключении.")

    def _manage_subscriptions(self) -> None:
        """Экран подписки: статистика, ссылка, QR, удаление.

        Удалить сервер поштучно можно правой кнопкой по строке, а всю подписку
        целиком — только отсюда: иначе её серверы вернулись бы при «Обновить».
        """
        subs = self.profiles.subscriptions
        if not subs:
            QMessageBox.information(self, "Подписки", "Подписок нет.\nДобавь кнопкой + вверху.")
            return

        sub = subs[0]
        if len(subs) > 1:
            names = [f"{s.name} — серверов: {len(s.servers)}" for s in subs]
            choice, ok = QInputDialog.getItem(self, "Подписки", "Выбери подписку:", names, 0, False)
            if not ok:
                return
            sub = subs[names.index(choice)]

        dlg = SubscriptionDialog(sub, self)
        dlg.exec()

        if dlg.deleted:
            self.profiles.subscriptions.remove(sub)
            save_profiles(self.profiles)
            self._refresh_list()
            self._append_log(f"[-] Удалена подписка: {sub.name}")
        elif dlg.refresh_requested:
            self._fetch_one_subscription(sub)

    def _fetch_one_subscription(self, sub: Subscription) -> None:
        ua = self.settings.get("user_agent", "")
        self._append_log(f"[*] Обновляю подписку «{sub.name}»…")

        def task(log):
            if ua:
                return fetch_subscription_full(sub.url, user_agent=ua)
            return fetch_subscription_full(sub.url)

        w = Worker(task)
        w.log.connect(self._append_log)

        def on_fail(err):
            self._append_log(f"[!] Ошибка подписки «{sub.name}»: {err.splitlines()[0]}")
            # Показываем всегда, а не только отказ панели: раньше сетевая
            # ошибка или кривой ответ уходили в один лог, и нажатие «Обновить»
            # выглядело как «ничего не произошло». Текст SubscriptionError уже
            # написан для человека, остальное показываем как есть.
            text = str(w.error) if isinstance(w.error, SubscriptionError) else err.strip()
            QMessageBox.warning(self, f"Подписка «{sub.name}»", text)
            self._workers.remove(w)

        def on_done(result):
            servers, info = result
            if not servers:
                self._append_log(f"[!] Подписка «{sub.name}»: серверов не нашлось")
                QMessageBox.warning(
                    self, f"Подписка «{sub.name}»",
                    "Панель ответила, но серверов в ответе нет.",
                )
                self._workers.remove(w)
                return
            sub.servers = servers
            sub.info = info
            sub.updated = now_iso()
            # Название от панели точнее того, что пользователь ввёл руками.
            if info.title and sub.name in ("", "Подписка", "Моя подписка"):
                sub.name = info.title
            # Новая подписка добавляется здесь, а не до похода в сеть.
            if all(x.url != sub.url for x in self.profiles.subscriptions):
                self.profiles.subscriptions.append(sub)
            save_profiles(self.profiles)
            self._refresh_list(keep_pings=False)
            self._append_log(f"[+] Подписка «{sub.name}»: {len(servers)} серверов, пинги сброшены")
            self._workers.remove(w)

        w.done.connect(on_done)
        w.failed.connect(on_fail)
        self._workers.append(w)
        w.start()

    def _remove_selected(self) -> None:
        s = self._current_server()
        if s is None:
            return
        # удаляем из одиночных и из подписок по ключу
        key = s.key()
        self.profiles.servers = [x for x in self.profiles.servers if x.key() != key]
        for sub in self.profiles.subscriptions:
            sub.servers = [x for x in sub.servers if x.key() != key]
        save_profiles(self.profiles)
        self._refresh_list()
        self._append_log(f"[-] Удалён: {s.title}")

    def keyPressEvent(self, event) -> None:  # noqa: N802
        if event.key() == Qt.Key_Delete and self.list.hasFocus():
            self._remove_selected()
        else:
            super().keyPressEvent(event)

    # ------------------------------------------------------------------
    # Пинг
    # ------------------------------------------------------------------
    def _ping_all(self) -> None:
        if not self.row_servers:
            return
        self._append_log("[*] Пингую серверы…")
        w = PingWorker(self.row_servers)
        w.result.connect(self._on_ping_result)
        w.done.connect(lambda: (self._append_log("[*] Пинг завершён"), self._workers.remove(w)))
        self._workers.append(w)
        w.start()

    def _on_ping_result(self, key: str, ms) -> None:
        for row in range(self.list.count()):
            item = self.list.item(row)
            if item.data(ROLE_SERVER).key() == key:
                item.setData(ROLE_PING, False if ms is None else int(ms))
                break

    # ------------------------------------------------------------------
    # Скачивание ядра
    # ------------------------------------------------------------------
    def _download_core(self) -> None:
        self._append_log("[*] Скачиваю ядро Xray-core…")
        self._run_download(download_core, "Ядро Xray-core {tag} установлено.", "ядро")

    def _download_tun(self) -> None:
        # На macOS качать некуда, пока нет демона: sing-box обязан лежать в
        # root-овой папке, и кладёт его туда он сам (native.tun.install_singbox
        # без установленного демона так и отвечает — «сначала установи
        # системный компонент»). Ставим демона прямо здесь, иначе этот вход в
        # TUN отправлял бы пользователя ровно туда, откуда он сюда пришёл.
        if sys.platform == "darwin" and not self._ensure_privilege():
            return
        # wintun — драйвер виртуального адаптера, он есть только на Windows;
        # на macOS роль адаптера играет штатный utun, качать нечего.
        what = "sing-box" if sys.platform == "darwin" else "sing-box + wintun"
        self._append_log(f"[*] Скачиваю {what} (для TUN-режима)…")
        self._run_download(download_tun, "TUN-компоненты установлены (sing-box {tag}).", "TUN")

    def _remove_tun(self) -> None:
        """Удалить sing-box (и wintun на Windows). Системный компонент остаётся.

        Отключаемся первыми и на обеих платформах: удалять файлы из-под
        работающего туннеля нельзя. На macOS демон и сам откажет живому
        туннелю, но полагаться на его отказ значило бы показать пользователю
        ошибку вместо действия; на Windows отказала бы уже сама система —
        занятый sing-box.exe не удаляется.
        """
        r = QMessageBox.question(
            self, "Удалить компоненты TUN",
            "TUN-режим перестанет работать, пока компоненты не скачают заново.\n"
            "Удалить?",
        )
        if r != QMessageBox.Yes:
            return
        self.disconnect_vpn()
        try:
            removed = remove_tun(progress=self._append_log)
        except Exception as e:  # noqa: BLE001
            self._append_log(f"[!] Не удалось удалить компоненты TUN: {e}")
            QMessageBox.warning(self, "Не вышло", str(e))
            return
        self._append_log(
            "[*] Компоненты TUN удалены." if removed
            else "[i] Компоненты TUN и так не были установлены."
        )

    def _run_download(self, fn, success_text: str, what: str) -> None:
        dlg = self._progress_dialog(f"Скачиваю {what}…")
        # Ссылка на воркер нужна внутри лямбды, которая создаётся раньше самого
        # воркера. Так можно: тело лямбды выполняется уже во время загрузки,
        # когда w давно присвоен.
        w = Worker(lambda log: fn(progress=log, on_bytes=lambda got, total: w.progress.emit(got, total)))
        w.log.connect(self._append_log)
        w.log.connect(dlg.setLabelText)
        w.progress.connect(lambda got, total: self._show_progress(dlg, got, total))
        w.failed.connect(lambda err: (
            dlg.close(),
            self._append_log(f"[!] Не удалось скачать {what}: {err.splitlines()[0]}"),
            self._workers.remove(w),
        ))
        w.done.connect(lambda tag: (
            dlg.close(),
            QMessageBox.information(self, "Готово", success_text.format(tag=tag)),
            self._workers.remove(w),
        ))
        self._workers.append(w)
        w.start()

    def _progress_dialog(self, text: str) -> QProgressDialog:
        """Окно загрузки: полоска и текущий шаг. Без кнопки отмены.

        Отмены нет намеренно: прервать можно было бы только сам поток, а он
        сидит в чтении сокета — на macOS вдобавок в чужом, демоновом, где
        качает root. Кнопка, которая закрывает окно, но не останавливает
        загрузку, врёт про то, что она делает.

        Полоска стартует бегущей (максимум 0). Кто умеет считать байты,
        переведёт её в проценты первым же on_bytes; кто не умеет (sing-box на
        macOS качает демон) — оставит бегущей до конца, и это честно.
        """
        dlg = QProgressDialog(text, None, 0, 0, self)
        dlg.setWindowTitle("Загрузка")
        dlg.setWindowModality(Qt.WindowModal)
        dlg.setAutoClose(False)
        dlg.setAutoReset(False)
        # Иначе Qt держит окно скрытым первые 4 секунды — ровно те, ради
        # которых окно и заводили: на быстром канале ядро успевает скачаться,
        # и пользователь не видит вообще ничего.
        dlg.setMinimumDuration(0)
        dlg.show()
        return dlg

    @staticmethod
    def _show_progress(dlg: QProgressDialog, got: int, total: int) -> None:
        """Перевести полоску в проценты. Считаем в КБ: байты переполняют int32,
        которым Qt меряет прогресс, уже на двух гигабайтах."""
        if total <= 0:                     # сервер не прислал Content-Length
            return
        dlg.setMaximum(total // 1024)
        dlg.setValue(got // 1024)

    def _remove_helper(self) -> None:
        """Снять привилегированный демон TUN (только macOS)."""
        r = QMessageBox.question(
            self, "Удалить системный компонент",
            "TUN-режим перестанет работать, пока компонент не установят заново.\n"
            "Удалить? Понадобится пароль администратора.",
        )
        if r != QMessageBox.Yes:
            return
        self.disconnect_vpn()
        from helper.install import uninstall

        try:
            uninstall()
        except RuntimeError as e:
            QMessageBox.warning(self, "Не вышло", str(e))
            return
        self._append_log("[*] Системный компонент удалён.")

    # ------------------------------------------------------------------
    # Прочее
    # ------------------------------------------------------------------
    def _on_mode_changed(self) -> None:
        mode = self.settings.get("vpn_mode", "proxy")
        # системный прокси имеет смысл только в режиме proxy
        self.sysproxy_action.setEnabled(mode == "proxy")
        if mode == "tun" and not privileged():
            self._append_log("[i] TUN потребует прав администратора при подключении.")
        self._update_substatus()

    def _append_log(self, text: str) -> None:
        self.log_view.appendPlainText(text)

    # ------------------------------------------------------------------
    # Закрытие окна — обязательно вернуть систему в исходное состояние
    # ------------------------------------------------------------------
    def closeEvent(self, event) -> None:  # noqa: N802
        try:
            tun_down = self.tun.stop()  # вернуть маршруты/адаптер
            if sysproxy.is_enabled():
                sysproxy.disable()
            self.runner.stop()
            # Именно на закрытии молчать нельзя больше всего: приложения через
            # секунду не будет, а поднятый utun с мёртвым туннелем останется —
            # без этого сообщения пользователь узнает о нём по пропавшей сети.
            if not tun_down:
                self._report_tun_stuck()
        finally:
            super().closeEvent(event)


def run_app() -> int:
    from native import paths

    app = QApplication(sys.argv)
    app.setApplicationName("SCVPN")
    theme.apply(app)
    ico = paths.icon_file()
    if ico.exists():
        app.setWindowIcon(QIcon(str(ico)))
    win = MainWindow()
    win.show()
    return app.exec()
