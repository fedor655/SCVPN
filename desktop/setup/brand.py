"""Фирменный знак SCVPN — рисуется кодом, без внешних картинок и шрифтов.

Знак: геометрическая монограмма «S» из двух дуг с круглыми окончаниями,
залитая градиентом, на почти чёрной подложке. Одна форма, читается и в 16 px,
и на рабочем столе — поэтому иконка и интерфейс выглядят одинаково спокойно.

Модуль общий: им пользуются и `setup/make_icon.py` (Windows .ico),
и генератор иконок Android. Ничего не качает — всё считается на месте.
"""
from __future__ import annotations

from PIL import Image, ImageDraw

# --- палитра ---------------------------------------------------------------
BG_TOP = (19, 26, 36)      # #131A24
BG_BOTTOM = (10, 14, 19)   # #0A0E13
MARK_TOP = (45, 212, 191)  # #2DD4BF  бирюзовый
MARK_BOTTOM = (59, 130, 246)  # #3B82F6  синий

# Во сколько раз рисуем крупнее итогового размера (сглаживание дуг).
SS = 4


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _vgradient(size: int, top, bottom) -> Image.Image:
    """Вертикальный градиент size x size."""
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        px[0, y] = _lerp(top, bottom, y / max(1, size - 1))
    return strip.resize((size, size), Image.NEAREST)


def _s_mask(size: int, scale: float = 1.0) -> Image.Image:
    """Маска монограммы «S» (белое на чёрном) на канве size x size.

    `scale` — доля канвы, которую занимает знак по высоте (1.0 ≈ 70 % канвы,
    как в готовой иконке; для Android-адаптива берём меньше — там своя
    безопасная зона).
    """
    import math

    n = size * SS
    m = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(m)

    cx = cy = n / 2
    rc = n * 0.155 * scale       # радиус осевой линии каждой чаши
    w = n * 0.090 * scale        # толщина штриха
    sweep = 255                  # насколько раскрыта чаша, градусов

    # Две окружности касаются ровно в центре канвы: низ верхней (90°) и верх
    # нижней (270°) — это одна и та же точка, причём с общей касательной.
    # Поэтому осевую можно пройти одной непрерывной ломаной, и стык выходит
    # гладким сам собой (в отличие от двух отдельных дуг, где он «защипывается»).
    cy_top = cy - rc
    cy_bot = cy + rc

    # Рисуем не «толстой линией» (PIL мохрит стыки сегментов), а контуром:
    # осевую разводим на ±w/2 по радиусу и заливаем получившийся многоугольник.
    # Обход по часовой меняет знак на изломе, поэтому у верхней чаши правая
    # сторона — наружная, а у нижней наоборот; из-за этого стороны и не
    # перехлёстываются в точке перегиба.
    steps = 180
    half = w / 2
    right: list[tuple[float, float]] = []
    left: list[tuple[float, float]] = []

    def add(centre_y: float, a_deg: float, outward_is_right: bool) -> None:
        a = math.radians(a_deg)
        ux, uy = math.cos(a), math.sin(a)
        outer = (cx + (rc + half) * ux, centre_y + (rc + half) * uy)
        inner = (cx + (rc - half) * ux, centre_y + (rc - half) * uy)
        if outward_is_right:
            right.append(outer); left.append(inner)
        else:
            right.append(inner); left.append(outer)

    for i in range(steps + 1):                    # верхняя чаша: терминал -> центр
        add(cy_top, 90 + sweep - sweep * i / steps, True)
    for i in range(1, steps + 1):                 # нижняя чаша: центр -> терминал
        add(cy_bot, 270 + sweep * i / steps, False)

    d.polygon(right + left[::-1], fill=255)

    # Круглые окончания на концах осевой.
    for centre_y, a_deg in ((cy_top, 90 + sweep), (cy_bot, 270 + sweep)):
        a = math.radians(a_deg)
        px, py = cx + rc * math.cos(a), centre_y + rc * math.sin(a)
        d.ellipse([px - half, py - half, px + half, py + half], fill=255)

    return m.resize((size, size), Image.LANCZOS)


def mark(size: int, scale: float = 1.0) -> Image.Image:
    """Только знак «S» в градиенте, прозрачный фон (RGBA)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = _vgradient(size, MARK_TOP, MARK_BOTTOM).convert("RGBA")
    img.paste(grad, (0, 0), _s_mask(size, scale))
    return img


def plate(size: int, radius_ratio: float = 0.22) -> Image.Image:
    """Тёмная подложка со скруглёнными углами (RGBA)."""
    n = size * SS
    grad = _vgradient(n, BG_TOP, BG_BOTTOM).convert("RGBA")
    m = Image.new("L", (n, n), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, n - 1, n - 1], radius=int(n * radius_ratio), fill=255
    )
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(grad, (0, 0), m)
    return out.resize((size, size), Image.LANCZOS)


def icon(size: int = 1024) -> Image.Image:
    """Готовая иконка: подложка + знак."""
    img = plate(size)
    img.alpha_composite(mark(size))
    return img
