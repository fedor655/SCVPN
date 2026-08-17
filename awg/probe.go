package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
)

// measure — задержка до сервера, честно измеренная сквозь туннель.
//
// Не TCP-коннект к Endpoint'у: WireGuard живёт на UDP, и коннектиться там не к
// чему. Не время рукопожатия: оно ничего не говорит о том, ходит ли трафик
// дальше сервера. Меряем то же, что остальные платформы меряют для Xray, —
// настоящий запрос через сам туннель.
//
// Подъём туннеля в счёт не идёт: он плата за честность, к задержке до сервера
// отношения не имеет. Поэтому таймер стартует прямо перед запросом.
func measure(tnet *netstack.Net, url string) (int, error) {
	client := &http.Client{
		Timeout: 8 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				// Жёстко IPv4. У большинства адресов есть и AAAA, а туннель
				// почти всегда выпускает наружу только IPv4 — попытка по IPv6
				// упирается в таймаут и добавляет к замеру секунды, которых у
				// сервера нет. Замер должен мерить сервер, а не эту вилку.
				return tnet.DialContext(ctx, "tcp4", addr)
			},
			// Соединение одноразовое: переиспользовать нечего, а закрыть его
			// надо до выхода, иначе процесс подождёт таймаута простоя.
			DisableKeepAlives: true,
		},
	}

	// Прогрев. Первый запрос платит за то, что к задержке отношения не имеет:
	// рукопожатие WireGuard (оно идёт по первому же пакету, а не по dev.Up) и
	// резолв имени внутри туннеля. Без него замер показывал шесть секунд там,
	// где сервер отвечает за сотню миллисекунд.
	if resp, err := client.Get(url); err == nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	} else {
		// Молчать нельзя: если не прошёл и прогрев, дальше мерить нечего.
		return 0, err
	}

	started := time.Now()
	resp, err := client.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	// Тело дочитываем: без этого измеренное время — время до заголовков, а не
	// до ответа. У 204-х оно всё равно пустое.
	io.Copy(io.Discard, resp.Body)
	elapsed := int(time.Since(started).Milliseconds())

	if resp.StatusCode >= 400 {
		return 0, fmt.Errorf("сервер ответил %s", resp.Status)
	}
	return elapsed, nil
}
