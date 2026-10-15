package lobby

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"kusogaki-together/server/relay"
)

// Package lobby is the rendezvous: rooms with 6-digit codes, the control channel and probes
// (NETWORKING.md, Connectivity). Control messages are one line of text,
// "KG1 <verb> <fields...>", answered with one datagram:
//
//	host:   open <protocol> <probe> <lan> <relayOnly>  -> room <code> <secret>
//	        poll <code> <secret>     -> hosted <code>, then one line per join:
//	                                    join <id> <public> <lan>      punch these
//	                                    relay <id> <port> <token>     punch the relay
//	        close <code> <secret>    -> closed
//	client: join <code> <protocol> <probe> <lan> <relayOnly> -> joining <id> <secret>
//	        status <id> <secret>     -> wait | direct <public> <lan> | relay <port> <token>
//	        relay <id> <secret>      -> the same as status, after asking for the relay
//	        done <id> <secret>       -> done
//	any:    -> error <reason>
//
// A probe is an ENet connect packet from a machine's game socket whose
// connect data is its probe token: it tells the server that socket's public
// address. Addresses are "ip:port"; a LAN address may be "-". Relay ports are
// on this server's own address, which the game already knows.

const (
	magic         = "KG1 "
	roomIdle      = 15 * time.Second // a room whose host stopped polling is closed
	joinLife      = 60 * time.Second // a join not finished by then is forgotten
	probeLife     = 60 * time.Second
	maxJoins      = 8 // pending joins per room
	maxRooms      = 10000
	maxProbes     = 100000
	limitBurst    = 20        // opens and joins per address ...
	limitPerSec   = 20.0 / 60 // ... refilled per second
	maxControlLen = 512
)

type Room struct {
	code, secret string
	protocol     int
	probe        uint32
	lan          string
	relayOnly    bool
	lastPoll     time.Time
	joins        []*Join
	pairs        []*relay.Pair // relay pairs of finished or forgotten joins
}

type Join struct {
	id, secret string
	room       *Room
	probe      uint32
	lan        string
	relayOnly  bool
	created    time.Time
	pair       *relay.Pair
}

type probeSeen struct {
	addr netip.AddrPort
	at   time.Time
}

// Server holds the rooms. Packet and Sweep are called from one goroutine.
type Server struct {
	relay  *relay.Relay
	rooms  map[string]*Room
	joins  map[string]*Join
	probes map[uint32]probeSeen
	limits map[netip.Addr]*relay.Bucket
	now    func() time.Time
	Log    func(format string, args ...any) // room events (never addresses)
}

// New makes a lobby that opens relay pairs from r.
func New(r *relay.Relay) *Server {
	return &Server{
		relay:  r,
		rooms:  map[string]*Room{},
		joins:  map[string]*Join{},
		probes: map[uint32]probeSeen{},
		limits: map[netip.Addr]*relay.Bucket{},
		now:    func() time.Time { return r.Now() },
		Log:    func(string, ...any) {},
	}
}

func randomHex(bytes int) string {
	b := make([]byte, bytes)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func randomToken() uint32 {
	b := make([]byte, 4)
	rand.Read(b)
	return binary.BigEndian.Uint32(b)&0x7fffffff | 1
}

func (s *Server) newCode() string {
	for {
		b := make([]byte, 4)
		rand.Read(b)
		code := fmt.Sprintf("%06d", binary.BigEndian.Uint32(b)%1000000)
		if s.rooms[code] == nil {
			return code
		}
	}
}

// Packet handles one datagram from `from` and returns the reply (nil: none).
func (s *Server) Packet(packet []byte, from netip.AddrPort) []byte {
	from = netip.AddrPortFrom(from.Addr().Unmap(), from.Port())
	if token, ok := relay.ConnectData(packet); ok {
		if len(s.probes) < maxProbes || s.probes[token].addr.IsValid() {
			s.probes[token] = probeSeen{from, s.now()}
		}
		return nil
	}
	if len(packet) > maxControlLen || !strings.HasPrefix(string(packet), magic) {
		return nil
	}
	return []byte(magic + s.control(strings.Fields(string(packet[len(magic):])), from))
}

func errorReply(reason string) string { return "error " + reason }

// lan checks a LAN address field: "-" or an IPv4 ip:port.
func lanField(text string) (string, bool) {
	if text == "-" {
		return text, true
	}
	addr, err := netip.ParseAddrPort(text)
	if err != nil || !addr.Addr().Is4() {
		return "", false
	}
	return addr.String(), true
}

func intField(text string, max int) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil && n >= 0 && n <= max
}

func (s *Server) allowed(addr netip.Addr) bool {
	b := s.limits[addr]
	if b == nil {
		b = &relay.Bucket{}
		s.limits[addr] = b
	}
	return b.Take(1, s.now(), limitPerSec, limitBurst)
}

func (s *Server) control(f []string, from netip.AddrPort) string {
	if len(f) == 0 {
		return errorReply("empty message")
	}
	switch {
	case f[0] == "open" && len(f) == 5:
		return s.open(f[1:], from)
	case f[0] == "poll" && len(f) == 3:
		room := s.rooms[f[1]]
		if room == nil || room.secret != f[2] {
			return errorReply("no such room")
		}
		room.lastPoll = s.now()
		return s.hosted(room)
	case f[0] == "close" && len(f) == 3:
		room := s.rooms[f[1]]
		if room != nil && room.secret == f[2] {
			s.closeRoom(room)
		}
		return "closed"
	case f[0] == "join" && len(f) == 6:
		return s.join(f[1:], from)
	case (f[0] == "status" || f[0] == "relay" || f[0] == "done") && len(f) == 3:
		join := s.joins[f[1]]
		if join == nil || join.secret != f[2] {
			return errorReply("no such join")
		}
		if s.rooms[join.room.code] != join.room {
			return errorReply("the room is closed")
		}
		if f[0] == "done" {
			s.forgetJoin(join)
			return "done"
		}
		if f[0] == "relay" && join.pair == nil {
			if reply := s.openRelay(join); reply != "" {
				return reply
			}
		}
		return s.status(join)
	}
	return errorReply("bad message")
}

func (s *Server) open(f []string, from netip.AddrPort) string {
	protocol, ok1 := intField(f[0], 65535)
	probe, ok2 := intField(f[1], 1<<31-1)
	lan, ok3 := lanField(f[2])
	if !ok1 || !ok2 || !ok3 || (f[3] != "0" && f[3] != "1") {
		return errorReply("bad message")
	}
	// The same host asking again (its reply was lost) gets the same room.
	for _, room := range s.rooms {
		if room.probe == uint32(probe) {
			return "room " + room.code + " " + room.secret
		}
	}
	if !s.allowed(from.Addr()) {
		return errorReply("too many requests, wait a minute")
	}
	if len(s.rooms) >= maxRooms {
		return errorReply("the server is full")
	}
	room := &Room{
		code: s.newCode(), secret: randomHex(8), protocol: protocol, probe: uint32(probe),
		lan: lan, relayOnly: f[3] == "1", lastPoll: s.now(),
	}
	s.rooms[room.code] = room
	s.Log("room %s opened (%d rooms)", room.code, len(s.rooms))
	return "room " + room.code + " " + room.secret
}

func (s *Server) join(f []string, from netip.AddrPort) string {
	protocol, ok1 := intField(f[1], 65535)
	probe, ok2 := intField(f[2], 1<<31-1)
	lan, ok3 := lanField(f[3])
	if !ok1 || !ok2 || !ok3 || (f[4] != "0" && f[4] != "1") {
		return errorReply("bad message")
	}
	// The same client asking again (its reply was lost) gets the same join,
	// without spending its limit.
	if room := s.rooms[f[0]]; room != nil {
		for _, join := range room.joins {
			if join.probe == uint32(probe) {
				return "joining " + join.id + " " + join.secret
			}
		}
	}
	if !s.allowed(from.Addr()) {
		return errorReply("too many requests, wait a minute")
	}
	room := s.rooms[f[0]]
	if room == nil {
		return errorReply("no such room")
	}
	if protocol != room.protocol {
		return errorReply(fmt.Sprintf("version mismatch: the host runs protocol %d, you run %d", room.protocol, protocol))
	}
	if len(room.joins) >= maxJoins {
		return errorReply("the room is busy, try again")
	}
	join := &Join{
		id: randomHex(8), secret: randomHex(8), room: room, probe: uint32(probe),
		lan: lan, relayOnly: f[4] == "1", created: s.now(),
	}
	room.joins = append(room.joins, join)
	s.joins[join.id] = join
	if join.relayOnly || room.relayOnly {
		if reply := s.openRelay(join); reply != "" {
			s.forgetJoin(join)
			return reply
		}
	}
	return "joining " + join.id + " " + join.secret
}

func (s *Server) openRelay(join *Join) string {
	pair, err := s.relay.Open(randomToken(), randomToken())
	if err != nil {
		return errorReply("the relay is full, try again later")
	}
	join.pair = pair
	s.Log("relay %d/%d for room %s", pair.ClientPort, pair.HostPort, join.room.code)
	return ""
}

func (s *Server) probeAddr(token uint32) (netip.AddrPort, bool) {
	seen, ok := s.probes[token]
	return seen.addr, ok
}

// direct reports whether the two may connect directly (neither asked for
// the relay only) and both probes have arrived.
func (s *Server) direct(join *Join) (host, client netip.AddrPort, ok bool) {
	if join.relayOnly || join.room.relayOnly {
		return host, client, false
	}
	host, ok1 := s.probeAddr(join.room.probe)
	client, ok2 := s.probeAddr(join.probe)
	return host, client, ok1 && ok2
}

func (s *Server) hosted(room *Room) string {
	lines := []string{"hosted " + room.code}
	for _, join := range room.joins {
		if _, client, ok := s.direct(join); ok {
			lines = append(lines, fmt.Sprintf("join %s %s %s", join.id, client, join.lan))
		}
		if join.pair != nil {
			lines = append(lines, fmt.Sprintf("relay %s %d %d", join.id, join.pair.HostPort, join.pair.HostToken))
		}
	}
	return strings.Join(lines, "\n")
}

func (s *Server) status(join *Join) string {
	if join.pair != nil {
		return fmt.Sprintf("relay %d %d", join.pair.ClientPort, join.pair.ClientToken)
	}
	if host, _, ok := s.direct(join); ok {
		return fmt.Sprintf("direct %s %s", host, join.room.lan)
	}
	return "wait"
}

// forgetJoin drops a join; its relay pair, if any, lives on until idle or
// the room closes.
func (s *Server) forgetJoin(join *Join) {
	delete(s.joins, join.id)
	room := join.room
	for i, other := range room.joins {
		if other == join {
			room.joins = append(room.joins[:i], room.joins[i+1:]...)
			break
		}
	}
	if join.pair != nil {
		room.pairs = append(room.pairs, join.pair)
	}
}

func (s *Server) closeRoom(room *Room) {
	for _, join := range append([]*Join(nil), room.joins...) {
		s.forgetJoin(join)
	}
	for _, pair := range room.pairs {
		pair.Close()
	}
	delete(s.rooms, room.code)
	s.Log("room %s closed (%d rooms)", room.code, len(s.rooms))
}

// Sweep forgets what has expired.
func (s *Server) Sweep() {
	now := s.now()
	for _, room := range s.rooms {
		if now.Sub(room.lastPoll) > roomIdle {
			s.closeRoom(room)
			continue
		}
		for _, join := range append([]*Join(nil), room.joins...) {
			if now.Sub(join.created) > joinLife {
				s.forgetJoin(join)
			}
		}
	}
	for token, seen := range s.probes {
		if now.Sub(seen.at) > probeLife {
			delete(s.probes, token)
		}
	}
	for addr, b := range s.limits {
		if b.Idle(now) > time.Minute*2 {
			delete(s.limits, addr)
		}
	}
	s.relay.Sweep()
}
