"""Разовая перерисовка иконки Windows: setup/scvpn.ico + превью scvpn_256.png.

Готовые файлы лежат в git, сборка их не пересоздаёт — скрипт нужен, только
если поменялась геометрия знака (setup/brand.py, там же палитра, общая с
Android). Pillow в requirements.txt намеренно нет, ставится вручную.

Запуск:  .venv\\Scripts\\python.exe -m pip install Pillow
         .venv\\Scripts\\python.exe setup\\make_icon.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PIL import Image  # noqa: E402

import brand  # noqa: E402

ICO = HERE / "scvpn.ico"
PNG = HERE / "scvpn_256.png"
SIZES = [256, 128, 64, 48, 32, 16]


def main() -> None:
    base = brand.icon(1024)
    frames = [base.resize((s, s), Image.LANCZOS) for s in SIZES]
    frames[0].save(ICO, format="ICO", sizes=[(s, s) for s in SIZES])
    base.resize((256, 256), Image.LANCZOS).save(PNG)
    print(f"Иконка сохранена: {ICO}")
    print(f"Превью:           {PNG}")


if __name__ == "__main__":
    main()
