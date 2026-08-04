"""Сканер QR-кода веб-камерой — чтобы перенести подписку с телефона.

Захват и распознавание делает OpenCV: у него есть и работа с камерой, и
детектор QR, так что одной зависимостью закрывается всё. Картинку показываем
сами через Qt — окна OpenCV нам не нужны, поэтому берётся сборка headless.

Камеру открываем уже после показа окна: инициализация занимает около секунды,
и делать её до отрисовки означало бы «зависшее» окно при открытии.
"""
from __future__ import annotations

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
)

from . import theme

# Сколько индексов камер перебирать по кнопке «другая камера».
MAX_CAMERAS = 4


class QrScannerDialog(QDialog):
    """Показывает картинку с камеры и ждёт QR. Результат — в `text`."""

    found = Signal(str)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Сканировать QR-код")
        self.setMinimumSize(520, 460)

        self.text: str = ""
        self._cap = None
        self._index = 0
        self._detector = None
        self._frames = 0

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 14, 16, 14)
        root.setSpacing(10)

        self.video = QLabel("Открываю камеру…")
        self.video.setAlignment(Qt.AlignCenter)
        self.video.setMinimumHeight(340)
        self.video.setStyleSheet(
            f"background: {theme.BG}; border: 1px solid {theme.STROKE};"
            f"border-radius: 10px; color: {theme.DIM};"
        )
        root.addWidget(self.video, 1)

        self.hint = QLabel("Поднеси QR-код подписки к камере")
        self.hint.setAlignment(Qt.AlignCenter)
        self.hint.setStyleSheet(f"color: {theme.DIM}; font-size: 12px;")
        root.addWidget(self.hint)

        row = QHBoxLayout()
        self.switch_btn = QPushButton("Другая камера")
        self.switch_btn.clicked.connect(self._next_camera)
        cancel = QPushButton("Отмена")
        cancel.clicked.connect(self.reject)
        row.addWidget(self.switch_btn)
        row.addStretch(1)
        row.addWidget(cancel)
        root.addLayout(row)

        self._timer = QTimer(self)
        self._timer.setInterval(33)          # ~30 кадров в секунду
        self._timer.timeout.connect(self._tick)

        QTimer.singleShot(50, self._open_camera)

    # ------------------------------------------------------------------
    def _open_camera(self, index: int = 0) -> None:
        try:
            import cv2
        except ImportError:
            self.video.setText(
                "Не установлен модуль opencv-python-headless —\nсканирование недоступно."
            )
            self.switch_btn.setEnabled(False)
            return

        self._release()
        self._detector = cv2.QRCodeDetector()
        self._index = index
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap.release()
            cap = cv2.VideoCapture(index)      # запасной вариант: другой бэкенд
        if not cap.isOpened():
            cap.release()
            self.video.setText(f"Камера {index} недоступна.\nПопробуй «Другая камера».")
            return

        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        self._cap = cap
        self._timer.start()

    def _next_camera(self) -> None:
        self._open_camera((self._index + 1) % MAX_CAMERAS)

    # ------------------------------------------------------------------
    def _tick(self) -> None:
        import cv2

        if self._cap is None:
            return
        ok, frame = self._cap.read()
        if not ok:
            return

        # Зеркалим: так держать телефон перед камерой привычнее.
        frame = cv2.flip(frame, 1)

        # Распознаём через кадр — детектор заметно дороже отрисовки, а QR
        # держат перед камерой куда дольше, чем 1/15 секунды.
        self._frames += 1
        if self._frames % 2 == 0:
            self._try_decode(frame)

        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        h, w, _ = rgb.shape
        image = QImage(rgb.data, w, h, 3 * w, QImage.Format_RGB888).copy()
        self.video.setPixmap(
            QPixmap.fromImage(image).scaled(
                self.video.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation
            )
        )

    def _try_decode(self, frame) -> None:
        import cv2

        try:
            text, points, _ = self._detector.detectAndDecode(frame)
        except cv2.error:
            return
        if not text:
            return

        self.text = text.strip()
        self.hint.setText("Код распознан")
        self._timer.stop()
        self.found.emit(self.text)
        self.accept()

    # ------------------------------------------------------------------
    def _release(self) -> None:
        self._timer.stop()
        if self._cap is not None:
            self._cap.release()
            self._cap = None

    def closeEvent(self, event) -> None:  # noqa: N802
        self._release()
        super().closeEvent(event)

    def done(self, result: int) -> None:  # noqa: A003
        # Камеру освобождаем при любом исходе, иначе она осталась бы занятой
        # для других программ до выхода из приложения.
        self._release()
        super().done(result)


def scan_qr(parent=None) -> str:
    """Открыть сканер и вернуть распознанный текст (пустая строка — отменили)."""
    dlg = QrScannerDialog(parent)
    return dlg.text if dlg.exec() == QDialog.Accepted else ""
