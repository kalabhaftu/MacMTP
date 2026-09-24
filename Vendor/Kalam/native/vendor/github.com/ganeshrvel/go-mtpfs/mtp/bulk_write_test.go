package mtp

import (
	"bytes"
	"reflect"
	"testing"
)

func TestWriteUSBPacketSendsZeroLengthPacket(t *testing.T) {
	calls := 0
	gotLength := -1
	written, err := writeUSBPacket(func(packet []byte) (int, error) {
		calls++
		gotLength = len(packet)
		return 0, nil
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if written != 0 || calls != 1 || gotLength != 0 {
		t.Fatalf("zero-length write = written %d, calls %d, length %d; want 0, 1, 0", written, calls, gotLength)
	}
}

func TestWriteUSBPacketHandlesPartialWrites(t *testing.T) {
	var calls []int
	written, err := writeUSBPacket(func(packet []byte) (int, error) {
		calls = append(calls, len(packet))
		if len(packet) > 2 {
			return 2, nil
		}
		return len(packet), nil
	}, bytes.Repeat([]byte{1}, 5))
	if err != nil {
		t.Fatal(err)
	}
	if written != 5 {
		t.Fatalf("written %d, want 5", written)
	}
	if !reflect.DeepEqual(calls, []int{5, 3, 1}) {
		t.Fatalf("partial-write calls %v, want [5 3 1]", calls)
	}
}

func TestWriteUSBPacketRejectsUnexpectedZeroLengthCount(t *testing.T) {
	if _, err := writeUSBPacket(func([]byte) (int, error) { return 1, nil }, nil); err == nil {
		t.Fatal("expected non-zero zero-length write to fail")
	}
}
