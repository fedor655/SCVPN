package com.scvpn

import com.journeyapps.barcodescanner.CaptureActivity

/**
 * Экран сканирования QR в вертикальной ориентации.
 *
 * Готовый CaptureActivity из zxing-android-embedded объявлен в манифесте
 * библиотеки как `sensorLandscape`, и настройками сканера это не меняется:
 * ориентацию задаёт манифест, а не код. Поэтому наследуемся и объявляем свой
 * экран с `screenOrientation="portrait"` — поведение остаётся библиотечным,
 * меняется только ориентация.
 *
 * Превью и распознавание при этом не ломаются: BarcodeView сам разворачивает
 * картинку с камеры по текущей ориентации экрана.
 */
class PortraitCaptureActivity : CaptureActivity()
