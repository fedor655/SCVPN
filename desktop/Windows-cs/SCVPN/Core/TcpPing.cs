using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace SCVPN.Core;

public static class TcpPing
{
    /// <summary>
    /// Задержка до сервера в миллисекундах, или null, если порт недоступен.
    /// </summary>
    /// <remarks>
    /// Это не ICMP-пинг, а время установки TCP-соединения (как happ-tcping):
    /// для VPN оно полезнее, потому что меряет доступность именно нужного
    /// порта, а не абстрактную достижимость хоста.
    ///
    /// Таймаут наш, а не системный: без него «сервер не отвечает» приходило бы
    /// через минуту вместо трёх секунд — столько Windows перебирает попытки
    /// SYN сама. Отсчёт таймаута — на каждый адрес отдельно, как в Python
    /// (settimeout на сокет) и в Swift.
    ///
    /// Отмена через <paramref name="ct"/> тоже даёт null: результата всё равно
    /// нет, а списку серверов, который отменяют при каждом переключении,
    /// незачем ловить исключение на каждой строке.
    /// </remarks>
    public static async Task<int?> MeasureAsync(
        string host, int port, TimeSpan timeout, CancellationToken ct = default)
    {
        IPAddress[] addresses;
        try
        {
            // Резолвим имя; если host — уже адрес, здесь просто разбор строки.
            addresses = await Dns.GetHostAddressesAsync(host, ct).ConfigureAwait(false);
        }
        catch (SocketException)
        {
            return null;
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }

        foreach (IPAddress address in addresses)
        {
            if (ct.IsCancellationRequested) return null;

            using var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
            using var attempt = CancellationTokenSource.CreateLinkedTokenSource(ct);
            attempt.CancelAfter(timeout);

            var started = Stopwatch.StartNew();
            try
            {
                await socket.ConnectAsync(new IPEndPoint(address, port), attempt.Token).ConfigureAwait(false);
                return (int)started.ElapsedMilliseconds;
            }
            catch (OperationCanceledException)
            {
                // Отменили снаружи — уходим; истёк наш таймаут — пробуем
                // следующий адрес (у хоста бывает и IPv6, и IPv4).
                if (ct.IsCancellationRequested) return null;
            }
            catch (SocketException)
            {
            }
        }
        return null;
    }
}
