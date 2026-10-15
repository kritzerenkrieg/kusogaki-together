package lobby

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"

	"kusogaki-together/server/relay"
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

type fixture struct {
	t      *testing.T
	server *Server
	clock  time.Time
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{t: t, clock: time.Unix(1000, 0)}
	r := relay.New(41000, 41099)
	r.Now = func() time.Time { return f.clock }
	f.server = New(r)
	t.Cleanup(func() {
		for _, room := range f.server.rooms {
			f.server.closeRoom(room)
		}
	})
	return f
}

func addr(text string) netip.AddrPort { return netip.MustParseAddrPort(text) }

func (f *fixture) send(from, text string) []string {
	reply := f.server.Packet([]byte(magic+text), addr(from))
	if !strings.HasPrefix(string(reply), magic) {
		f.t.Fatalf("%q: reply %q", text, reply)
	}
	return strings.Fields(string(reply[len(magic):]))
}

func (f *fixture) probe(from string, token uint32) {
	if f.server.Packet(connectPacket(token), addr(from)) != nil {
		f.t.Fatal("a probe is never answered")
	}
}

func TestRoomAndDirectJoin(t *testing.T) {
	f := newFixture(t)
	r := f.send("1.1.1.1:5000", "open 7 111 192.168.1.2:26967 0")
	if r[0] != "room" || len(r[1]) != 6 {
		t.Fatalf("open: %v", r)
	}
	code, secret := r[1], r[2]
	if again := f.send("1.1.1.1:5000", "open 7 111 192.168.1.2:26967 0"); again[1] != code {
		t.Fatal("a repeated open gets the same room")
	}
	f.probe("1.1.1.1:26967", 111)

	j := f.send("2.2.2.2:6000", "join "+code+" 7 222 10.0.0.5:40000 0")
	if j[0] != "joining" {
		t.Fatalf("join: %v", j)
	}
	id, jsecret := j[1], j[2]
	if s := f.send("2.2.2.2:6000", "status "+id+" "+jsecret); s[0] != "wait" {
		t.Fatalf("before the client's probe: %v", s)
	}
	f.probe("2.2.2.2:40001", 222)
	s := f.send("2.2.2.2:6000", "status "+id+" "+jsecret)
	if strings.Join(s, " ") != "direct 1.1.1.1:26967 192.168.1.2:26967" {
		t.Fatalf("status: %v", s)
	}
	p := f.send("1.1.1.1:5000", "poll "+code+" "+secret)
	if strings.Join(p, " ") != "hosted "+code+" join "+id+" 2.2.2.2:40001 10.0.0.5:40000" {
		t.Fatalf("poll: %v", p)
	}
	if bad := f.send("1.1.1.1:5000", "poll "+code+" wrong"); bad[0] != "error" {
		t.Fatal("a wrong secret is refused")
	}
	f.send("2.2.2.2:6000", "done "+id+" "+jsecret)
	if p := f.send("1.1.1.1:5000", "poll "+code+" "+secret); len(p) != 2 {
		t.Fatalf("a finished join is no longer listed: %v", p)
	}
}

func TestRefusals(t *testing.T) {
	f := newFixture(t)
	r := f.send("1.1.1.1:5000", "open 7 111 - 0")
	code := r[1]
	if j := f.send("2.2.2.2:6000", "join "+code+" 6 222 - 0"); j[0] != "error" || !strings.Contains(strings.Join(j, " "), "version") {
		t.Fatalf("an older protocol is refused: %v", j)
	}
	if j := f.send("2.2.2.2:6000", "join 000000 7 223 - 0"); j[0] != "error" && code != "000000" {
		t.Fatalf("a wrong code is refused: %v", j)
	}
	for _, bad := range []string{"open 7 x - 0", "open 7 1 nonsense 0", "join " + code + " 7 1 - 2", "frobnicate", ""} {
		if r := f.send("3.3.3.3:1", bad); r[0] != "error" {
			t.Fatalf("%q accepted: %v", bad, r)
		}
	}
	if f.server.Packet([]byte("hello"), addr("3.3.3.3:1")) != nil {
		t.Fatal("stray datagrams get no answer")
	}
	// Guessing codes: one address gets limitBurst tries, then must wait.
	for i := 0; i < limitBurst; i++ {
		f.send("4.4.4.4:1", "join 999999 7 5 - 0")
	}
	r2 := f.send("4.4.4.4:1", "join 999999 7 5 - 0")
	if !strings.Contains(strings.Join(r2, " "), "too many") {
		t.Fatalf("join attempts are rate-limited: %v", r2)
	}
	f.clock = f.clock.Add(time.Minute)
	if r := f.send("4.4.4.4:1", "join 999999 7 5 - 0"); strings.Contains(strings.Join(r, " "), "too many") {
		t.Fatal("the limit refills")
	}
	// A client resending its join (replies lost) does not spend the limit.
	first := f.send("5.5.5.5:1", "join "+code+" 7 333 - 0")
	for i := 0; i < 3*limitBurst; i++ {
		if again := f.send("5.5.5.5:1", "join "+code+" 7 333 - 0"); strings.Join(again, " ") != strings.Join(first, " ") {
			t.Fatalf("resend %d: %v, want %v", i, again, first)
		}
	}
}

func TestRoomExpires(t *testing.T) {
	f := newFixture(t)
	r := f.send("1.1.1.1:5000", "open 7 111 - 0")
	code, secret := r[1], r[2]
	f.clock = f.clock.Add(10 * time.Second)
	f.send("1.1.1.1:5000", "poll "+code+" "+secret)
	f.clock = f.clock.Add(10 * time.Second)
	f.server.Sweep()
	if f.server.rooms[code] == nil {
		t.Fatal("a polled room stays")
	}
	f.clock = f.clock.Add(16 * time.Second)
	f.server.Sweep()
	if f.server.rooms[code] != nil {
		t.Fatal("a room whose host stopped polling is closed")
	}
	if j := f.send("2.2.2.2:1", "join "+code+" 7 5 - 0"); j[0] != "error" {
		t.Fatal("a closed room cannot be joined")
	}
}

func TestRelayOnly(t *testing.T) {
	f := newFixture(t)
	r := f.send("1.1.1.1:5000", "open 7 111 - 1") // relay only
	code, secret := r[1], r[2]
	j := f.send("2.2.2.2:6000", "join "+code+" 7 222 - 0")
	id, jsecret := j[1], j[2]
	f.probe("1.1.1.1:26967", 111)
	f.probe("2.2.2.2:40001", 222)
	s := f.send("2.2.2.2:6000", "status "+id+" "+jsecret)
	pair := f.server.joins[id].pair
	if strings.Join(s, " ") != fmt.Sprintf("relay %d %d", pair.ClientPort, pair.ClientToken) {
		t.Fatalf("a relay-only room never gives addresses: %v", s)
	}
	p := f.send("1.1.1.1:5000", "poll "+code+" "+secret)
	if strings.Join(p[2:], " ") != fmt.Sprintf("relay %s %d %d", id, pair.HostPort, pair.HostToken) {
		t.Fatalf("the host gets the relay, not the client's address: %v", p)
	}
	f.send("2.2.2.2:6000", "done "+id+" "+jsecret)
	f.send("1.1.1.1:5000", "close "+code+" "+secret)
	if f.server.relay.Count() != 0 {
		t.Fatal("closing the room closes its relay pairs")
	}
}

func TestRelayOnRequestAndIdle(t *testing.T) {
	f := newFixture(t)
	r := f.send("1.1.1.1:5000", "open 7 111 - 0")
	j := f.send("2.2.2.2:6000", "join "+r[1]+" 7 222 - 0")
	f.probe("1.1.1.1:26967", 111)
	f.probe("2.2.2.2:40001", 222)
	if s := f.send("2.2.2.2:6000", "status "+j[1]+" "+j[2]); s[0] != "direct" {
		t.Fatalf("direct first: %v", s)
	}
	s := f.send("2.2.2.2:6000", "relay "+j[1]+" "+j[2])
	if s[0] != "relay" {
		t.Fatalf("relay on request: %v", s)
	}
	if again := f.send("2.2.2.2:6000", "relay "+j[1]+" "+j[2]); again[1] != s[1] || f.server.relay.Count() != 1 {
		t.Fatal("asking again gives the same pair")
	}
	f.clock = f.clock.Add(relay.Idle + time.Second)
	f.server.relay.Sweep()
	if f.server.relay.Count() != 0 {
		t.Fatal("a silent pair is closed")
	}
}
