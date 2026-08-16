using System;
using System.Text;

namespace SCVPN.Core;

/// <summary>
/// Устойчивый base64: паддинга может не быть, алфавит может быть url-safe.
///
/// Голый <see cref="Convert.FromBase64String"/> тут не годится — он требует и
/// правильной длины, и стандартного алфавита, а панели шлют и то, и другое как
/// придётся. Терять из-за этого всю подписку нельзя.
///
/// Но чинится только то, что перечислено: алфавит и паддинг. Всё остальное —
/// отказ. Python на этом месте звал base64.b64decode, который молча выбрасывает
/// символы вне алфавита, и потому «расшифровывал» открытую пару
/// method:password из ss://-ссылки в двоичный мусор вместо честного отказа.
/// </summary>
public static class Base64Url
{
    /// <summary>Декодирует или возвращает null, если это не base64.</summary>
    public static byte[]? TryDecode(string s)
    {
        var t = s.Trim()
            // Переносы строк режем везде, а не только по краям: длинную строку
            // подписки панели любят слать разбитой на строки.
            .Replace("\n", string.Empty)
            .Replace("\r", string.Empty)
            .Replace('-', '+')
            .Replace('_', '/');

        // Паддинг считается уже после чистки: иначе '\n' попадёт в длину и
        // добьётся до кратности четырём неверным числом '='.
        var pad = (4 - t.Length % 4) % 4;
        if (pad > 0)
            t += new string('=', pad);

        try
        {
            return Convert.FromBase64String(t);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>
    /// То же, но текстом. Битые байты заменяются на U+FFFD, а не роняют разбор:
    /// одна кривая строка не должна стоить пользователю всей подписки.
    /// </summary>
    public static string? TryDecodeText(string s)
    {
        var bytes = TryDecode(s);
        return bytes is null ? null : Encoding.UTF8.GetString(bytes);
    }
}
