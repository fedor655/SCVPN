using System.Net;
using System.Net.Sockets;

namespace SCVPN.Core;

public static class FreePort
{
    /// <summary>
    /// Найти свободный TCP-порт на 127.0.0.1, начиная с <paramref name="preferred"/>.
    /// </summary>
    /// <remarks>
    /// Нужно, чтобы не конфликтовать с другими VPN-клиентами: Happ держит
    /// 10808/10809, и без этого поиска ядро молча не поднялось бы.
    /// Если заняты все сто — берём любой эфемерный, лишь бы работало.
    /// </remarks>
    public static int Find(int preferred)
    {
        // Номер порта приходит из settings.json, а его пользователь правит
        // руками. Ноль здесь особенно коварен: bind(0) удаётся всегда, и без
        // этой проверки Find вернул бы 0 — ядро подняло бы вход на случайном
        // порту, а приложение ходило бы на нулевой. Отрицательное и «70000»
        // уронили бы подключение ArgumentOutOfRangeException из IPEndPoint.
        if (preferred >= 1 && preferred <= 65535)
        {
            // Верхняя граница диапазона портов — дальше пробовать нечего.
            for (int port = preferred; port < preferred + 100 && port <= 65535; port++)
            {
                if (CanBind(port)) return port;
            }
        }
        return BindEphemeral() ?? preferred;
    }

    private static bool CanBind(int port)
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            // Без этого флага Windows разрешает встать на порт, который кто-то
            // уже занял с SO_REUSEADDR: проверка сказала бы «свободен», а ядро
            // потом не поднялось бы. Ставится только до Bind.
            s.ExclusiveAddressUse = true;
            s.Bind(new IPEndPoint(IPAddress.Loopback, port));
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    private static int? BindEphemeral()
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            s.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            return (s.LocalEndPoint as IPEndPoint)?.Port;
        }
        catch (SocketException)
        {
            return null;
        }
    }
}
