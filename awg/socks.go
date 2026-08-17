package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"log"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
)

// Минимальный SOCKS5: CONNECT и UDP ASSOCIATE, без аутентификации.
//
// Своя реализация, а не библиотека: слушаем только 127.0.0.1, протокол
// умещается в двести строк, а лишняя зависимость в процессе, который держит
// приватный ключ туннеля, стоит дороже.
//
// UDP обязателен, а не «на будущее»: без него отваливаются QUIC (это треть
// веба) и всё, что ходит датаграммами. Xray в socks-outbound шлёт UDP именно
// через ASSOCIATE.

const (
	socksVersion = 5

	cmdConnect      = 1
	cmdUDPAssociate = 3

	atypIPv4   = 1
	atypDomain = 3
	atypIPv6   = 4

	replyOK              = 0
	replyGeneralFailure  = 1
	replyCmdNotSupported = 7

	// Сколько держать исходящий UDP-сокет без трафика. DNS-ответ приходит за
	// миллисекунды, но QUIC-сессия живёт минутами и молчать может долго.
	udpIdleTimeout = 2 * time.Minute
	udpBufferSize  = 64 * 1024
)

func serveSOCKS(ln net.Listener, tnet *netstack.Net) {
	for {
		c, err := ln.Accept()
		if err != nil {
			// Listener закрыт сигналом — это не ошибка, а штатный выход.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("[awg] accept: %v", err)
			return
		}
		go func() {
			defer c.Close()
			if err := handle(c, tnet); err != nil && !errors.Is(err, io.EOF) {
				log.Printf("[awg] %v", err)
			}
		}()
	}
}

func handle(c net.Conn, tnet *netstack.Net) error {
	br := bufio.NewReader(c)

	// Приветствие: версия, число методов, сами методы.
	head := make([]byte, 2)
	if _, err := io.ReadFull(br, head); err != nil {
		return err
	}
	if head[0] != socksVersion {
		return errors.New("не SOCKS5")
	}
	if _, err := io.ReadFull(br, make([]byte, head[1])); err != nil {
		return err
	}
	if _, err := c.Write([]byte{socksVersion, 0}); err != nil { // 0 — без аутентификации
		return err
	}

	// Запрос: версия, команда, резерв, тип адреса, адрес, порт.
	req := make([]byte, 4)
	if _, err := io.ReadFull(br, req); err != nil {
		return err
	}
	host, port, err := readAddress(br, req[3])
	if err != nil {
		return err
	}

	switch req[1] {
	case cmdConnect:
		return doConnect(c, br, tnet, host, port)
	case cmdUDPAssociate:
		return doUDPAssociate(c, br, tnet)
	default:
		writeReply(c, replyCmdNotSupported, net.IPv4zero, 0)
		return nil
	}
}

func doConnect(c net.Conn, br *bufio.Reader, tnet *netstack.Net, host string, port int) error {
	target := net.JoinHostPort(host, strconv.Itoa(port))
	up, err := tnet.Dial("tcp", target)
	if err != nil {
		writeReply(c, replyGeneralFailure, net.IPv4zero, 0)
		return nil // адрес мог просто не ответить — это не наша ошибка
	}
	defer up.Close()

	if err := writeReply(c, replyOK, net.IPv4zero, 0); err != nil {
		return err
	}

	// br, а не c: в буфере уже может лежать первый пакет клиента.
	done := make(chan struct{})
	go func() {
		io.Copy(up, br)
		if cw, ok := up.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			up.Close()
		}
		close(done)
	}()
	io.Copy(c, up)
	<-done
	return nil
}

// doUDPAssociate поднимает локальный UDP-порт и гоняет через него датаграммы,
// пока жива управляющая TCP-сессия. Так и требует RFC 1928: обрыв TCP — конец
// ассоциации, иначе порт остался бы висеть после ухода клиента.
func doUDPAssociate(c net.Conn, br *bufio.Reader, tnet *netstack.Net) error {
	// Адрес из запроса игнорируем: клиент часто шлёт 0.0.0.0:0, потому что сам
	// ещё не знает, с какого порта пойдёт. Принимаем с любого — слушаем только
	// на localhost, чужой туда не достучится.
	pc, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		writeReply(c, replyGeneralFailure, net.IPv4zero, 0)
		return err
	}
	defer pc.Close()

	bound := pc.LocalAddr().(*net.UDPAddr)
	if err := writeReply(c, replyOK, bound.IP, bound.Port); err != nil {
		return err
	}

	relay := &udpRelay{local: pc, tnet: tnet, upstream: map[string]*udpLink{}}
	go relay.run()

	// Ждём конца управляющего соединения. Данных по нему быть не должно;
	// любое чтение вернётся ошибкой или EOF ровно тогда, когда клиент ушёл.
	io.Copy(io.Discard, br)
	relay.close()
	return nil
}

type udpLink struct {
	conn   net.Conn
	client *net.UDPAddr
	header []byte // готовый SOCKS-заголовок ответа для этого адресата
}

type udpRelay struct {
	local    *net.UDPConn
	tnet     *netstack.Net
	mu       sync.Mutex
	upstream map[string]*udpLink
	closed   bool
}

func (r *udpRelay) run() {
	buf := make([]byte, udpBufferSize)
	for {
		n, client, err := r.local.ReadFromUDP(buf)
		if err != nil {
			return
		}
		host, port, payload, err := parseUDPDatagram(buf[:n])
		if err != nil {
			continue // битую датаграмму молча роняем, как и положено UDP
		}
		target := net.JoinHostPort(host, strconv.Itoa(port))

		link, err := r.link(client, target)
		if err != nil {
			continue
		}
		link.conn.SetWriteDeadline(time.Now().Add(udpIdleTimeout))
		link.conn.Write(payload)
	}
}

// link находит или заводит исходящий сокет под пару «клиент — адресат».
//
// Ключ включает адрес клиента: одна ассоциация обслуживает несколько сокетов
// приложения, и ответы обязаны вернуться тому, кто спрашивал.
func (r *udpRelay) link(client *net.UDPAddr, target string) (*udpLink, error) {
	key := client.String() + "|" + target

	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil, net.ErrClosed
	}
	if link, ok := r.upstream[key]; ok {
		return link, nil
	}

	conn, err := r.tnet.Dial("udp", target)
	if err != nil {
		return nil, err
	}
	header, err := udpReplyHeader(target)
	if err != nil {
		conn.Close()
		return nil, err
	}
	link := &udpLink{conn: conn, client: client, header: header}
	r.upstream[key] = link
	go r.pump(key, link)
	return link, nil
}

func (r *udpRelay) pump(key string, link *udpLink) {
	defer func() {
		link.conn.Close()
		r.mu.Lock()
		delete(r.upstream, key)
		r.mu.Unlock()
	}()

	buf := make([]byte, udpBufferSize)
	for {
		link.conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
		n, err := link.conn.Read(buf)
		if err != nil {
			return
		}
		out := append(append([]byte{}, link.header...), buf[:n]...)
		if _, err := r.local.WriteToUDP(out, link.client); err != nil {
			return
		}
	}
}

func (r *udpRelay) close() {
	r.mu.Lock()
	r.closed = true
	for _, link := range r.upstream {
		link.conn.Close()
	}
	r.mu.Unlock()
	r.local.Close()
}

// --- разбор адресов ---

func readAddress(br *bufio.Reader, atyp byte) (string, int, error) {
	var host string
	switch atyp {
	case atypIPv4:
		b := make([]byte, 4)
		if _, err := io.ReadFull(br, b); err != nil {
			return "", 0, err
		}
		host = net.IP(b).String()
	case atypIPv6:
		b := make([]byte, 16)
		if _, err := io.ReadFull(br, b); err != nil {
			return "", 0, err
		}
		host = net.IP(b).String()
	case atypDomain:
		l := make([]byte, 1)
		if _, err := io.ReadFull(br, l); err != nil {
			return "", 0, err
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(br, b); err != nil {
			return "", 0, err
		}
		host = string(b)
	default:
		return "", 0, errors.New("неизвестный тип адреса SOCKS")
	}

	p := make([]byte, 2)
	if _, err := io.ReadFull(br, p); err != nil {
		return "", 0, err
	}
	return host, int(binary.BigEndian.Uint16(p)), nil
}

// parseUDPDatagram разбирает «RSV RSV FRAG ATYP ADDR PORT DATA».
func parseUDPDatagram(b []byte) (string, int, []byte, error) {
	if len(b) < 5 {
		return "", 0, nil, errors.New("датаграмма короче заголовка")
	}
	// Сборку фрагментов не делаем: её не использует ни один живой клиент, а
	// частичная реализация опаснее честного отказа.
	if b[2] != 0 {
		return "", 0, nil, errors.New("фрагментация не поддержана")
	}

	var host string
	rest := b[4:]
	switch b[3] {
	case atypIPv4:
		if len(rest) < 4 {
			return "", 0, nil, errors.New("обрезанный IPv4")
		}
		host, rest = net.IP(rest[:4]).String(), rest[4:]
	case atypIPv6:
		if len(rest) < 16 {
			return "", 0, nil, errors.New("обрезанный IPv6")
		}
		host, rest = net.IP(rest[:16]).String(), rest[16:]
	case atypDomain:
		if len(rest) < 1 || len(rest) < 1+int(rest[0]) {
			return "", 0, nil, errors.New("обрезанное имя")
		}
		n := int(rest[0])
		host, rest = string(rest[1:1+n]), rest[1+n:]
	default:
		return "", 0, nil, errors.New("неизвестный тип адреса")
	}
	if len(rest) < 2 {
		return "", 0, nil, errors.New("нет порта")
	}
	return host, int(binary.BigEndian.Uint16(rest[:2])), rest[2:], nil
}

// udpReplyHeader готовит заголовок ответных датаграмм один раз на адресата.
func udpReplyHeader(target string) ([]byte, error) {
	host, portText, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return nil, err
	}

	out := []byte{0, 0, 0}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			out = append(out, atypIPv4)
			out = append(out, v4...)
		} else {
			out = append(out, atypIPv6)
			out = append(out, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return nil, errors.New("имя длиннее 255 байт")
		}
		out = append(out, atypDomain, byte(len(host)))
		out = append(out, host...)
	}
	return binary.BigEndian.AppendUint16(out, uint16(port)), nil
}

func writeReply(c net.Conn, code byte, ip net.IP, port int) error {
	out := []byte{socksVersion, code, 0}
	if v4 := ip.To4(); v4 != nil {
		out = append(out, atypIPv4)
		out = append(out, v4...)
	} else {
		out = append(out, atypIPv6)
		out = append(out, ip.To16()...)
	}
	_, err := c.Write(binary.BigEndian.AppendUint16(out, uint16(port)))
	return err
}
