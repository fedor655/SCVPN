package com.scvpn

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * QR-код ссылки подписки — чтобы перенести её на другое устройство,
 * не пересылая текст.
 *
 * Рисуем чёрным по белому даже в тёмной теме: сканеры рассчитывают именно на
 * такой контраст, инверсия читается заметно хуже.
 */
object Qr {
    fun encode(text: String, size: Int): Bitmap? = runCatching {
        val hints = mapOf(
            EncodeHintType.MARGIN to 1,
            // Ссылка подписки длинная, поэтому уровень коррекции берём средний:
            // на высоком код стал бы плотнее и хуже читался с экрана.
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            EncodeHintType.CHARACTER_SET to "UTF-8",
        )
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, hints)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.RGB_565)
        val row = IntArray(size)
        for (y in 0 until size) {
            for (x in 0 until size) {
                row[x] = if (matrix[x, y]) Color.BLACK else Color.WHITE
            }
            bmp.setPixels(row, 0, size, 0, y, size, 1)
        }
        bmp
    }.getOrNull()
}
