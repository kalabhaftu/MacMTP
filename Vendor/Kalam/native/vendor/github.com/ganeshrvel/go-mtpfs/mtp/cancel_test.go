package mtp

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/ganeshrvel/usb"
)

func TestCancelRequestDataUsesCurrentTransaction(t *testing.T) {
	want := []byte{0x01, 0x40, 0x78, 0x56, 0x34, 0x12}
	if got := cancelRequestData(0x12345678); !bytes.Equal(got, want) {
		t.Fatalf("cancel request = %x, want %x", got, want)
	}
}

func TestCancelStatusSequenceReachesOK(t *testing.T) {
	statuses := []uint16{RC_DeviceBusy, RC_TransactionCanceled, RC_OK}
	index := 0
	cleared := 0
	verified := false
	var events []string
	err := awaitCancelRecovery(
		func() error {
			events = append(events, "drain")
			return nil
		},
		func() (uint16, error) {
			events = append(events, "status")
			status := statuses[index]
			index++
			return status, nil
		},
		func() error {
			events = append(events, "clear")
			cleared++
			return nil
		},
		func() error {
			events = append(events, "verify")
			verified = true
			return nil
		},
		time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	if cleared != 1 {
		t.Fatalf("cleared halts %d times, want 1", cleared)
	}
	if !verified {
		t.Fatal("session verification did not run")
	}
	wantEvents := []string{"drain", "status", "status", "clear", "status", "verify"}
	if !bytes.Equal([]byte(strings.Join(events, ",")), []byte(strings.Join(wantEvents, ","))) {
		t.Fatalf("recovery order = %v, want %v", events, wantEvents)
	}
}

func TestDeviceStatusRejectsMalformedUnexpectedAndTimeout(t *testing.T) {
	if _, err := parseDeviceStatus([]byte{3, 0, 1, 32}); err == nil {
		t.Fatal("short declared device status should fail")
	}
	if _, _, err := cancelStatusAction(RC_GeneralError); err == nil {
		t.Fatal("unexpected device status should fail")
	}
	if err := awaitCancelRecovery(
		func() error { return nil },
		func() (uint16, error) { return RC_DeviceBusy, nil },
		func() error { return nil },
		func() error { return nil },
		0,
	); err == nil {
		t.Fatal("cancel recovery timeout should fail")
	}
}

func TestCancelRecoveryStopsBeforeStatusWhenDrainFails(t *testing.T) {
	statusReads := 0
	err := awaitCancelRecovery(
		func() error { return fmt.Errorf("bulk pipe stalled") },
		func() (uint16, error) {
			statusReads++
			return RC_OK, nil
		},
		func() error { return nil },
		func() error { return nil },
		time.Second,
	)
	if err == nil || !strings.Contains(err.Error(), "drain stale USB data") {
		t.Fatalf("drain failure = %v", err)
	}
	if statusReads != 0 {
		t.Fatalf("status reads = %d, want 0 after drain failure", statusReads)
	}
}

func TestDrainTimeoutWithReceivedBytesIsNotMistakenForIdle(t *testing.T) {
	_, err := drainUntilIdle(0x81, 1, time.Millisecond, time.Millisecond, func(byte, []byte, int) (int, error) {
		return 1, usb.ERROR_TIMEOUT
	})
	if err == nil || !strings.Contains(err.Error(), "did not become idle") {
		t.Fatalf("drain result = %v, want bounded failure", err)
	}

	drained, err := drainUntilIdle(0x81, 1, time.Second, time.Millisecond, func(byte, []byte, int) (int, error) {
		return 0, usb.ERROR_TIMEOUT
	})
	if err != nil || drained != 0 {
		t.Fatalf("idle drain = (%d, %v), want (0, nil)", drained, err)
	}
}

func TestClearEndpointHaltsAttemptsBothEndpoints(t *testing.T) {
	var endpoints []byte
	err := clearEndpointHalts(func(endpoint byte) error {
		endpoints = append(endpoints, endpoint)
		if endpoint == 0x82 {
			return fmt.Errorf("in halt")
		}
		return nil
	}, 0x01, 0x82)
	if err == nil {
		t.Fatal("expected first endpoint error")
	}
	if !bytes.Equal(endpoints, []byte{0x01, 0x82}) {
		t.Fatalf("cleared endpoints = %x, want 01 82", endpoints)
	}
}

func TestCancelRecoveryVerificationFailureIsNotSuccess(t *testing.T) {
	err := awaitCancelRecovery(
		func() error { return nil },
		func() (uint16, error) { return RC_OK, nil },
		func() error { return nil },
		func() error { return fmt.Errorf("got stale response container") },
		time.Second,
	)
	if err == nil || !strings.Contains(err.Error(), "verify MTP session") {
		t.Fatalf("verification failure = %v", err)
	}
}

func TestStandardPartialObjectRequestUsesStandardOpcode(t *testing.T) {
	req := partialObjectRequest(7, 11, 13)
	if req.Code != OC_GetPartialObject {
		t.Fatalf("opcode = 0x%x, want 0x%x", req.Code, OC_GetPartialObject)
	}
	want := []uint32{7, 11, 13}
	if fmt.Sprint(req.Param) != fmt.Sprint(want) {
		t.Fatalf("params = %v, want %v", req.Param, want)
	}
}
