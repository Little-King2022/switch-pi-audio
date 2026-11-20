package main

import (
	"github.com/godbus/dbus/v5"
	"testing"
)

func TestAgentAllowsOnlyConfiguredAudioPeerFromBlueZ(t *testing.T) {
	peer := dbus.ObjectPath("/org/bluez/hci0/dev_00_11_22_33_44_55")
	a := &agent{peer: peer}
	a.owner.Store(":1.42")
	if err := a.RequestAuthorization(":1.42", peer); err != nil {
		t.Fatal("configured peer was rejected")
	}
	if err := a.AuthorizeService(":1.42", peer, sinkUUID); err != nil {
		t.Fatal("configured audio endpoint was rejected")
	}
	if err := a.RequestAuthorization(":1.99", peer); err == nil {
		t.Fatal("an unrelated D-Bus sender was authorized")
	}
	if err := a.RequestAuthorization(":1.42", "/org/bluez/hci0/dev_00_11_22_33_44_66"); err == nil {
		t.Fatal("an unrelated Bluetooth device was authorized")
	}
	if err := a.AuthorizeService(":1.42", peer, "00001105-0000-1000-8000-00805f9b34fb"); err == nil {
		t.Fatal("a file-transfer profile was authorized")
	}
}
