"""Проверки платформенного слоя macOS.

Без фреймворков: обычные assert и печать результата — так же, как smoke_test.py.
Запуск:  ./test.sh
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


@check
def test_paths_data_dir_in_application_support():
    from native import paths

    if paths.FROZEN:
        assert paths.DATA_DIR.name == "SCVPN", paths.DATA_DIR
        assert "Application Support" in str(paths.DATA_DIR), paths.DATA_DIR
    else:
        # В разработке данные лежат рядом с проектом (ROOT/"data"), а не в
        # Application Support — так задумано в paths.py, чтобы было проще
        # проверить содержимое. Имя "SCVPN" гарантировано только в собранном
        # виде, поэтому здесь проверяем сам факт: путь под корнем проекта.
        assert paths.DATA_DIR == paths.ROOT / "data", paths.DATA_DIR


@check
def test_paths_binaries_have_no_exe_suffix():
    from native import paths

    assert paths.xray_exe().name == "xray", paths.xray_exe()
    assert paths.singbox_exe().name == "sing-box", paths.singbox_exe()


@check
def test_singbox_lives_in_root_owned_dir():
    """sing-box запускает root — значит он обязан лежать вне досягаемости пользователя."""
    from native import paths

    assert paths.singbox_exe().is_relative_to(paths.HELPER_BIN_DIR), paths.singbox_exe()
    assert str(paths.HELPER_BIN_DIR).startswith("/Library/"), paths.HELPER_BIN_DIR


def main() -> int:
    failed = 0
    for fn in CHECKS:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
    print(f"\n{len(CHECKS) - failed}/{len(CHECKS)} проверок пройдено.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
