package main

import "testing"

// Форма живого конфига: обычный wg-quick плюс обфускация AmneziaWG.
// Ключи сгенерированы для теста и никуда не ведут — настоящие в репозитории
// делать нечего, приватный ключ туннеля это пароль от всего трафика.
const (
	privateB64 = "38GCTbJEvBrai7BT7K8SzCJbD92q35iwl98JRQb/gqI="
	privateHex = "dfc1824db244bc1ada8bb053ecaf12cc225b0fddaadf98b097df094506ff82a2"
	publicB64  = "DdoK6OyIth4BjEvyRBnH7eUpjOniDyUMiodwzE5CEl8="
	publicHex  = "0dda0ae8ec88b61e018c4bf24419c7ede5298ce9e20f250c8a8770cc4e42125f"
	pskB64     = "zxrL/zVlGsR8kjYEg5uS7Krt9XmrgNjliUk6NDvaTEE="
	pskHex     = "cf1acbff35651ac47c923604839b92ecaaedf579ab80d8e589493a343bda4c41"
)

const sample = `[Interface]
PrivateKey = ` + privateB64 + `
Address = 10.66.66.4/32,fd42:42:42::4/128
DNS = 1.1.1.1,1.0.0.1
Jc = 10
Jmin = 47
Jmax = 129
S1 = 46
S2 = 30
S3 = 19
S4 = 18
H1 = 1035708199
H2 = 256240833
H3 = 1997207975
H4 = 556935419

[Peer]
PublicKey = ` + publicB64 + `
PresharedKey = ` + pskB64 + `
Endpoint = 198.51.100.7:51820
AllowedIPs = 0.0.0.0/0,::/0
PersistentKeepalive = 25
`

func TestIpcCarriesObfuscationBeforeThePeer(t *testing.T) {
	c, err := parseConf(sample)
	if err != nil {
		t.Fatalf("разбор: %v", err)
	}

	want := "private_key=" + privateHex + "\n" +
		"jc=10\njmin=47\njmax=129\n" +
		"s1=46\ns2=30\ns3=19\ns4=18\n" +
		"h1=1035708199\nh2=256240833\nh3=1997207975\nh4=556935419\n" +
		"public_key=" + publicHex + "\n" +
		"preshared_key=" + pskHex + "\n" +
		"endpoint=198.51.100.7:51820\n" +
		"allowed_ip=0.0.0.0/0\nallowed_ip=::/0\n" +
		"persistent_keepalive_interval=25\n"

	// Порядок значим: всё до первого public_key ядро считает настройками
	// устройства, всё после — свойствами пира. Обфускация относится к
	// устройству, поэтому сверяется вся строка целиком, а не по кускам.
	if got := c.ipc(); got != want {
		t.Errorf("UAPI-строка разошлась.\nполучено:\n%s\nожидалось:\n%s", got, want)
	}
}

func TestKeysAreCheckedForLength(t *testing.T) {
	// Обрезанный ключ UAPI принял бы молча, а туннель потом не поднялся бы
	// без внятной причины.
	_, err := parseConf("[Interface]\nPrivateKey = YWJj\n[Peer]\nPublicKey = " +
		publicB64 + "\nEndpoint = 1.2.3.4:1\n")
	if err == nil {
		t.Fatal("короткий PrivateKey прошёл проверку")
	}
}

func TestMissingFieldsAreNamed(t *testing.T) {
	for _, tc := range []struct{ name, text string }{
		{"без PrivateKey", "[Peer]\nPublicKey = " + publicB64 + "\nEndpoint = 1.2.3.4:1\n"},
		{"без Endpoint", "[Interface]\nPrivateKey = " + privateB64 +
			"\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = " + publicB64 + "\n"},
		{"без Address", "[Interface]\nPrivateKey = " + privateB64 +
			"\n[Peer]\nPublicKey = " + publicB64 + "\nEndpoint = 1.2.3.4:1\n"},
	} {
		if _, err := parseConf(tc.text); err == nil {
			t.Errorf("%s: разбор прошёл, хотя не должен", tc.name)
		}
	}
}

func TestPlainWireguardConfigNeedsNoObfuscation(t *testing.T) {
	// Тот же разбор обязан работать и для обычного WireGuard: без Jc/H*
	// строка их просто не содержит, и ядро ведёт себя как классический WG.
	c, err := parseConf("[Interface]\nPrivateKey = " + privateB64 +
		"\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = " + publicB64 +
		"\nEndpoint = 1.2.3.4:51820\n")
	if err != nil {
		t.Fatalf("разбор: %v", err)
	}
	if len(c.awg) != 0 {
		t.Errorf("взялись параметры обфускации: %v", c.awg)
	}
	// Пустой AllowedIPs должен превратиться в полный, иначе туннель поднимется
	// и не пропустит ни байта.
	if len(c.allowedIPs) != 2 {
		t.Errorf("AllowedIPs = %v, ожидался полный набор", c.allowedIPs)
	}
	if c.mtu != 1420 {
		t.Errorf("MTU = %d, ожидалось 1420", c.mtu)
	}
	// Без DNS в файле резолвить домены было бы нечем.
	if len(c.dns) != 1 || c.dns[0].String() != "1.1.1.1" {
		t.Errorf("DNS = %v, ожидался запасной 1.1.1.1", c.dns)
	}
}
