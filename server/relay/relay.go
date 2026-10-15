// Package relay copies datagrams between two machines that could not
// connect directly (README.md in this folder).
package relay

import (
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"
)

// For each relayed client a pair of UDP ports. The client
// connects to the first as if it were the host; the host makes a connect
// attempt to the second. Each end is accepted only from a connect packet
// carrying the token issued for it, and from then on datagrams are copied
// between the two, capped in rate. ENet runs end to end through it.

const (
	Idle      = 30 * time.Second // a pair silent this long is closed
	Rate      = 64 * 1024        // bytes per second, each direction
	Burst     = 256 * 1024       // bytes
	MaxPacket = 2048             // largest datagram read
)

var ErrFull = errors.New("relay full")

// Relay hands out port pairs from a range.
type Relay struct {
	mu    sync.Mutex
	lo    int
	hi    int
	used  map[int]bool
	pairs map[*Pair]bool
	Now   func() time.Time // the clock (tests set it)
}

// New makes a relay using UDP ports lo..hi (two per relayed player).
func New(lo, hi int) *Relay {
	return &Relay{lo: lo, hi: hi, used: map[int]bool{}, pairs: map[*Pair]bool{}, Now: time.Now}
}

// Bucket is a token bucket.
type Bucket struct {
	tokens float64
	last   time.Time
}

// Take removes n tokens if there are enough, refilling at rate per second up
// to burst.
func (b *Bucket) Take(n int, now time.Time, rate, burst float64) bool {
	if b.last.IsZero() {
		b.tokens = burst
	} else {
		b.tokens += now.Sub(b.last).Seconds() * rate
		if b.tokens > burst {
			b.tokens = burst
		}
	}
	b.last = now
	if b.tokens < float64(n) {
		return false
	}
	b.tokens -= float64(n)
	return true
}

// Pair is one relayed client: ClientPort for the client, HostPort for the
// host, each end accepted from a connect packet carrying its token.
type Pair struct {
	relay       *Relay
	client      *net.UDPConn
	host        *net.UDPConn
	ClientPort  int
	HostPort    int
	ClientToken uint32
	HostToken   uint32

	mu         sync.Mutex
	clientAddr netip.AddrPort
	hostAddr   netip.AddrPort
	last       time.Time
	up, down   Bucket
	closed     bool
}

// Open a pair on two free ports of the range.
func (r *Relay) Open(clientToken, hostToken uint32) (*Pair, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var conns []*net.UDPConn
	var ports []int
	for port := r.lo; port <= r.hi && len(conns) < 2; port++ {
		if r.used[port] {
			continue
		}
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: port})
		if err != nil {
			continue // taken by something else
		}
		conns = append(conns, conn)
		ports = append(ports, port)
	}
	if len(conns) < 2 {
		for _, conn := range conns {
			conn.Close()
		}
		return nil, ErrFull
	}
	p := &Pair{
		relay: r, client: conns[0], host: conns[1],
		ClientPort: ports[0], HostPort: ports[1],
		ClientToken: clientToken, HostToken: hostToken,
		last: r.Now(),
	}
	r.used[ports[0]], r.used[ports[1]] = true, true
	r.pairs[p] = true
	go p.forward(true)
	go p.forward(false)
	return p, nil
}

// forward copies datagrams arriving on one end of the pair to the other.
func (p *Pair) forward(fromClient bool) {
	in, out := p.client, p.host
	if !fromClient {
		in, out = p.host, p.client
	}
	buf := make([]byte, MaxPacket)
	for {
		n, from, err := in.ReadFromUDPAddrPort(buf)
		if err != nil {
			if p.isClosed() {
				return
			}
			continue
		}
		from = netip.AddrPortFrom(from.Addr().Unmap(), from.Port())
		packet := buf[:n]
		data, isConnect := ConnectData(packet)
		p.mu.Lock()
		self, other := &p.clientAddr, &p.hostAddr
		token, limit := p.ClientToken, &p.up
		if !fromClient {
			self, other = &p.hostAddr, &p.clientAddr
			token, limit = p.HostToken, &p.down
		}
		if !self.IsValid() && isConnect && data == token {
			*self = from
		}
		send := *self == from && other.IsValid()
		// The host's connect attempts only open its router; the client never
		// sees them.
		if !fromClient && isConnect && data == p.HostToken {
			send = false
		}
		now := p.relay.Now()
		if *self == from {
			p.last = now
		}
		if send && !limit.Take(n, now, Rate, Burst) {
			send = false
		}
		to := *other
		p.mu.Unlock()
		if send {
			out.WriteToUDPAddrPort(packet, to)
		}
	}
}

func (p *Pair) isClosed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closed
}

// Close the pair and free its ports.
func (p *Pair) Close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	p.mu.Unlock()
	p.client.Close()
	p.host.Close()
	r := p.relay
	r.mu.Lock()
	delete(r.used, p.ClientPort)
	delete(r.used, p.HostPort)
	delete(r.pairs, p)
	r.mu.Unlock()
}

// Sweep closes pairs silent for Idle.
func (r *Relay) Sweep() {
	now := r.Now()
	r.mu.Lock()
	var idle []*Pair
	for p := range r.pairs {
		p.mu.Lock()
		if now.Sub(p.last) > Idle {
			idle = append(idle, p)
		}
		p.mu.Unlock()
	}
	r.mu.Unlock()
	for _, p := range idle {
		p.Close()
	}
}

// Count is the number of open pairs.
func (r *Relay) Count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.pairs)
}

// Idle is how long the bucket has not been used.
func (b *Bucket) Idle(now time.Time) time.Duration {
	return now.Sub(b.last)
}
