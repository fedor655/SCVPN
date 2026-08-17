package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// Параметры обфускации AmneziaWG в том виде, в каком их принимает UAPI ядра.
//
// Список открытый намеренно: Amnezia добавляет параметры от версии к версии
// (jc..h4 были в 1.5, i1..i5 приехали во 2.0, дальше — больше). Разбирать их
// поимённо значило бы обновлять четыре платформы на каждый новый ключ, поэтому
// имена берутся из .conf как есть и уезжают в UAPI как есть — ядро само
// скажет, если ключ ему незнаком.
//
// Порядок фиксирован, чтобы UAPI-строка была одинаковой при одном и том же
// конфиге: так её можно сравнивать в тестах.
var awgParams = []string{
	"jc", "jmin", "jmax",
	"s1", "s2", "s3", "s4",
	"h1", "h2", "h3", "h4",
	"i1", "i2", "i3", "i4", "i5",
}

type wgConfig struct {
	privateKey   string // hex, как требует UAPI
	addresses    []netip.Addr
	dns          []netip.Addr
	mtu          int
	publicKey    string // hex
	presharedKey string // hex
	endpoint     string
	allowedIPs   []string
	keepalive    string
	awg          map[string]string
}

// keyToHex переводит ключ из base64 (.conf) в hex (UAPI).
//
// Длину проверяем: UAPI молча принял бы обрезанный ключ, а туннель потом
// просто не поднялся бы без внятной причины.
func keyToHex(field, value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil {
		return "", fmt.Errorf("%s: не base64: %w", field, err)
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("%s: длина %d байт вместо 32", field, len(raw))
	}
	return hex.EncodeToString(raw), nil
}

// parseConf разбирает .conf формата wg-quick, включая расширения AmneziaWG.
//
// INI разбирается вручную, а не библиотекой: файл простой, а зависимость в
// бинарнике, который держит приватный ключ, стоит дороже двадцати строк.
func parseConf(text string) (*wgConfig, error) {
	c := &wgConfig{mtu: 1420, awg: map[string]string{}}
	section := ""

	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		rawKey, rawValue, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(rawKey))
		value := strings.TrimSpace(rawValue)
		if value == "" {
			continue
		}

		var err error
		switch section {
		case "interface":
			err = c.setInterface(key, value)
		case "peer":
			err = c.setPeer(key, value)
		}
		if err != nil {
			return nil, err
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	if c.privateKey == "" {
		return nil, fmt.Errorf("нет PrivateKey")
	}
	if c.publicKey == "" {
		return nil, fmt.Errorf("нет PublicKey у пира")
	}
	if c.endpoint == "" {
		return nil, fmt.Errorf("нет Endpoint у пира")
	}
	if len(c.addresses) == 0 {
		return nil, fmt.Errorf("нет Address интерфейса")
	}
	// Пустой AllowedIPs у wg-quick значит «ничего не маршрутизировать», но в
	// клиентском конфиге это всегда опечатка: туннель поднимется и не пропустит
	// ни байта. Берём полный, как это делает Xray.
	if len(c.allowedIPs) == 0 {
		c.allowedIPs = []string{"0.0.0.0/0", "::/0"}
	}
	// Имена резолвит стек внутри туннеля — Xray передаёт нам домен, а не адрес.
	// Без единого сервера LookupHost не сможет ничего, и наружу не уйдёт ни
	// одного запроса по имени. Ставим тот же адрес, что стоит умолчанием у
	// самого приложения.
	if len(c.dns) == 0 {
		c.dns = append(c.dns, netip.MustParseAddr("1.1.1.1"))
	}
	return c, nil
}

func (c *wgConfig) setInterface(key, value string) error {
	switch key {
	case "privatekey":
		hexKey, err := keyToHex("PrivateKey", value)
		if err != nil {
			return err
		}
		c.privateKey = hexKey
	case "address":
		for _, part := range splitList(value) {
			// Маска здесь не нужна: адрес живёт в юзерспейс-стеке, где
			// «подсеть интерфейса» ни на что не влияет, а маршрутизацию
			// задаёт AllowedIPs.
			if prefix, err := netip.ParsePrefix(part); err == nil {
				c.addresses = append(c.addresses, prefix.Addr())
				continue
			}
			addr, err := netip.ParseAddr(part)
			if err != nil {
				return fmt.Errorf("Address %q: %w", part, err)
			}
			c.addresses = append(c.addresses, addr)
		}
	case "dns":
		for _, part := range splitList(value) {
			// DNS-именами (а не адресами) wg-quick тоже не брезгует; такие
			// молча пропускаем — стек всё равно принимает только адреса.
			if addr, err := netip.ParseAddr(part); err == nil {
				c.dns = append(c.dns, addr)
			}
		}
	case "mtu":
		mtu, err := strconv.Atoi(value)
		if err != nil || mtu < 576 || mtu > 65535 {
			return fmt.Errorf("MTU %q вне диапазона 576..65535", value)
		}
		c.mtu = mtu
	default:
		if isAWGParam(key) {
			c.awg[key] = value
		}
		// Остальное (ListenPort, Table, PreUp/PostUp…) к юзерспейс-стеку
		// отношения не имеет — тихо игнорируем, файл от этого не «кривой».
	}
	return nil
}

func (c *wgConfig) setPeer(key, value string) error {
	switch key {
	case "publickey":
		hexKey, err := keyToHex("PublicKey", value)
		if err != nil {
			return err
		}
		c.publicKey = hexKey
	case "presharedkey":
		hexKey, err := keyToHex("PresharedKey", value)
		if err != nil {
			return err
		}
		c.presharedKey = hexKey
	case "endpoint":
		c.endpoint = value
	case "allowedips":
		c.allowedIPs = append(c.allowedIPs, splitList(value)...)
	case "persistentkeepalive":
		if value == "off" {
			return nil
		}
		if _, err := strconv.Atoi(value); err != nil {
			return fmt.Errorf("PersistentKeepalive %q — не число", value)
		}
		c.keepalive = value
	}
	return nil
}

func isAWGParam(key string) bool {
	for _, p := range awgParams {
		if p == key {
			return true
		}
	}
	return false
}

func splitList(value string) []string {
	var out []string
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

// ipc собирает UAPI-строку для amneziawg-go.
//
// Параметры обфускации относятся к устройству, а не к пиру, поэтому идут до
// первого public_key: всё, что после него, ядро считает свойствами пира.
func (c *wgConfig) ipc() string {
	var b strings.Builder
	b.WriteString("private_key=" + c.privateKey + "\n")
	for _, name := range awgParams {
		if value, ok := c.awg[name]; ok {
			b.WriteString(name + "=" + value + "\n")
		}
	}
	b.WriteString("public_key=" + c.publicKey + "\n")
	if c.presharedKey != "" {
		b.WriteString("preshared_key=" + c.presharedKey + "\n")
	}
	b.WriteString("endpoint=" + c.endpoint + "\n")
	for _, ip := range c.allowedIPs {
		b.WriteString("allowed_ip=" + ip + "\n")
	}
	if c.keepalive != "" {
		b.WriteString("persistent_keepalive_interval=" + c.keepalive + "\n")
	}
	return b.String()
}
