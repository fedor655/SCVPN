"""Запасные ic_launcher.png для Android 7 (API 24-25) — там адаптивных иконок ещё нет.

Начиная с API 26 система берёт mipmap-anydpi-v26/ic_launcher.xml (вектор + фон),
поэтому PNG нужны только как fallback. Рисуются тем же кодом, что и иконка
десктопной версии, — общий модуль brand.py, чтобы знак не разъехался.

Запуск:  python make_launcher_icons.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RES = HERE / "app" / "src" / "main" / "res"

# Где искать brand.py: сначала рядом (если проекты уложены в один репозиторий),
# потом — в десктопном проекте на своём месте.
CANDIDATES = [
    HERE / "brand",
    HERE.parent / "brand",
    HERE.parent / "desktop" / "setup",
    Path(r"C:\Users\semin\OneDrive\Рабочий стол\впны\свой хапп\setup"),
]
for path in CANDIDATES:
    if (path / "brand.py").exists():
        sys.path.insert(0, str(path))
        break
else:
    sys.exit("[!] Не найден brand.py. Проверял:\n  " + "\n  ".join(map(str, CANDIDATES)))

from PIL import Image  # noqa: E402

import brand  # noqa: E402

DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def main() -> None:
    base = brand.icon(1024)
    for name, size in DENSITIES.items():
        out = RES / f"mipmap-{name}"
        out.mkdir(parents=True, exist_ok=True)
        ic = base.resize((size, size), Image.LANCZOS)
        ic.save(out / "ic_launcher.png")
        ic.save(out / "ic_launcher_round.png")
        print(f"  mipmap-{name}/ic_launcher.png ({size}px)")
    print("Готово.")


if __name__ == "__main__":
    main()
