package main

import "encoding/binary"

// ENet wire details the server needs: it reads probes and relay tokens from
// the connect packets the game's ENet sockets send, and never speaks ENet
// itself (NETWORKING.md, Connectivity).
//
// A packet starts with a 2-byte header (peer id plus flags), then 2 bytes of
// sent time when the 0x8000 flag is set. A connect command follows: command
// byte 2 (with flag bits in the high nibble), channel, sequence, then 44
// bytes of parameters whose last 4 are the connect data, big-endian. LÖVE's
// lua-enet takes the data as a signed int, so tokens stay below 2^31.
const (
	enetSentTime   = 0x8000
	enetCompressed = 0x4000
	enetConnect    = 2
	connectLength  = 48
)

// connectData returns the data of an ENet connect packet, or ok false when
// the packet is anything else.
func connectData(packet []byte) (data uint32, ok bool) {
	if len(packet) < 2 {
		return 0, false
	}
	header := binary.BigEndian.Uint16(packet)
	if header&enetCompressed != 0 {
		return 0, false
	}
	at := 2
	if header&enetSentTime != 0 {
		at = 4
	}
	if len(packet) < at+connectLength || packet[at]&0x0f != enetConnect {
		return 0, false
	}
	return binary.BigEndian.Uint32(packet[at+connectLength-4:]), true
}
