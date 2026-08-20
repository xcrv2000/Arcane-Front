package main

import (
	"testing"
	"time"
)

func TestRoomCanStartOnlyAfterCountdownWithBothReady(t *testing.T) {
	now := time.Now()
	room := &Room{
		Host:    &Client{Ready: true},
		Guest:   &Client{Ready: true},
		StartAt: now.Add(3 * time.Second),
	}
	if room.canStart(now.Add(2999 * time.Millisecond)) {
		t.Fatal("room started before the three-second countdown elapsed")
	}
	if !room.canStart(now.Add(3 * time.Second)) {
		t.Fatal("room did not become startable after the countdown elapsed")
	}

	room.Guest.Ready = false
	if room.canStart(now.Add(4 * time.Second)) {
		t.Fatal("room started after one player cancelled ready")
	}
	room.Guest.Ready = true
	room.Guest.Disconnected = true
	if room.canStart(now.Add(4 * time.Second)) {
		t.Fatal("room started while one player was disconnected")
	}
}
