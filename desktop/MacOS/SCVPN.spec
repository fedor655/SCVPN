# -*- mode: python ; coding: utf-8 -*-
# Сборка SCVPN.app для macOS на Apple Silicon.
# Бинарники ядра (xray, гео-базы, sing-box) сюда НЕ упаковываются: приложение
# качает их само, а sing-box вдобавок обязан лежать в root-овой папке демона.

a = Analysis(
    ['run.py'],
    pathex=['..'],          # чтобы нашёлся пакет shared
    binaries=[],
    datas=[('setup/scvpn.icns', '.')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'PySide6.QtWebEngineCore', 'PySide6.QtWebEngineWidgets',
              'PySide6.Qt3DCore', 'PySide6.QtQuick', 'PySide6.QtQml',
              'PySide6.QtCharts', 'PySide6.QtDataVisualization', 'PySide6.QtPdf'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='SCVPN',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,              # upx ломает подпись бинарников на macOS
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch='arm64',
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='SCVPN',
)
app = BUNDLE(
    coll,
    name='SCVPN.app',
    icon='setup/scvpn.icns',
    bundle_identifier='com.scvpn.client',
    info_plist={
        'CFBundleName': 'SCVPN',
        'CFBundleDisplayName': 'SCVPN',
        'CFBundleShortVersionString': '1.0',
        'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True,
        # Без этого ключа система молча не отдаст камеру сканеру QR.
        'NSCameraUsageDescription':
            'Камера нужна только чтобы считать QR-код ссылки подписки.',
        # Приложение живёт в окне, а не в строке меню.
        'LSUIElement': False,
    },
)
