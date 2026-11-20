package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
	"golang.org/x/sys/unix"
)

const (
	bluez              = "org.bluez"
	adapter            = dbus.ObjectPath("/org/bluez/hci0")
	endpointPath       = dbus.ObjectPath("/local/SwitchAudio/SBC")
	endpointInterface  = "org.bluez.MediaEndpoint1"
	transportInterface = "org.bluez.MediaTransport1"
	socketPath         = "/var/run/switch-audio-sbc.sock"
)

var capabilities = []byte{0x13, 0x15, 2, 53} // 48 kHz, stereo/joint stereo, 16 blocks, 8 subbands.

type endpoint struct {
	bus         *dbus.Conn
	owner       string
	mu          sync.Mutex
	transport   dbus.ObjectPath
	cancel      context.CancelFunc
	stream      sync.Mutex
	client      *net.UnixConn
	released    chan struct{}
	releaseOnce sync.Once
}

func (e *endpoint) authorized(sender dbus.Sender) *dbus.Error {
	if string(sender) != e.owner {
		return dbus.NewError("org.freedesktop.DBus.Error.AccessDenied", nil)
	}
	return nil
}

func (e *endpoint) SelectConfiguration(sender dbus.Sender, caps []byte) ([]byte, *dbus.Error) {
	if err := e.authorized(sender); err != nil {
		return nil, err
	}
	if len(caps) != 4 || caps[0]&0x10 == 0 || caps[0]&0x03 == 0 || caps[1]&0x14 != 0x14 ||
		caps[1]&3 == 0 || max(caps[2], 2) > min(caps[3], 53) {
		return nil, invalid(fmt.Errorf("incompatible SBC capabilities: %x", caps))
	}
	mode := byte(1)
	if caps[0]&mode == 0 {
		mode = 2
	}
	allocation := byte(1)
	if caps[1]&allocation == 0 {
		allocation = 2
	}
	return []byte{0x10 | mode, 0x14 | allocation, max(caps[2], 2), min(caps[3], 53)}, nil
}

func (e *endpoint) SetConfiguration(sender dbus.Sender, path dbus.ObjectPath, properties map[string]dbus.Variant) *dbus.Error {
	if err := e.authorized(sender); err != nil {
		return err
	}
	config, ok := properties["Configuration"].Value().([]byte)
	if !ok || len(config) != 4 || (config[0] != 0x11 && config[0] != 0x12) ||
		(config[1] != 0x15 && config[1] != 0x16) || config[2] < 2 || config[3] > 53 || config[2] > config[3] {
		return invalid(fmt.Errorf("unsupported SBC configuration: %x", config))
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.transport != "" && e.transport != path {
		return dbus.NewError("org.bluez.Error.NotAvailable", nil)
	}
	if e.cancel != nil {
		e.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	e.transport, e.cancel = path, cancel
	go e.readTransport(ctx, path)
	log.Printf("SBC negotiated: %x", config)
	return nil
}

func (e *endpoint) ClearConfiguration(sender dbus.Sender, path dbus.ObjectPath) *dbus.Error {
	if err := e.authorized(sender); err != nil {
		return err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.transport == path {
		e.cancel()
		e.transport, e.cancel = "", nil
	}
	return nil
}

func (e *endpoint) Release(sender dbus.Sender) *dbus.Error {
	if err := e.authorized(sender); err != nil {
		return err
	}
	e.releaseOnce.Do(func() { close(e.released) })
	return nil
}

func invalid(err error) *dbus.Error {
	return dbus.NewError("org.bluez.Error.InvalidArguments", []any{err.Error()})
}

func (e *endpoint) readTransport(ctx context.Context, path dbus.ObjectPath) {
	obj := e.bus.Object(e.owner, path)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		var state dbus.Variant
		err := obj.CallWithContext(ctx, "org.freedesktop.DBus.Properties.Get", 0, transportInterface, "State").Store(&state)
		if err != nil || state.Value() != "pending" {
			continue
		}
		var fd dbus.UnixFD
		var readMTU, writeMTU uint16
		err = obj.CallWithContext(ctx, transportInterface+".TryAcquire", 0).Store(&fd, &readMTU, &writeMTU)
		if err != nil {
			continue
		}
		log.Printf("SBC transport acquired, MTU %d", readMTU)
		e.drainTransport(ctx, int(fd), int(readMTU))
		unix.Close(int(fd))
		// BlueZ releases the transport as the peer suspends it. Release also
		// clears our acquisition if the file descriptor ended first.
		if ctx.Err() == nil {
			releaseCtx, cancel := context.WithTimeout(ctx, time.Second)
			obj.CallWithContext(releaseCtx, transportInterface+".Release", 0)
			cancel()
		}
	}
}

func (e *endpoint) drainTransport(ctx context.Context, fd, mtu int) {
	if mtu < 13 || unix.SetNonblock(fd, true) != nil {
		return
	}
	packet := make([]byte, mtu)
	poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	var decoder mediaPackets
	var count, gaps, bad int
	defer func() { log.Printf("RTP ended: %d packets, %d sequence gaps, %d malformed", count, gaps, bad) }()
	for ctx.Err() == nil {
		ready, err := unix.Poll(poll, 100)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return
		}
		if ready == 0 {
			continue
		}
		if poll[0].Revents&unix.POLLIN == 0 {
			return
		}
		n, err := unix.Read(fd, packet)
		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil || n == 0 {
			return
		}
		count++
		frames, gap, malformed := decoder.parse(packet[:n])
		if gap {
			gaps++
		}
		if malformed {
			bad++
		}
		if len(frames) > 0 && ctx.Err() == nil {
			e.publish(frames)
		}
	}
}

func (e *endpoint) publish(frames []byte) {
	e.stream.Lock()
	defer e.stream.Unlock()
	if e.client == nil {
		return
	}
	e.client.SetWriteDeadline(time.Now().Add(10 * time.Millisecond))
	if _, err := e.client.Write(frames); err != nil {
		e.client.Close()
		e.client = nil
	}
}

func serve(ctx context.Context) error {
	bus, err := dbus.ConnectSystemBus()
	if err != nil {
		return err
	}
	defer bus.Close()
	if !bus.SupportsUnixFDs() {
		return errors.New("system bus does not support Unix file descriptors")
	}
	var owner string
	if err = bus.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, bluez).Store(&owner); err != nil {
		return err
	}
	e := &endpoint{bus: bus, owner: owner, released: make(chan struct{})}
	if err = bus.Export(e, endpointPath, endpointInterface); err != nil {
		return err
	}
	media := bus.Object(owner, adapter)
	properties := map[string]dbus.Variant{
		"UUID":         dbus.MakeVariant("0000110b-0000-1000-8000-00805f9b34fb"),
		"Codec":        dbus.MakeVariant(byte(0)),
		"Capabilities": dbus.MakeVariant(capabilities),
	}
	if err = media.Call("org.bluez.Media1.RegisterEndpoint", 0, endpointPath, properties).Err; err != nil {
		return err
	}
	defer func() {
		timeout, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		media.CallWithContext(timeout, "org.bluez.Media1.UnregisterEndpoint", 0, endpointPath)
	}()
	if err = os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	if err = os.Chmod(socketPath, 0600); err != nil {
		return err
	}
	log.Print("SBC endpoint registered")
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		select {
		case <-e.released:
		case <-ctx.Done():
		case <-bus.Context().Done():
		case <-ticker.C:
			for {
				var actual string
				if bus.BusObject().CallWithContext(ctx, "org.freedesktop.DBus.GetNameOwner", 0, bluez).Store(&actual) != nil || actual != owner {
					break
				}
				select {
				case <-e.released:
				case <-ctx.Done():
				case <-bus.Context().Done():
				case <-ticker.C:
					continue
				}
				break
			}
		}
		listener.Close()
	}()
	defer func() {
		e.mu.Lock()
		if e.cancel != nil {
			e.cancel()
		}
		e.mu.Unlock()
		e.stream.Lock()
		if e.client != nil {
			e.client.Close()
		}
		e.stream.Unlock()
	}()
	for {
		client, err := listener.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		client.SetWriteBuffer(8192)
		e.stream.Lock()
		if e.client != nil {
			e.client.Close()
		}
		e.client = client
		e.stream.Unlock()
		go func() {
			io.Copy(io.Discard, client) // EOF when the SSH reader exits.
			e.stream.Lock()
			if e.client == client {
				e.client = nil
			}
			e.stream.Unlock()
			client.Close()
		}()
	}
}

func readStream() error {
	conn, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		return fmt.Errorf("树莓派的 BlueZ 直读未启动。请先切换树莓派后端: %w", err)
	}
	defer conn.Close()
	_, err = io.Copy(os.Stdout, conn)
	return err
}

func main() {
	log.SetFlags(0)
	if len(os.Args) == 2 && os.Args[1] == "--read" {
		if err := readStream(); err != nil {
			log.Fatal(err)
		}
		return
	}
	if len(os.Args) != 1 {
		log.Fatal("usage: switch-audio-sbc [--read]")
	}
	syscall.Umask(0077)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := serve(ctx); err != nil {
		log.Fatal(err)
	}
}
