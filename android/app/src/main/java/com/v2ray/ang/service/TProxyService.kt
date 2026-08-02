package com.v2ray.ang.service

/**
 * JNI-обёртка над hev-socks5-tunnel (libhev-socks5-tunnel.so, лицензия MIT).
 *
 * ВАЖНО: имя пакета/класса (com.v2ray.ang.service.TProxyService) обязано совпадать
 * с тем, под которое .so был собран (RegisterNatives использует именно этот путь —
 * проверено по строкам внутри .so). Поэтому этот один класс лежит в чужом пакете,
 * остальное приложение — в com.scvpn.
 *
 * Источник .so: проект v2rayNG (сам hev-socks5-tunnel от heiher, MIT).
 */
object TProxyService {
    @JvmStatic
    @Suppress("FunctionName")
    external fun TProxyStartService(configPath: String, fd: Int)

    @JvmStatic
    @Suppress("FunctionName")
    external fun TProxyStopService()

    @JvmStatic
    @Suppress("FunctionName")
    external fun TProxyGetStats(): LongArray?

    init {
        System.loadLibrary("hev-socks5-tunnel")
    }
}
