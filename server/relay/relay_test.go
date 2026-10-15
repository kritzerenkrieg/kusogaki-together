package relay

import (
	"encoding/binary"
	"encoding/hex"
	"net"
	"testing"
	"time"
)

// A connect packet as LÖVE 11.5's ENet sends it (captured), with its data.
func connectPacket(data uint32) []byte {
	packet, err := hex.DecodeString("8ffffc0e82ff00010000ffff000005780001000000000003" +
		"00000000000000000000138800000002" + "00000002e7a1914080000000")
	if err != nil || len(packet) != 52 {
		panic("bad captured packet")
	}
	binary.BigEndian.PutUint32(packet[48:], data)
	return packet
}

func TestConnectData(t *testing.T) {
	if data, ok := ConnectData(connectPacket(12345)); !ok || data != 12345 {
		t.Fatalf("captured connect: %d %v", data, ok)
	}
	short := connectPacket(1)[:40]
	if _, ok := ConnectData(short); ok {
		t.Fatal("a truncated packet is not a connect")
	}
	other := connectPacket(1)
	other[4] = 0x86 // a send command
	if _, ok := ConnectData(other); ok {
		t.Fatal("another command is not a connect")
	}
	if _, ok := ConnectData([]byte("KG1 poll 1 2")); ok {
		t.Fatal("control text is not a connect")
	}
}

// udp opens a loopback socket standing in for a game's ENet socket.
func udp(t *testing.T) *net.UDPConn {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func sendTo(t *testing.T, conn *net.UDPConn, port int, data []byte) {
	if _, err := conn.WriteToUDP(data, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port}); err != nil {
		t.Fatal(err)
	}
}

func receive(conn *net.UDPConn) (string, bool) {
	conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	buf := make([]byte, MaxPacket)
	n, err := conn.Read(buf)
	return string(buf[:n]), err == nil
}

func TestForwarding(t *testing.T) {
	r := New(41100, 41199)
	pair, err := r.Open(1234, 5678)
	if err != nil {
		t.Fatal(err)
	}
	defer pair.Close()
	client, host, stranger := udp(t), udp(t), udp(t)

	// Nothing passes before both ends showed their tokens.
	sendTo(t, client, pair.ClientPort, connectPacket(pair.ClientToken))
	sendTo(t, stranger, pair.HostPort, connectPacket(pair.ClientToken)) // wrong token
	if got, ok := receive(stranger); ok {
		t.Fatalf("nothing reaches a stranger: %q", got)
	}
	sendTo(t, host, pair.HostPort, connectPacket(pair.HostToken))
	if got, ok := receive(client); ok {
		t.Fatalf("the host's punch must not reach the client: %q", got)
	}
	if got, ok := receive(host); ok {
		t.Fatalf("the client's connect before the host was known is dropped: %q", got)
	}
	// Now both ends are known: the client's connect retry reaches the host.
	sendTo(t, client, pair.ClientPort, connectPacket(pair.ClientToken))
	if got, ok := receive(host); !ok || got != string(connectPacket(pair.ClientToken)) {
		t.Fatalf("client -> host: %q %v", got, ok)
	}
	sendTo(t, host, pair.HostPort, []byte("state"))
	if got, ok := receive(client); !ok || got != "state" {
		t.Fatalf("host -> client: %q %v", got, ok)
	}
	sendTo(t, stranger, pair.HostPort, []byte("spoof"))
	sendTo(t, stranger, pair.ClientPort, []byte("spoof"))
	if got, ok := receive(client); ok {
		t.Fatalf("a stranger's datagram passed: %q", got)
	}
	if got, ok := receive(host); ok {
		t.Fatalf("a stranger's datagram passed: %q", got)
	}
}

func TestPortsAndIdle(t *testing.T) {
	clock := time.Unix(1000, 0)
	r := New(41200, 41203) // room for two pairs
	r.Now = func() time.Time { return clock }
	a, err1 := r.Open(1, 2)
	b, err2 := r.Open(3, 4)
	_, err3 := r.Open(5, 6)
	if err1 != nil || err2 != nil || err3 != ErrFull {
		t.Fatalf("two pairs fit, a third does not: %v %v %v", err1, err2, err3)
	}
	a.Close()
	if c, err := r.Open(7, 8); err != nil {
		t.Fatal("a closed pair's ports are free again")
	} else {
		c.Close()
	}
	clock = clock.Add(Idle + time.Second)
	r.Sweep()
	if r.Count() != 0 {
		t.Fatal("a silent pair is closed")
	}
	b.Close()
}

func TestBucket(t *testing.T) {
	var b Bucket
	now := time.Unix(0, 0)
	if !b.Take(100, now, 10, 100) || b.Take(1, now, 10, 100) {
		t.Fatal("a full bucket gives its burst, then nothing")
	}
	if !b.Take(10, now.Add(time.Second), 10, 100) {
		t.Fatal("it refills at the rate")
	}
}
