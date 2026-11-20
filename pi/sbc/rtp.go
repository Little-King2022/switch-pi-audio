package main

import "encoding/binary"

type mediaPackets struct {
	seen     bool
	sequence uint16
	fragment []byte
}

func (m *mediaPackets) parse(packet []byte) (frames []byte, gap, malformed bool) {
	if len(packet) < 13 || packet[0]>>6 != 2 {
		return nil, false, true
	}
	sequence := binary.BigEndian.Uint16(packet[2:4])
	gap = m.seen && sequence != m.sequence+1
	m.seen, m.sequence = true, sequence
	if gap {
		m.fragment = nil
	}
	end := len(packet)
	if packet[0]&0x20 != 0 {
		pad := int(packet[end-1])
		if pad == 0 || pad > end-13 {
			return nil, gap, true
		}
		end -= pad
	}
	offset := 12 + 4*int(packet[0]&15)
	if packet[0]&0x10 != 0 {
		if offset+4 >= end {
			return nil, gap, true
		}
		offset += 4 + 4*int(binary.BigEndian.Uint16(packet[offset+2:offset+4]))
	}
	if offset+1 >= end {
		return nil, gap, true
	}
	header, payload := packet[offset], packet[offset+1:end]
	switch {
	case header&0xe0 == 0:
		m.fragment = nil
		count := int(header & 15)
		if count == 0 || !sbcFrames(payload, count) {
			return nil, gap, true
		}
		return payload, gap, false
	case header&0x80 != 0:
		if header&0x40 != 0 {
			m.fragment = make([]byte, 0, 119)
		}
		if m.fragment == nil || len(m.fragment)+len(payload) > 119 {
			m.fragment = nil
			return nil, gap, true
		}
		m.fragment = append(m.fragment, payload...)
		if header&0x20 == 0 {
			return nil, gap, false
		}
		frame := m.fragment
		m.fragment = nil
		if sbcFrames(frame, 1) {
			return frame, gap, false
		}
	}
	return nil, gap, true
}

func sbcFrames(data []byte, count int) bool {
	for i := 0; i < count; i++ {
		if len(data) < 4 || data[0] != 0x9c || data[1]&0xf1 != 0xf1 || data[2] < 2 || data[2] > 53 {
			return false
		}
		mode := (data[1] >> 2) & 3
		if mode < 2 {
			return false
		}
		bytes := 12 + 2*int(data[2])
		if mode == 3 {
			bytes++
		}
		if len(data) < bytes {
			return false
		}
		data = data[bytes:]
	}
	return len(data) == 0
}
