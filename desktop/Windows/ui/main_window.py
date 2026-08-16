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
    QProgressDialog,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from app_info import __version__
from connect import find_working_fingerprint
from core_runner import XrayRunner, find_free_port
from models import Server
from storage import (
    Profiles,
    Subscription,
    load_profiles,
    load_settings,
    now_iso,
    save_profiles,
    save_settings,
)
from subscription import SubscriptionError, fetch_subscription_full, parse_link
from xray_config import ROUTE_BYPASS_RU, ROUTE_GLOBAL, build_config
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
from .widgets import (
    ROLE_PING,
    ROLE_SERVER,
    ROLE_SUBTITLE,
    LogPane,
    PowerButton,
    ServerDelegate,
    hairline,
    pulse_icon,
)
from .workers import PingWorker, Worker

# Яркостью состояния не различаются: «Отключено» и «Подключено» одинаково
# белые, а отличает их форма кольца и само слово. Список цветов на состояния
# был и ушёл — в чёрно-белой теме он давал только ложное чувство разницы.
STATE_TEXTS = {
    "idle": "Отключено",
    "connecting": "Подключение…",
    "connected": "Подключено",
    "error": "Не подключилось",
    # Отдельное состояние, а не "error": ошибка подключения и «отключиться не
    # вышло» — разные новости, и вторая опаснее. См. _report_tun_stuck().
    "tun_stuck": "Туннель не снят",
}

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
        self.profiles: Profiles = load_profiles()
        self.settings: dict = load_settings()
        self.row_servers: list[Server] = []
        self._workers: list = []        # держим ссылки, чтобы потоки не удалялись
        self._want_connected = False
        self._state = "idle"
        self._connected_since: float | None = None
        # Имя сервера, с которым ядро действительно подняли. Не тот, что
        # выбран в списке: выбор меняется одним щелчком и живой туннель не
        # трогает, а новый список показывает выбор маркером и яркостью —
        # назвать здесь выбранный значило бы соврать заметнее прежнего.
        self._connected_title = ""
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
        # Полоса заголовка Windows чужая и светлее содержимого: без этой
        # линии непонятно, где кончается системная рамка и начинается
        # приложение.
        root.addWidget(hairline(central))

        root.addLayout(self._build_power_block())

        section = QLabel("СЕРВЕРЫ")
        section.setObjectName("section")
        section.setFont(theme.font_section())
        # Заголовок встаёт ровно над именами серверов, а не над краем строки:
        # колонка текста — самая заметная вертикаль в списке.
        section.setContentsMargins(
            theme.SECTION_PADDING, 0, theme.SECTION_PADDING, theme.SECTION_BOTTOM
        )
        root.addWidget(section)

        self.list = QListWidget()
        self.list.setItemDelegate(ServerDelegate(self.list))
        self.list.setMouseTracking(True)          # чтобы делегат видел наведение
        self.list.setSpacing(theme.LIST_SPACING)
        # Поля ушли внутрь строки: подсветка под курсором должна идти от края
        # до края окна, а не по карточке. Снизу остаётся просвет до лога.
        self.list.setViewportMargins(0, 0, 0, theme.LIST_BOTTOM)
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list.setSelectionMode(QListWidget.SingleSelection)
        self.list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self._list_context_menu)
        self.list.itemSelectionChanged.connect(self._on_selection_changed)
        self.list.itemDoubleClicked.connect(lambda *_: self._on_connect_clicked())
        root.addWidget(self.list, 1)

        self.empty_view = self._build_empty()
        root.addWidget(self.empty_view, 1)

        # Лог — не коробка на весь низ окна, а полоса с последней строкой:
        # читают его именно ради неё. Разворот — по щелчку.
        self.log = LogPane()
        self.log.setVisible(bool(self.settings.get("show_log", False)))
        root.addWidget(self.log)

        self.setCentralWidget(central)

    def _build_empty(self) -> QWidget:
        """Пустой список.

        Прежде здесь стояла одна серая фраза посреди пустоты, и экран выглядел
        так, будто список не загрузился. Теперь это два разных по весу
        сообщения: что произошло и что с этим делать — второе набрано как
        подпись, чтобы не спорило с первым.
        """
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(
            theme.EMPTY_PADDING, theme.EMPTY_PADDING,
            theme.EMPTY_PADDING, theme.EMPTY_PADDING,
        )
        lay.setSpacing(theme.EMPTY_GAP)
        lay.addStretch(1)

        title = QLabel("Серверов пока нет")
        title.setObjectName("emptyTitle")
        title.setFont(theme.font_row_title())
        title.setAlignment(Qt.AlignCenter)
        lay.addWidget(title)

        hint = QLabel("ДОБАВЬ ССЫЛКУ ИЛИ ПОДПИСКУ КНОПКОЙ  +")
        hint.setObjectName("emptyHint")
        hint.setFont(theme.font_section())
        hint.setAlignment(Qt.AlignCenter)
        hint.setWordWrap(True)
        lay.addWidget(hint)

        lay.addStretch(1)
        return box

    def _build_header(self) -> QHBoxLayout:
        header = QHBoxLayout()
        # Правый край группы кнопок совпадает с полем окна — это и есть общая
        # сетка. Просвета между кнопками нет: подложек у них больше нет, и
        # только вплотную они читаются как одна группа.
        header.setContentsMargins(
            theme.LIST_PADDING,
            theme.HEADER_TOP,
            theme.HEADER_TRAILING,
            theme.HEADER_BOTTOM,
        )
        header.setSpacing(theme.HEADER_SPACING)
        btn = QSize(theme.HEADER_BTN, theme.HEADER_BTN)

        badge = QLabel()
        badge.setPixmap(mark_pixmap(20, QColor(theme.TEXT)))
        header.addWidget(badge)

        title = QLabel("SCVPN")
        title.setObjectName("wordmark")
        # Разрядка задаётся шрифтом: letter-spacing таблица стилей Qt молча
        # выбрасывает, и знак все эти годы стоял без неё.
        title.setFont(theme.font_wordmark())
        title.setContentsMargins(theme.HEADER_BADGE_GAP, 0, 0, 0)
        header.addWidget(title, 1)

        def tool(text: str, tip: str, slot) -> QToolButton:
            b = QToolButton()
            b.setText(text)
            b.setToolTip(tip)
            b.setFixedSize(btn)
            # Подложки у кнопок нет, и без autoRaise стиль рисует знак только
            # «нормальным»: наведение видно лишь у кнопок с приподнятым видом.
            b.setAutoRaise(True)
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(slot)
            header.addWidget(b)
            return b

        # Пинг — отдельной кнопкой в шапке, а не только в меню: его ищут глазами.
        # Рисуем знак вдвое крупнее нужного: Qt ужмёт его сам, и на экране с
        # масштабом 2 кардиограмма останется чёткой.
        ping_btn = QToolButton()
        ping_btn.setIcon(pulse_icon(size=theme.HEADER_ICON * 2))
        ping_btn.setIconSize(QSize(theme.HEADER_ICON, theme.HEADER_ICON))
        ping_btn.setToolTip("Измерить пинг серверов")
        ping_btn.setFixedSize(btn)
        ping_btn.setAutoRaise(True)
        ping_btn.setCursor(Qt.PointingHandCursor)
        ping_btn.clicked.connect(self._ping_all)
        header.addWidget(ping_btn)

        tool("+", "Добавить сервер или подписку", self._add_something)
        tool("↻", "Обновить подписки", self._update_subscriptions)

        self.menu_btn = tool("⋯", "Настройки и подписки", lambda: None)
        self.menu_btn.setPopupMode(QToolButton.InstantPopup)
        self.menu_btn.setMenu(self._build_menu())

        # Иконку окна не рисуем: её ставит run_app() из готового файла
        # (.ico/.icns), а окно без своей иконки берёт иконку приложения.
        return header

    def _build_power_block(self) -> QVBoxLayout:
        # Пустоты вокруг блока ужаты: кнопка выросла до 156, и прежние отступы
        # отдавали ей треть окна, оставляя списку четыре строки.
        block = QVBoxLayout()
        block.setContentsMargins(
            0, theme.POWER_BLOCK_PADDING, 0, theme.POWER_BLOCK_PADDING
        )
        block.setSpacing(0)

        self.power = PowerButton(theme.POWER_SIDE)
        self.power.clicked.connect(self._on_connect_clicked)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(self.power)
        row.addStretch(1)
        block.addLayout(row)

        self.status_label = QLabel(STATE_TEXTS["idle"])
        self.status_label.setObjectName("status")
        self.status_label.setFont(theme.font_status())
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setContentsMargins(0, theme.STATUS_TOP, 0, 0)
        block.addWidget(self.status_label)

        block.addWidget(self._build_status_detail())
        return block

    def _build_status_detail(self) -> QWidget:
        """Подробности под состоянием: строка «что сейчас» и подпись режима.

        Раньше это была одна строка вида «00:12:34 · системный прокси»: аптайм
        и режим — разные по природе вещи, живое число и настройка, — а
        разделяла их точка. Теперь режим стоит отдельной подписью и только при
        живом подключении: в простое он ничего не сообщает.

        Обе строки остаются в раскладке всегда, даже пустые, а у блока есть
        нижняя граница высоты: иначе список серверов подпрыгивал бы при каждой
        смене состояния. Высота именно минимальная, а не жёсткая — жёсткая
        ужала бы подписи ниже их строки, и у русских букв срезало бы хвосты.
        """
        box = QWidget()
        box.setMinimumHeight(theme.SUBSTATUS_HEIGHT)
        lay = QVBoxLayout(box)
        lay.setContentsMargins(
            theme.SUBSTATUS_PADDING, theme.SUBSTATUS_TOP, theme.SUBSTATUS_PADDING, 0
        )
        lay.setSpacing(theme.SUBSTATUS_LINE_GAP)

        self.substatus_label = QLabel("")
        self.substatus_label.setObjectName("substatus")
        # Цифры табличные: аптайм тикает раз в секунду, и пропорциональные
        # дёргали бы строку на каждом тике.
        self.substatus_label.setFont(theme.font_substatus())
        self.substatus_label.setAlignment(Qt.AlignCenter)
        lay.addWidget(self.substatus_label)

        self.mode_label = QLabel("")
        self.mode_label.setObjectName("mode")
        self.mode_label.setFont(theme.font_section())
        self.mode_label.setAlignment(Qt.AlignCenter)
        lay.addWidget(self.mode_label)

        lay.addStretch(1)
        return box

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
        # Настройка решает, видна ли полоса вообще; развёрнут ли лог — нет:
        # это состояние взгляда, а не приложения, и переживать перезапуск ему
        # незачем.
        self._set_setting("show_log", visible)
        self.log.setVisible(visible)

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

        self.empty_view.setVisible(not servers)
        self.list.setVisible(bool(servers))
        self._update_substatus()

    @staticmethod
    def _proto_label(s: Server) -> str:
        """Что видно под именем: протокол, адрес и транспорт — то, по чему
        пользователь отличает два сервера с одинаковым названием."""
        parts = [s.protocol, f"{s.address}:{s.port}"]
        if s.security not in ("", "none"):
            parts.append(s.security)
        if s.network != "tcp":
            parts.append(s.network)
        return " · ".join(parts)

    def _current_server(self) -> Server | None:
        item = self.list.currentItem()
        return item.data(ROLE_SERVER) if item else None

    def _on_selection_changed(self) -> None:
        s = self._current_server()
        if s:
            was = self.settings.get("selected_key", "")
            self._set_setting("selected_key", s.key())
            self._update_substatus()
            # Ядро уже запущено с прежним конфигом и само не переедет: без
            # этой строки список показывал бы один сервер, а трафик шёл через
            # другой. Android говорит то же самое.
            if was != s.key() and self._state == "connected":
                self._append_log("[i] Сервер сменится при следующем подключении")

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

        Порядок шагов не вкусовщина. Компоненты TUN — два файла рядом с
        приложением (sing-box и wintun.dll), которые кладёт установщик, а
        права — независимый от них UAC. Проверять файлы первыми правильно:
        иначе пользователь крутил бы круг UAC только затем, чтобы следом
        прочитать «нет компонентов».
        """
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
        self._connected_title = srv.title

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
        self._connected_title = ""
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
        self._update_substatus()

    def _update_substatus(self) -> None:
        self.substatus_label.setText(self._detail_line())
        self.mode_label.setText(self._mode_caption())

    def _detail_line(self) -> str:
        """Что происходит прямо сейчас: при живом подключении — какой сервер
        держит трафик и сколько уже держит, в остальных случаях — куда
        собирались подключаться."""
        if self._state == "connected" and self._connected_since:
            secs = int(time.monotonic() - self._connected_since)
            uptime = (
                f"{secs // 3600}:{secs // 60 % 60:02d}:{secs % 60:02d}"
                if secs >= 3600 else f"{secs // 60:02d}:{secs % 60:02d}"
            )
            # Разделитель тот же, что на macOS и Android: строка обязана
            # читаться одинаково на всех платформах.
            return uptime if not self._connected_title else f"{self._connected_title}  ·  {uptime}"
        if self._state == "tun_stuck":
            return "Трафик всё ещё идёт через туннель"
        server = self._current_server()
        return server.title if server else ""

    def _mode_caption(self) -> str:
        """Режим — только при живом подключении.

        В простое он ни о чём не сообщает: ничего ещё не выбрано и никуда не
        идёт. Пустая строка при этом остаётся в раскладке, иначе список под
        ней прыгал бы на каждом подключении.
        """
        if self._state != "connected":
            return ""
        return "ВЕСЬ ТРАФИК" if self.settings.get("vpn_mode") == "tun" else "СИСТЕМНЫЙ ПРОКСИ"

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
        # При живом подключении замер уходит в сам туннель и меряет дорогу до
        # сервера через сервер: цифры выглядели бы настоящими, но были бы
        # выдумкой. Отказ с объяснением, а не молча.
        if self.runner.running:
            self._append_log("[!] Отключись, чтобы померить пинг: "
                             "сейчас замер пойдёт через сам туннель.")
            return
        self._append_log("[*] Пингую серверы…")
        w = PingWorker(self.row_servers, route_mode=self.settings.get("route_mode", "global"))
        w.log.connect(self._append_log)
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
        # wintun — драйвер виртуального адаптера: без него sing-box не поднимет
        # интерфейс, поэтому качаются оба файла разом.
        self._append_log("[*] Скачиваю sing-box + wintun (для TUN-режима)…")
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
        self.log.append(text)

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
