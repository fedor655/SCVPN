package com.scvpn

/**
 * Последние сообщения ядра — то, что показывает полоса лога внизу экрана.
 *
 * Приложение и раньше писало всё это в `android.util.Log`, но прочитать его на
 * телефоне без компьютера невозможно: `logcat` доступен только через adb.
 * Поэтому те же строки складываются ещё и сюда — **ничего нового не
 * логируется, просто написанное перестало быть недоступным**.
 *
 * Хранится хвост: лог читают ради последнего сообщения, а не ради истории, и
 * держать в памяти всю сессию незачем.
 */
object CoreLog {

    /** Сколько строк помним. Больше экрана всё равно не разворачивается. */
    private const val LIMIT = 200

    private val lines = ArrayDeque<String>()

    /** Кому сообщать о новой строке. Слушатель один — это экран. */
    @Volatile
    private var listener: ((String) -> Unit)? = null

    @Synchronized
    fun add(line: String) {
        val text = line.trim()
        if (text.isEmpty()) return
        lines.addLast(text)
        while (lines.size > LIMIT) lines.removeFirst()
        listener?.invoke(text)
    }

    @Synchronized
    fun snapshot(): List<String> = lines.toList()

    @Synchronized
    fun last(): String? = lines.lastOrNull()

    /**
     * Слушатель зовётся из потока, который писал строку, — а пишут из
     * фонового потока подъёма туннеля и из колбэка ядра. Перекладывать на
     * главный поток обязан тот, кто подписался.
     */
    fun onLine(block: ((String) -> Unit)?) {
        listener = block
    }
}
