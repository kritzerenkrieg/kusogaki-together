// Command kusogaki-server is the rendezvous and relay for Kusogaki
// Together's internet play (NETWORKING.md, Connectivity). It introduces the
// machines in a room so they can connect peer to peer, and relays their
// packets when that fails. It never runs the game.
//
//	kusogaki-server -addr :26968 -relay-ports 27000-27999
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
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
	server := NewServer(NewRelay(lo, hi))
	server.log = log.New(os.Stderr, "", log.LstdFlags).Printf
	log.Printf("kusogaki-server on %s, relay ports %d-%d", conn.LocalAddr(), lo, hi)
	buf := make([]byte, maxPacket)
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
			lastSweep = time.Now()
		}
	}
}
