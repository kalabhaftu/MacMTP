package mtp

import (
	"github.com/ganeshrvel/usb"
	"testing"
)

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
