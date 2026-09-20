package mtp

import (
	"fmt"
	"github.com/ganeshrvel/usb"
	"testing"
)

func TestUSBClaimErrorClassification(t *testing.T) {
	if !isUSBClaimError(fmt.Errorf("LIBUSB_ERROR_ACCESS")) {
		t.Fatal("access failure should trigger claimant recovery")
	}
	if isUSBClaimError(fmt.Errorf("interface does not identify MTP")) {
		t.Fatal("interface rejection should remain a normal non-MTP candidate")
	}
}

func TestMTPDeviceDescriptorRejectsCameraClass(t *testing.T) {
	if isMTPDeviceDescriptor(usb.DeviceDescriptor{DeviceClass: 0xef}) {
		t.Fatal("composite camera device must not qualify as an MTP device")
	}
	if !isMTPDeviceDescriptor(usb.DeviceDescriptor{DeviceClass: usb.CLASS_PER_INTERFACE}) {
		t.Fatal("per-interface MTP device should qualify")
	}
}

func TestHasMTPDataEndpointsRejectsMouseShape(t *testing.T) {
	endpoints := []usb.EndpointDescriptor{{
		EndpointAddress: 0x81,
		Attributes:      usb.TRANSFER_TYPE_INTERRUPT,
	}}
	if hasMTPDataEndpoints(endpoints) {
		t.Fatal("interrupt-only device must not be treated as MTP")
	}
}

func TestHasMTPDataEndpointsAcceptsMTPShape(t *testing.T) {
	endpoints := []usb.EndpointDescriptor{
		{EndpointAddress: 0x81, Attributes: usb.TRANSFER_TYPE_BULK},
		{EndpointAddress: 0x02, Attributes: usb.TRANSFER_TYPE_BULK},
		{EndpointAddress: 0x83, Attributes: usb.TRANSFER_TYPE_INTERRUPT},
	}
	if !hasMTPDataEndpoints(endpoints) {
		t.Fatal("MTP bulk-in, bulk-out, interrupt-in endpoints should qualify")
	}
}

func TestMTPInterfaceStringValidation(t *testing.T) {
	if isMTPInterfaceString("Lenovo USB Optical Mouse") {
		t.Fatal("mouse interface must not qualify as MTP")
	}
	if !isMTPInterfaceString("MTP") {
		t.Fatal("MTP interface should qualify")
	}
}
