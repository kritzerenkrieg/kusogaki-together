// Command kusogaki-server is Kusogaki Together's public server: the lobby
// (rooms, codes, introductions for hole punching), the relay and the level
// repository (HTTP, on the lobby's port number over TCP). It never runs the
// game. See server/README.md and server/DEPLOYMENT.md.
//
//	kusogaki-server -addr :26968 -relay-ports 27000-27999 -data /var/lib/kusogaki-server
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"kusogaki-together/server/lobby"
	"kusogaki-together/server/relay"
	"kusogaki-together/server/repository"
)

func parseRange(text string) (int, int, error) {
	lo, hi, found := strings.Cut(text, "-")
	a, err1 := strconv.Atoi(lo)
	b, err2 := strconv.Atoi(hi)
	if !found || err1 != nil || err2 != nil || a < 1 || b > 65535 || b < a+1 {
		return 0, 0, fmt.Errorf("bad port range %q (want like 27000-27999)", text)
	}
	return a, b, nil
}

func main() {
	addr := flag.String("addr", ":26968", "UDP address for rooms and probes")
	ports := flag.String("relay-ports", "27000-27999", "UDP port range for relay pairs (two ports per relayed player)")
	data := flag.String("data", "", "directory of the level repository (none: no repository)")
	httpAddr := flag.String("http", "", "TCP address for the level repository (default: the -addr port)")
	flag.Parse()
	lo, hi, err := parseRange(*ports)
	if err != nil {
		log.Fatal(err)
	}
	udpAddr, err := net.ResolveUDPAddr("udp4", *addr)
	if err != nil {
		log.Fatal(err)
	}
	conn, err := net.ListenUDP("udp4", udpAddr)
	if err != nil {
		log.Fatal(err)
	}
	server := lobby.New(relay.New(lo, hi))
	server.Log = log.New(os.Stderr, "", log.LstdFlags).Printf
	log.Printf("kusogaki-server on %s, relay ports %d-%d", conn.LocalAddr(), lo, hi)
	var store *repository.Store
	if *data != "" {
		store = serveRepository(*data, *httpAddr, *addr)
	}
	buf := make([]byte, relay.MaxPacket)
	lastSweep := time.Now()
	for {
		conn.SetReadDeadline(time.Now().Add(time.Second))
		n, from, err := conn.ReadFromUDPAddrPort(buf)
		if err == nil {
			if reply := server.Packet(buf[:n], from); reply != nil {
				conn.WriteToUDPAddrPort(reply, from)
			}
		}
		if time.Since(lastSweep) >= time.Second {
			server.Sweep()
			if store != nil {
				store.Sweep()
			}
			lastSweep = time.Now()
		}
	}
}

// serveRepository opens the level repository in dir and serves it over HTTP
// on httpAddr (or on the UDP address's port, over TCP).
func serveRepository(dir, httpAddr, udpAddr string) *repository.Store {
	store, err := repository.Open(dir)
	if err != nil {
		log.Fatal(err)
	}
	store.Log = log.New(os.Stderr, "", log.LstdFlags).Printf
	if httpAddr == "" {
		httpAddr = udpAddr
	}
	listener, err := net.Listen("tcp4", httpAddr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("level repository on %s (%d levels in %s)", listener.Addr(), store.Count(), dir)
	httpServer := &http.Server{
		Handler:           store.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
		ErrorLog:          log.New(io.Discard, "", 0), // no addresses in the log
	}
	go func() { log.Fatal(httpServer.Serve(listener)) }()
	return store
}
