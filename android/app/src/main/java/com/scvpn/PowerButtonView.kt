package com.scvpn

import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.os.SystemClock
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.animation.LinearInterpolator
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.DrawableCompat
import kotlin.math.cos
import kotlin.math.min

/**
 * Круглая кнопка подключения.
 *
 * Состояние показывается **формой кольца**, а не только цветом: подключено —
 * толстое сплошное, ошибка — пунктир, простой — тонкое приглушённое. В
 * чёрно-белой теме иначе никак, и это осознанное решение доступности. Формы
 * задаёт ядро (`ConnectionState.ring` в `core-swift`), здесь они только
 * повторены числами — трогать их нельзя, иначе состояния станут выглядеть
 * по-разному на разных платформах.
 *
 * Кнопка — единственная вещь на экране, у которой есть объём: заливка идёт
 * радиальным переходом, будто свет падает сверху, и внутри кольца проходит
 * кромка шайбы. Всё остальное плоское, поэтому взгляд идёт сюда первым.
 *
 * Рисуется вручную, а не через `GradientDrawable` в разметке: радиальный
 * переход, кромка, бегущая дуга и «дыхание» — это четыре слоя поверх одной
 * окружности, и собрать их из XML-фигур можно только слоями фиксированных
 * размеров, которые разъедутся при другой плотности экрана.
 */
class PowerButtonView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    companion object {
        /** Секунд на полный вдох-выдох кольца в простое. */
        const val BREATH_MS = 3600L
        /** До какой яркости кольцо притухает на выдохе. */
        const val BREATH_LOW = 0.5f
        /**
         * Частота перерисовки «дыхания». Двадцать четыре кадра хватает для
         * медленного затухания, а экран висит открытым подолгу — гонять ради
         * него полный refresh rate незачем, это батарея.
         */
        const val BREATH_FRAME_MS = 1000 / 24

        /** Миллисекунд на оборот бегущей дуги. */
        const val SPIN_MS = 1400L
        /** Сколько градусов занимает дуга. */
        const val ARC_SWEEP = 100f
        /** Насколько притушено кольцо-подложка под бегущей дугой. */
        const val TRACK_ALPHA = 0.22f

        /**
         * Переход между состояниями. Четверть секунды — столько, чтобы глаз
         * успел заметить смену и не начал ждать. Дольше означало бы, что
         * после нажатия кнопка ещё раздумывает, хотя сервис уже стартовал.
         *
         * Тем же переходом разворачивается лог — оттуда сюда и смотрят, чтобы
         * второго числа не завелось.
         */
        const val STATE_MS = 250L

        // Доли стороны. Живут здесь, а не в dimens.xml: это отношения, а не
        // размеры, — при другой стороне кнопки они обязаны остаться прежними.

        /** Отступ кромки шайбы от кольца состояния. */
        const val EDGE_SHARE = 0.11f
        /** Радиус радиального перехода. */
        const val FILL_RADIUS_SHARE = 0.62f
        /** Центр перехода по вертикали: свет падает сверху. */
        const val FILL_CENTER_Y = 0.34f
        /** Сторона знака «S» внутри кольца. */
        const val MARK_SHARE = 0.48f
    }

    /** Вид кольца: цвет, толщина, пунктир. */
    private class Ring(val color: Int, val width: Float, val dashed: Boolean)

    private val thin = resources.getDimension(R.dimen.power_ring_thin)
    private val thick = resources.getDimension(R.dimen.power_ring_thick)
    private val hairline = resources.getDimension(R.dimen.hairline)

    private val colorSurface = ContextCompat.getColor(context, R.color.surface)
    private val colorSurfaceHi = ContextCompat.getColor(context, R.color.surface_hi)
    private val colorStroke = ContextCompat.getColor(context, R.color.stroke)
    private val colorText = ContextCompat.getColor(context, R.color.text)
    private val colorMuted = ContextCompat.getColor(context, R.color.muted)
    private val colorAccent = ContextCompat.getColor(context, R.color.accent)

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = hairline
        color = colorStroke
    }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val arcBox = RectF()
    private val blend = ArgbEvaluator()

    private val mark = ContextCompat.getDrawable(context, R.drawable.ic_scvpn_mark)?.mutate()

    /** Показываемое состояние. Меняется только через [show]. */
    var state: VpnState = VpnState.IDLE
        private set

    /**
     * Состояние, из которого растворяемся, и доля перехода.
     *
     * Кольца разных состояний растворяются друг в друга целиком, а не
     * «доанимируются»: пунктир не интерполируется вовсе, а рывок толщины с 3
     * на 5 читался бы как подёргивание.
     */
    private var from: VpnState = VpnState.IDLE
    private var fade = 1f

    private var breathWave = 1f
    private var breathFrameAt = 0L
    private var spinAngle = 0f

    private val breathing = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = BREATH_MS
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { a ->
            // Синус даёт плавный разворот на обоих концах: без него вдох и
            // выдох стыкуются рывком.
            val t = (a.animatedValue as Float).toDouble()
            breathWave = ((1 - cos(2 * Math.PI * t)) / 2).toFloat()
            val now = SystemClock.uptimeMillis()
            if (now - breathFrameAt >= BREATH_FRAME_MS) {
                breathFrameAt = now
                invalidate()
            }
        }
    }

    private val spinning = ValueAnimator.ofFloat(0f, 360f).apply {
        duration = SPIN_MS
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { a -> spinAngle = a.animatedValue as Float; invalidate() }
    }

    private val fading = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = STATE_MS
        addUpdateListener { a -> fade = a.animatedValue as Float; invalidate() }
    }

    init {
        isClickable = true
        isFocusable = true
    }

    /** Показать состояние. Смена идёт растворением, повтор игнорируется. */
    fun show(next: VpnState) {
        if (next == state) return
        fading.cancel()
        from = state
        state = next
        fade = 0f
        fading.start()
        syncAnimators()
    }

    private fun ring(s: VpnState): Ring = when (s) {
        VpnState.IDLE -> Ring(colorMuted, thin, false)
        VpnState.CONNECTING -> Ring(colorText, thin, false)
        VpnState.CONNECTED -> Ring(colorAccent, thick, false)
        VpnState.ERROR -> Ring(colorText, thin, true)
    }

    // ------------------------------------------------------------------
    // Отрисовка
    // ------------------------------------------------------------------
    override fun onDraw(canvas: Canvas) {
        val side = min(width, height).toFloat()
        val cx = width / 2f
        val cy = height / 2f

        val a = ring(from)
        val b = ring(state)

        // Кромка и заливка привязаны к кольцу, поэтому их радиус растворяется
        // вместе с его толщиной, а не прыгает на 2 пикселя в момент смены.
        val inset = a.width + (b.width - a.width) * fade
        val r = side / 2f - inset
        if (r <= 0) return

        // Свет сверху: центр перехода смещён вверх, к краям шайба уходит в
        // фон. Под нажатием вся заливка светлеет на ступень — так же, как на
        // десктопе под курсором.
        val inner = if (isPressed) colorStroke else colorSurfaceHi
        fillPaint.shader = RadialGradient(
            cx, cy - r + 2 * r * FILL_CENTER_Y, side * FILL_RADIUS_SHARE,
            inner, colorSurface, Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(cx, cy, r, fillPaint)

        // Кромка шайбы. Тонкая и заметно меньше кольца состояния — спутать их
        // нельзя, а плоский круг она превращает в предмет.
        val edgeR = r - side * EDGE_SHARE
        if (edgeR > 0) canvas.drawCircle(cx, cy, edgeR, edgePaint)

        if (fade < 1f) drawRing(canvas, cx, cy, r, from, a, 1f - fade)
        drawRing(canvas, cx, cy, r, state, b, fade)

        drawMark(canvas, cx, cy, side, a.color, b.color)
    }

    private fun drawRing(
        canvas: Canvas, cx: Float, cy: Float, r: Float,
        which: VpnState, ring: Ring, alpha: Float,
    ) {
        if (alpha <= 0.01f) return
        ringPaint.strokeWidth = ring.width
        ringPaint.strokeCap = Paint.Cap.BUTT
        // Пунктир задаётся в долях толщины линии — так же, как на десктопе.
        ringPaint.pathEffect =
            if (ring.dashed) DashPathEffect(floatArrayOf(ring.width * 3, ring.width * 3), 0f)
            else null

        when (which) {
            VpnState.CONNECTING -> {
                // Тусклое кольцо целиком плюс яркая дуга, бегущая по нему.
                ringPaint.color = ring.color
                ringPaint.alpha = opacity(alpha * TRACK_ALPHA)
                canvas.drawCircle(cx, cy, r, ringPaint)

                arcBox.set(cx - r, cy - r, cx + r, cy + r)
                ringPaint.color = ring.color
                ringPaint.alpha = opacity(alpha)
                ringPaint.strokeCap = Paint.Cap.ROUND
                canvas.drawArc(arcBox, spinAngle, ARC_SWEEP, false, ringPaint)
            }
            VpnState.IDLE -> {
                // Дыхание меняет только яркость: форма кольца, по которой
                // состояния и различаются, остаётся прежней.
                ringPaint.color = ring.color
                ringPaint.alpha = opacity(alpha * (BREATH_LOW + (1 - BREATH_LOW) * breathWave))
                canvas.drawCircle(cx, cy, r, ringPaint)
            }
            else -> {
                ringPaint.color = ring.color
                ringPaint.alpha = opacity(alpha)
                canvas.drawCircle(cx, cy, r, ringPaint)
            }
        }
    }

    private fun drawMark(canvas: Canvas, cx: Float, cy: Float, side: Float, was: Int, now: Int) {
        val m = mark ?: return
        val half = (side * MARK_SHARE / 2f).toInt()
        m.setBounds(cx.toInt() - half, cy.toInt() - half, cx.toInt() + half, cy.toInt() + half)
        DrawableCompat.setTint(m, blend.evaluate(fade, was, now) as Int)
        m.draw(canvas)
    }

    private fun opacity(value: Float): Int = (value * 255).toInt().coerceIn(0, 255)

    // ------------------------------------------------------------------
    // Нажатие: ровно круг, а не квадрат вокруг него
    // ------------------------------------------------------------------
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN && !insideCircle(event.x, event.y)) {
            return false
        }
        return super.onTouchEvent(event)
    }

    private fun insideCircle(x: Float, y: Float): Boolean {
        val side = min(width, height).toFloat()
        val r = side / 2f - ring(state).width
        val dx = x - width / 2f
        val dy = y - height / 2f
        return dx * dx + dy * dy <= r * r
    }

    /** Заливка светлеет под нажатием — значит, её надо перерисовать. */
    override fun drawableStateChanged() {
        super.drawableStateChanged()
        invalidate()
    }

    // ------------------------------------------------------------------
    // Расписание анимаций
    // ------------------------------------------------------------------
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        syncAnimators()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        breathing.cancel()
        spinning.cancel()
        fading.cancel()
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility)
        syncAnimators()
    }

    /**
     * Каждая анимация отвечает на свой вопрос, поэтому крутится только та, чей
     * вопрос сейчас задан: дуга — «идёт подключение», дыхание — «приложение
     * живо» в простое. Невидимый экран не крутит ничего: это батарея.
     */
    private fun syncAnimators() {
        val live = isAttachedToWindow && visibility == VISIBLE
        if (live && state == VpnState.IDLE) {
            if (!breathing.isStarted) breathing.start()
        } else {
            breathing.cancel()
        }
        if (live && state == VpnState.CONNECTING) {
            if (!spinning.isStarted) spinning.start()
        } else {
            spinning.cancel()
        }
        invalidate()
    }
}
