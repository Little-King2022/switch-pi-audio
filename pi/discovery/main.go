package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	bluez        = "org.bluez"
	adapterIFace = "org.bluez.Adapter1"
	managerIFace = "org.bluez.AgentManager1"
	propsIFace   = "org.freedesktop.DBus.Properties"
	sinkUUID     = "0000110b-0000-1000-8000-00805f9b34fb"
	agentPath    = dbus.ObjectPath("/org/switchaudio/Agent")
)

type agent struct {
	peer       dbus.ObjectPath
	owner      atomic.Value
	registered atomic.Bool
}

func reject() *dbus.Error {
	return dbus.NewError("org.bluez.Error.Rejected", []any{"Pairing or service not authorized"})
}

func (a *agent) authorize(sender dbus.Sender, device dbus.ObjectPath) *dbus.Error {
	if sender == "" || a.owner.Load() != string(sender) || device != a.peer {
		return reject()
	}
	return nil
}

func (a *agent) RequestAuthorization(sender dbus.Sender, device dbus.ObjectPath) *dbus.Error {
	return a.authorize(sender, device)
}

func (a *agent) AuthorizeService(sender dbus.Sender, device dbus.ObjectPath, uuid string) *dbus.Error {
	if err := a.authorize(sender, device); err != nil {
		return err
	}
	switch strings.ToLower(uuid) {
	case "0000110a-0000-1000-8000-00805f9b34fb", sinkUUID,
		"0000110c-0000-1000-8000-00805f9b34fb",
		"0000110d-0000-1000-8000-00805f9b34fb",
		"0000110e-0000-1000-8000-00805f9b34fb",
		"0000110f-0000-1000-8000-00805f9b34fb":
		return nil
	default:
		return reject()
	}
}

func (a *agent) RequestConfirmation(sender dbus.Sender, device dbus.ObjectPath, _ uint32) *dbus.Error {
	return a.authorize(sender, device)
}

func (a *agent) RequestPinCode(_ dbus.ObjectPath) (string, *dbus.Error) {
	return "", reject()
}

func (a *agent) RequestPasskey(_ dbus.ObjectPath) (uint32, *dbus.Error) {
	return 0, reject()
}

func (a *agent) DisplayPinCode(sender dbus.Sender, device dbus.ObjectPath, _ string) *dbus.Error {
	return a.authorize(sender, device)
}

func (a *agent) DisplayPasskey(sender dbus.Sender, device dbus.ObjectPath, _ uint32, _ uint16) *dbus.Error {
	return a.authorize(sender, device)
}

func (a *agent) Cancel(sender dbus.Sender) *dbus.Error {
	if sender == "" || a.owner.Load() != string(sender) {
		return reject()
	}
	return nil
}

func (a *agent) Release(sender dbus.Sender) *dbus.Error {
	if err := a.Cancel(sender); err != nil {
		return err
	}
	a.registered.Store(false)
	return nil
}

type config struct {
	adapter dbus.ObjectPath
	peer    dbus.ObjectPath
	name    string
}

func configure(ctx context.Context, conn *dbus.Conn, a *agent, config config) error {
	var owner string
	if err := conn.BusObject().CallWithContext(ctx, "org.freedesktop.DBus.GetNameOwner", 0, bluez).Store(&owner); err != nil {
		return fmt.Errorf("waiting for BlueZ: %w", err)
	}
	if a.owner.Load() != owner {
		a.registered.Store(false)
		a.owner.Store(owner)
	}
	controller := conn.Object(owner, config.adapter)
	var properties map[string]dbus.Variant
	if err := controller.CallWithContext(ctx, propsIFace+".GetAll", 0, adapterIFace).Store(&properties); err != nil {
		return fmt.Errorf("waiting for the onboard Bluetooth controller: %w", err)
	}
	if properties["Powered"].Value() != true {
		if err := set(ctx, controller, "Powered", true); err != nil {
			return err
		}
	}
	uuids, _ := properties["UUIDs"].Value().([]string)
	if !slices.Contains(uuids, sinkUUID) {
		return errors.New("waiting for the A2DP Sink endpoint")
	}

	if !a.registered.Load() {
		manager := conn.Object(owner, "/org/bluez")
		call := manager.CallWithContext(ctx, managerIFace+".RegisterAgent", 0, agentPath, "NoInputNoOutput")
		var dbusError dbus.Error
		if call.Err != nil && (!errors.As(call.Err, &dbusError) || dbusError.Name != "org.bluez.Error.AlreadyExists") {
			return fmt.Errorf("register pairing agent: %w", call.Err)
		}
		if err := manager.CallWithContext(ctx, managerIFace+".RequestDefaultAgent", 0, agentPath).Err; err != nil {
			return fmt.Errorf("set default pairing agent: %w", err)
		}
		a.registered.Store(true)
	}

	for _, setting := range []struct {
		key   string
		value any
	}{
		{"Alias", config.name},
		{"DiscoverableTimeout", uint32(0)},
		{"PairableTimeout", uint32(0)},
		{"Pairable", true},
		{"Discoverable", true},
	} {
		if properties[setting.key].Value() != setting.value {
			if err := set(ctx, controller, setting.key, setting.value); err != nil {
				return err
			}
		}
	}
	return nil
}

func set(ctx context.Context, controller dbus.BusObject, key string, value any) error {
	if err := controller.CallWithContext(ctx, propsIFace+".Set", 0, adapterIFace, key, dbus.MakeVariant(value)).Err; err != nil {
		return fmt.Errorf("set %s: %w", key, err)
	}
	return nil
}

func serve(ctx context.Context, conn *dbus.Conn, config config) error {
	a := &agent{peer: config.peer}
	if err := conn.Export(a, agentPath, "org.bluez.Agent1"); err != nil {
		return err
	}

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	last := ""
	for {
		callCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err := configure(callCtx, conn, a, config)
		cancel()
		message := "discoverable as " + config.name + "; pairing restricted to the configured Switch"
		if err != nil {
			message = err.Error()
		}
		if message != last {
			log.Print(message)
			last = message
		}

		select {
		case <-ticker.C:
		case <-conn.Context().Done():
			return errors.New("system D-Bus disconnected")
		case <-ctx.Done():
			stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if owner, ok := a.owner.Load().(string); ok {
				controller := conn.Object(owner, config.adapter)
				_ = set(stopCtx, controller, "Discoverable", false)
				_ = set(stopCtx, controller, "Pairable", false)
			}
			return nil
		}
	}
}

func main() {
	adapter := flag.String("adapter", "hci0", "BlueZ adapter")
	name := flag.String("name", "Switch-Pi-Audio", "discoverable Bluetooth name")
	peer := flag.String("peer", "", "only Bluetooth address allowed to pair")
	flag.Parse()

	address, err := net.ParseMAC(*peer)
	if err != nil || len(address) != 6 || !regexp.MustCompile("^hci[0-9]+$").MatchString(*adapter) ||
		*name == "" || len(*name) > 248 {
		log.Fatal("invalid adapter, name or allowed peer")
	}
	adapterPath := dbus.ObjectPath("/org/bluez/" + *adapter)
	peerName := strings.ReplaceAll(strings.ToUpper(address.String()), ":", "_")
	cfg := config{adapter: adapterPath, peer: adapterPath + dbus.ObjectPath("/dev_"+peerName), name: *name}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	for ctx.Err() == nil {
		conn, err := dbus.ConnectSystemBus()
		if err == nil {
			err = serve(ctx, conn, cfg)
			conn.Close()
		}
		if err != nil {
			log.Print(err)
		}

		select {
		case <-ctx.Done():
		case <-time.After(2 * time.Second):
		}
	}
}
