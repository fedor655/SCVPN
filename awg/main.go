// scvpn-awg — AmneziaWG в виде локального SOCKS5-прокси.
//
// Зачем прокси, а не TUN. Приложение уже умеет заводить системный трафик в
// локальный SOCKS: этим занимаются системный прокси, sing-box на десктопе и
// hev-socks5-tunnel на Android. Если AmneziaWG отдать тем же интерфейсом, то
// маршруты, DNS, killswitch и раздельное туннелирование писать заново не
// нужно — всё это уже есть и работает. Отсюда и выбор: TCP/IP-стек живёт
// внутри процесса (gvisor netstack из amneziawg-go), наружу торчит только
// 127.0.0.1.
//
// Ядро протокола — github.com/amnezia-vpn/amneziawg-go, официальная
// реализация Amnezia. Здесь только разбор .conf, UAPI-строка и SOCKS5.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
)

func main() {
	log.SetFlags(0)

	confPath := flag.String("config", "", "путь к .conf (формат wg-quick / AmneziaWG)")
	listen := flag.String("socks", "127.0.0.1:10810", "адрес SOCKS5")
	probe := flag.String("probe", "", "замерить задержку запросом по адресу и выйти")
	verbose := flag.Bool("verbose", false, "подробный лог протокола")
	flag.Parse()

	if *confPath == "" {
		fmt.Fprintln(os.Stderr, "нужен -config")
		flag.Usage()
		os.Exit(2)
	}

	raw, err := os.ReadFile(*confPath)
	if err != nil {
		log.Fatalf("[awg] конфиг не прочитан: %v", err)
	}
	cfg, err := parseConf(string(raw))
	if err != nil {
		log.Fatalf("[awg] конфиг: %v", err)
	}

	// Слушаем до того, как поднимать туннель: если порт занят, лучше упасть
	// сразу, чем после успешного рукопожатия с сервером. В режиме замера
	// слушать нечего — там только один запрос наружу.
	var ln net.Listener
	if *probe == "" {
		ln, err = net.Listen("tcp", *listen)
		if err != nil {
			log.Fatalf("[awg] не занять %s: %v", *listen, err)
		}
	}

	tun, tnet, err := netstack.CreateNetTUN(cfg.addresses, cfg.dns, cfg.mtu)
	if err != nil {
		log.Fatalf("[awg] стек: %v", err)
	}
	level := device.LogLevelError
	if *verbose {
		level = device.LogLevelVerbose
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(level, "[awg] "))
	if err := dev.IpcSet(cfg.ipc()); err != nil {
		log.Fatalf("[awg] параметры туннеля: %v", err)
	}
	if err := dev.Up(); err != nil {
		log.Fatalf("[awg] туннель не поднялся: %v", err)
	}

	if *probe != "" {
		ms, err := measure(tnet, *probe)
		dev.Close()
		if err != nil {
			log.Fatalf("[awg] замер: %v", err)
		}
		// Одно число в stdout и ничего больше — это парсят три платформы.
		fmt.Println(ms)
		return
	}

	// Строку ждёт супервизор на каждой платформе — это признак «готов
	// принимать соединения», а не украшение. Менять только вместе с ними.
	log.Printf("[awg] готов: SOCKS5 на %s, пир %s", ln.Addr(), cfg.endpoint)

	// Сигнал гасит туннель до выхода: иначе процесс умрёт с открытым сокетом
	// к серверу, и тот будет ещё минуту держать сессию.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		log.Println("[awg] остановка")
		ln.Close()
		dev.Close()
		os.Exit(0)
	}()

	serveSOCKS(ln, tnet)
	dev.Close()
}
