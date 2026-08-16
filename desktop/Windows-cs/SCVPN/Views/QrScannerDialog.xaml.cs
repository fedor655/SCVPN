using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Devices.Enumeration;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using ZXing;
using ZXing.Common;
using SCVPN.Theme;

namespace SCVPN.Views;

/// <summary>
/// Сканер QR-кода веб-камерой — чтобы перенести подписку с телефона.
///
/// Прежняя версия (ui/qr_scanner.py) делала и захват, и распознавание одним
/// OpenCV. Здесь так нельзя: колёс opencv-python под Windows on ARM не
/// существует вовсе, а порт затевался именно ради arm64. Поэтому работа
/// разделена на две части, и обе живут на arm64 нативно: камеру открывает
/// WinRT (Windows.Media.Capture), распознаёт ZXing.Net — чистый C#.
///
/// Из двух путей WinRT выбран MediaFrameReader: он отдаёт поток кадров, как
/// и прежний VideoCapture.read(), — картинка живая, лага нет и камера не
/// щёлкает затвором. Запасной путь, если MediaFrameReader на какой-то камере
/// не заведётся: периодический MediaCapture.CapturePhotoToStreamAsync раз в
/// 300–400 мс в InMemoryRandomAccessStream с последующим BitmapDecoder.
/// Он короче, но у части камер даёт щелчок затвора и заметную задержку, и
/// именно поэтому он здесь только описан, а не закодирован вторым путём:
/// два пути одновременно — это два пути, которые никто не проверяет.
///
/// Камеру открываем уже после показа окна: инициализация занимает около
/// секунды, и делать её до отрисовки означало бы «зависшее» окно при открытии.
/// </summary>
public partial class QrScannerDialog : Window
{
    /// <summary>
    /// Высота окна из прежней версии. Ширина общая у всех окон поверх
    /// главного (Metrics.SheetWidth): сканер открывают из окна добавления,
    /// и разница в ширине была бы заметна сразу.
    /// </summary>
    private const double DialogHeight = 460;

    /// <summary>
    /// Нижняя граница высоты картинки. Меньше — и QR с экрана телефона
    /// перестаёт разбираться: модули кода схлопываются в кашу.
    /// </summary>
    private const double VideoMinHeight = 340;

    /// <summary>
    /// Ширина кадра, которую просим у камеры, — та же, что просила прежняя
    /// версия (CAP_PROP_FRAME_WIDTH = 1280). Мельче — QR с экрана телефона не
    /// разбирается, крупнее — распознавание не успевает за кадрами.
    /// </summary>
    private const int PreferredFrameWidth = 1280;

    /// <summary>
    /// Распознаём через кадр: детектор заметно дороже отрисовки, а QR держат
    /// перед камерой куда дольше, чем 1/15 секунды.
    /// </summary>
    private const int DecodeEveryNthFrame = 2;

    private readonly BarcodeReaderGeneric _decoder;

    private IReadOnlyList<DeviceInformation> _devices = new List<DeviceInformation>();
    private int _deviceIndex;

    private MediaCapture? _capture;
    private MediaFrameReader? _frameReader;

    /// <summary>
    /// Два буфера кадра по очереди: пока интерфейс рисует один, камера пишет
    /// в другой. Одного не хватает — Dispatcher.InvokeAsync возвращает
    /// управление сразу, и следующий кадр затирал бы картинку прямо во время
    /// отрисовки.
    /// </summary>
    private readonly byte[]?[] _frames = new byte[]?[2];
    private int _frameSlot;
    private byte[]? _gray;
    private Windows.Storage.Streams.Buffer? _copyBuffer;

    private WriteableBitmap? _screen;
    private int _frameCount;

    /// <summary>Замок обработчика кадров: кадры приходят из чужого потока.</summary>
    private int _busy;

    /// <summary>Единица — предыдущий кадр ещё не дорисован, новый не шлём.</summary>
    private int _uiPending;

    /// <summary>
    /// Номер попытки открыть камеру. Открытие асинхронное, и пока оно идёт,
    /// можно успеть нажать «Другая камера» или закрыть окно; по несовпадению
    /// номера запоздавшая попытка сама себя убирает.
    /// </summary>
    private int _generation;

    private bool _closed;

    /// <summary>Распознанный текст. Пустая строка — окно закрыли без результата.</summary>
    public string Text { get; private set; } = "";

    public QrScannerDialog()
    {
        InitializeComponent();

        // FontFamily из Metrics.UiFont ставится здесь, а не в XAML: x:Static
        // отдаёт строку, а свойству нужен FontFamily, и конвертер типов к
        // результату разметочного расширения не применяется.
        FontFamily = new FontFamily(Metrics.UiFont);
        Height = DialogHeight;
        MinHeight = DialogHeight;

        ApplyMetrics();

        _decoder = new BarcodeReaderGeneric
        {
            // Поворот кадра перебором вчетверо дороже, а QR читается в любой
            // ориентации сам — искать в повёрнутых копиях нечего.
            AutoRotate = false,
            Options = new DecodingOptions
            {
                PossibleFormats = new List<BarcodeFormat> { BarcodeFormat.QR_CODE },
                TryHarder = true,
            },
        };
    }

    /// <summary>
    /// Отступы и скругления. Живут в коде, потому что Thickness и CornerRadius
    /// в XAML из отдельных чисел не собрать, а числа обязаны остаться в Metrics.
    /// </summary>
    private void ApplyMetrics()
    {
        Root.Margin = new Thickness(
            Metrics.SheetPadH, Metrics.SheetPadV, Metrics.SheetPadH, Metrics.SheetPadV);

        VideoBox.MinHeight = VideoMinHeight;
        VideoBox.BorderThickness = new Thickness(Metrics.StrokeWidth);
        VideoBox.CornerRadius = new CornerRadius(Metrics.BoxCorner);

        // Просвет между блоками — верхним отступом каждого следующего:
        // Grid в WPF не умеет расстояния между строками.
        Hint.Margin = new Thickness(0, Metrics.SheetGap, 0, 0);
        ButtonRow.Margin = new Thickness(0, Metrics.SheetGap, 0, 0);
    }

    // ------------------------------------------------------------------
    // Камера
    // ------------------------------------------------------------------

    private async void OnContentRendered(object? sender, EventArgs e)
    {
        try
        {
            _devices = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture);
        }
        catch (Exception ex)
        {
            ShowMessage("Не удалось получить список камер:\n" + ex.Message);
            SwitchButton.IsEnabled = false;
            return;
        }

        if (_closed)
        {
            return;
        }

        if (_devices.Count == 0)
        {
            ShowMessage("Камера не найдена.\nПодключи веб-камеру и открой сканер заново.");
            SwitchButton.IsEnabled = false;
            return;
        }

        // Переключать не на что — кнопка только моргала бы картинкой,
        // переоткрывая ту же самую камеру.
        SwitchButton.IsEnabled = _devices.Count > 1;

        await OpenCameraAsync(0);
    }

    private async void OnSwitchCamera(object sender, RoutedEventArgs e)
    {
        if (_devices.Count == 0)
        {
            return;
        }

        await OpenCameraAsync(_deviceIndex + 1);
    }

    /// <summary>Открыть камеру по кругу: за последней снова идёт первая.</summary>
    private async Task OpenCameraAsync(int index)
    {
        ReleaseCamera();
        if (_closed || _devices.Count == 0)
        {
            return;
        }

        var generation = ++_generation;
        _deviceIndex = index % _devices.Count;
        var device = _devices[_deviceIndex];

        ShowMessage("Открываю камеру…");
        SwitchButton.IsEnabled = false;

        try
        {
            var capture = await InitializeCaptureAsync(device);
            if (capture is null)
            {
                return;
            }

            if (_closed || generation != _generation)
            {
                capture.Dispose();
                return;
            }

            var source = PickColorSource(capture);
            if (source is null)
            {
                capture.Dispose();
                ShowMessage($"Камера «{device.Name}» не отдаёт кадры.\nПопробуй «Другая камера».");
                return;
            }

            await TrySetFormatAsync(source);

            MediaFrameReader reader;
            try
            {
                // Bgra8 просим явно: иначе кадр приходит в NV12 или YUY2, и
                // цветовое преобразование пришлось бы писать руками.
                reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            }
            catch (Exception ex)
            {
                capture.Dispose();
                ShowMessage($"Камера «{device.Name}» недоступна.\n{ex.Message}\nПопробуй «Другая камера».");
                return;
            }

            // Realtime — кадры не копятся в очереди, а теряются. Нам нужен
            // только последний: распознавать позавчерашний кадр бессмысленно.
            reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            reader.FrameArrived += OnFrameArrived;

            MediaFrameReaderStartStatus status;
            try
            {
                status = await reader.StartAsync();
            }
            catch (Exception ex)
            {
                DisposeCamera(capture, reader);
                ShowMessage($"Камера «{device.Name}» недоступна.\n{ex.Message}\nПопробуй «Другая камера».");
                return;
            }

            if (_closed || generation != _generation)
            {
                DisposeCamera(capture, reader);
                return;
            }

            if (status != MediaFrameReaderStartStatus.Success)
            {
                DisposeCamera(capture, reader);
                ShowMessage($"Камера «{device.Name}» недоступна ({status}).\nПопробуй «Другая камера».");
                return;
            }

            _capture = capture;
            _frameReader = reader;
        }
        finally
        {
            if (!_closed)
            {
                SwitchButton.IsEnabled = _devices.Count > 1;
            }
        }
    }

    /// <summary>
    /// Поднять MediaCapture на устройстве. null — не поднялась, причина уже
    /// написана в окне словами.
    /// </summary>
    private async Task<MediaCapture?> InitializeCaptureAsync(DeviceInformation device)
    {
        var capture = new MediaCapture();
        try
        {
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                VideoDeviceId = device.Id,
                StreamingCaptureMode = StreamingCaptureMode.Video,
                // Кадры нужны в обычной памяти: при предпочтении GPU у кадра
                // SoftwareBitmap приходит пустым, а картинка лежит в
                // Direct3D-поверхности, читать которую здесь нечем.
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                SharingMode = MediaCaptureSharingMode.ExclusiveControl,
            });
            return capture;
        }
        catch (UnauthorizedAccessException)
        {
            // Отдельная ветка ради текста: доступ к камере закрывают и
            // настройками приватности, и групповой политикой, и без объяснения
            // человек видит просто чёрный прямоугольник.
            capture.Dispose();
            ShowMessage(
                "Доступ к камере запрещён.\n" +
                "Разреши его в «Параметры → Конфиденциальность и защита → Камера»\n" +
                "или вставь ссылку подписки текстом.");
            return null;
        }
        catch (Exception ex)
        {
            capture.Dispose();
            ShowMessage($"Камера «{device.Name}» недоступна.\n{ex.Message}\nПопробуй «Другая камера».");
            return null;
        }
    }

    /// <summary>
    /// Источник цветных кадров. Предпочтение — потоку предпросмотра: он
    /// легче потока записи и не поднимает камеру на максимальное разрешение.
    /// </summary>
    private static MediaFrameSource? PickColorSource(MediaCapture capture)
    {
        MediaFrameSource? preview = null;
        MediaFrameSource? record = null;
        MediaFrameSource? other = null;

        foreach (var source in capture.FrameSources.Values)
        {
            if (source.Info.SourceKind != MediaFrameSourceKind.Color)
            {
                continue;
            }

            if (source.Info.MediaStreamType == MediaStreamType.VideoPreview)
            {
                preview ??= source;
            }
            else if (source.Info.MediaStreamType == MediaStreamType.VideoRecord)
            {
                record ??= source;
            }
            else
            {
                other ??= source;
            }
        }

        return preview ?? record ?? other;
    }

    /// <summary>
    /// Выбрать формат, ближайший по ширине к PreferredFrameWidth. Формат
    /// ставится до создания читателя: после старта камера его уже не меняет.
    /// Не получилось — работаем на том, что камера предложила сама.
    /// </summary>
    private static async Task TrySetFormatAsync(MediaFrameSource source)
    {
        MediaFrameFormat? best = null;
        var bestDistance = int.MaxValue;

        foreach (var format in source.SupportedFormats)
        {
            if (format.VideoFormat is null)
            {
                continue;
            }

            var distance = Math.Abs((int)format.VideoFormat.Width - PreferredFrameWidth);
            if (distance < bestDistance)
            {
                best = format;
                bestDistance = distance;
            }
        }

        if (best is null)
        {
            return;
        }

        try
        {
            await source.SetFormatAsync(best);
        }
        catch (Exception)
        {
            // Часть камер отвергает смену формата; это не повод не сканировать.
        }
    }

    // ------------------------------------------------------------------
    // Кадры
    // ------------------------------------------------------------------

    private void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        // Обработчик вызывается из фонового потока. Если предыдущий кадр ещё
        // в работе — этот пропускаем: догонять очередь бессмысленно, камера
        // всё равно отдаёт самый свежий кадр.
        if (Interlocked.Exchange(ref _busy, 1) == 1)
        {
            return;
        }

        try
        {
            using var frame = sender.TryAcquireLatestFrame();
            var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (bitmap is null)
            {
                return;
            }

            SoftwareBitmap? converted = null;
            try
            {
                if (bitmap.BitmapPixelFormat != BitmapPixelFormat.Bgra8)
                {
                    converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
                    bitmap = converted;
                }

                ProcessFrame(bitmap);
            }
            finally
            {
                converted?.Dispose();
            }
        }
        catch (Exception)
        {
            // Камеру могли выдернуть из порта прямо между кадрами. Ронять из-за
            // этого окно нельзя: пользователь просто нажмёт «Другая камера».
        }
        finally
        {
            Interlocked.Exchange(ref _busy, 0);
        }
    }

    private void ProcessFrame(SoftwareBitmap bitmap)
    {
        var width = bitmap.PixelWidth;
        var height = bitmap.PixelHeight;
        var size = width * height * 4;

        // Слот меняется только при отправке кадра в интерфейс, поэтому тот,
        // который сейчас рисуется, здесь не трогается.
        var pixels = _frames[_frameSlot];
        if (pixels is null || pixels.Length != size)
        {
            pixels = new byte[size];
            _frames[_frameSlot] = pixels;
        }

        if (_copyBuffer is null || _copyBuffer.Capacity < size)
        {
            _copyBuffer = new Windows.Storage.Streams.Buffer((uint)size);
        }

        // Через IBuffer и DataReader, а не через AsBuffer(): расширения
        // System.Runtime.WindowsRuntime из .NET убраны, а читать память кадра
        // напрямую (IMemoryBufferByteAccess) можно только в unsafe-коде,
        // которого в проекте нет.
        bitmap.CopyToBuffer(_copyBuffer);
        using (var readerStream = Windows.Storage.Streams.DataReader.FromBuffer(_copyBuffer))
        {
            readerStream.ReadBytes(pixels);
        }

        if (_gray is null || _gray.Length != width * height)
        {
            _gray = new byte[width * height];
        }

        // BGRA → яркость по Rec.601. ZXing ждёт готовую яркостную плоскость,
        // и считать её здесь дешевле, чем внутри RGBLuminanceSource: тот же
        // проход всё равно нужен, а лишней копии кадра не возникает.
        var gray = _gray;
        for (int i = 0, p = 0; i < gray.Length; i++, p += 4)
        {
            gray[i] = (byte)((pixels[p + 2] * 299 + pixels[p + 1] * 587 + pixels[p] * 114) / 1000);
        }

        string? found = null;
        if (++_frameCount % DecodeEveryNthFrame == 0)
        {
            var result = _decoder.Decode(
                new RGBLuminanceSource(gray, width, height, RGBLuminanceSource.BitmapFormat.Gray8));
            found = result?.Text;
        }

        if (found is null && Interlocked.CompareExchange(ref _uiPending, 1, 0) != 0)
        {
            // Интерфейс ещё не дорисовал предыдущий кадр — этот не показываем.
            return;
        }

        if (found is not null)
        {
            _uiPending = 1;
        }

        _frameSlot ^= 1;
        Dispatcher.InvokeAsync(() => ShowFrame(pixels, width, height, found));
    }

    private void ShowFrame(byte[] pixels, int width, int height, string? found)
    {
        try
        {
            // Кадр отправлен в очередь интерфейса, а камеру за это время могли
            // отпустить — нажали «Другая камера» или окно закрылось. Запоздавший
            // кадр показывать нельзя: он затёр бы собой уже написанную причину
            // («камера недоступна», «доступ запрещён») застывшей картинкой.
            if (_closed || _frameReader is null)
            {
                return;
            }

            if (_screen is null || _screen.PixelWidth != width || _screen.PixelHeight != height)
            {
                // Bgr32, а не Bgra32: альфа у кадра камеры смысла не несёт, а
                // премультиплицированный формат заставил бы её ещё и учитывать.
                _screen = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgr32, null);
                VideoImage.Source = _screen;
            }

            _screen.WritePixels(new Int32Rect(0, 0, width, height), pixels, width * 4, 0);
            VideoImage.Visibility = Visibility.Visible;
            VideoMessage.Visibility = Visibility.Collapsed;

            if (found is not null)
            {
                Accept(found);
            }
        }
        finally
        {
            Interlocked.Exchange(ref _uiPending, 0);
        }
    }

    private void Accept(string text)
    {
        Text = text.Trim();
        Hint.Text = "Код распознан";
        ReleaseCamera();
        DialogResult = true;
    }

    // ------------------------------------------------------------------
    // Освобождение камеры
    // ------------------------------------------------------------------

    private void ShowMessage(string text)
    {
        VideoMessage.Text = text;
        VideoMessage.Visibility = Visibility.Visible;
        VideoImage.Visibility = Visibility.Collapsed;
        VideoImage.Source = null;
        _screen = null;
    }

    private void ReleaseCamera()
    {
        var reader = _frameReader;
        var capture = _capture;
        _frameReader = null;
        _capture = null;
        DisposeCamera(capture, reader);
    }

    private void DisposeCamera(MediaCapture? capture, MediaFrameReader? reader)
    {
        if (reader is not null)
        {
            reader.FrameArrived -= OnFrameArrived;
            try
            {
                // StopAsync не ждём: ожидание на потоке интерфейса остановило
                // бы перекачку сообщений, а Dispose и сам останавливает чтение
                // и отпускает устройство. Ровно поэтому кадр уходит в
                // интерфейс через InvokeAsync, а не Invoke: ждущий обработчик
                // кадра и ждущий его Dispose встали бы намертво друг против друга.
                reader.Dispose();
            }
            catch (Exception)
            {
            }
        }

        try
        {
            capture?.Dispose();
        }
        catch (Exception)
        {
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        // Камеру освобождаем при любом исходе — закрыли крестиком, отменили,
        // распознали, — иначе она осталась бы занятой для других программ до
        // выхода из приложения.
        _closed = true;
        _generation++;
        ReleaseCamera();
        base.OnClosed(e);
    }
}
