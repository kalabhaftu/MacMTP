package mtp

import "testing"

func TestSelectorMatchesIdentity(t *testing.T) {
	selector := DeviceSelector{VendorID: 0x1234, ProductID: 0x5678, SerialNumber: "phone"}
	if !selectorMatches(selector, 0x1234, 0x5678, "phone") {
		t.Fatal("expected exact selector match")
	}
	if selectorMatches(selector, 0x1234, 0x5678, "other") {
		t.Fatal("rejected serial should not match")
	}
	if selectorMatches(selector, 0x1234, 0x5679, "phone") {
		t.Fatal("rejected product should not match")
	}
}

func TestSelectorAllowsMissingSerial(t *testing.T) {
	selector := DeviceSelector{VendorID: 0x1234, ProductID: 0x5678}
	if !selectorMatches(selector, 0x1234, 0x5678, "phone") {
		t.Fatal("missing selector serial should match the VID/PID candidate")
	}
}
