package mtp

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/ganeshrvel/usb"
)

type DeviceSelector struct {
	VendorID     uint16
	ProductID    uint16
	SerialNumber string
	Manufacturer string
	Model        string
}

func DiscoverDeviceSelectors() ([]DeviceSelector, error) {
	return discoverDeviceSelectors(nil)
}

// DiscoverDeviceSelectorsExcept probes available MTP devices without touching
// the supplied active handle. Discovery runs while the app keeps one session
// open; probing that same USB address can otherwise steal its interface.
func DiscoverDeviceSelectorsExcept(skip *Device) ([]DeviceSelector, error) {
	return discoverDeviceSelectors(skip)
}

func discoverDeviceSelectors(skip *Device) ([]DeviceSelector, error) {
	c := usb.NewContext()
	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}

	seen := make(map[string]struct{})
	openedVIDPIDs := make(map[string]struct{})
	failedFallbacks := make(map[string]DeviceSelector)
	selectors := make([]DeviceSelector, 0, len(devs))
	var claimError error
	var probeError error
	for _, candidate := range devs {
		if skip != nil && sameUSBDevice(candidate, skip) {
			candidate.Done()
			continue
		}
		candidate.MTPDebug = false
		candidate.USBDebug = false
		candidate.DataDebug = false
		if err := candidate.Open(); err != nil {
			if probeError == nil {
				probeError = err
			}
			if isUSBClaimError(err) {
				claimError = err
			}
			selector := DeviceSelector{
				VendorID:  candidate.devDescr.IdVendor,
				ProductID: candidate.devDescr.IdProduct,
			}
			failedFallbacks[fmt.Sprintf("%04x:%04x", selector.VendorID, selector.ProductID)] = selector
			candidate.Done()
			continue
		}
		info, err := candidate.GetUsbInfo()
		candidate.Close()
		candidate.Done()
		if err != nil {
			if probeError == nil {
				probeError = err
			}
			selector := DeviceSelector{
				VendorID:  candidate.devDescr.IdVendor,
				ProductID: candidate.devDescr.IdProduct,
			}
			failedFallbacks[fmt.Sprintf("%04x:%04x", selector.VendorID, selector.ProductID)] = selector
			continue
		}
		selector := DeviceSelector{
			VendorID:     info.IdVendor,
			ProductID:    info.IdProduct,
			SerialNumber: info.SerialNumber,
			Manufacturer: info.Manufacturer,
			Model:        info.Product,
		}
		openedVIDPIDs[fmt.Sprintf("%04x:%04x", selector.VendorID, selector.ProductID)] = struct{}{}
		key := fmt.Sprintf("%04x:%04x:%s", selector.VendorID, selector.ProductID, selector.SerialNumber)
		if _, exists := seen[key]; !exists {
			seen[key] = struct{}{}
			selectors = append(selectors, selector)
		}
	}
	for vidPID, selector := range failedFallbacks {
		if _, opened := openedVIDPIDs[vidPID]; !opened {
			selectors = append(selectors, selector)
		}
	}
	if len(selectors) == 0 && claimError != nil {
		return nil, fmt.Errorf("MTP interface probe failed: %w", claimError)
	}
	if len(selectors) == 0 && probeError != nil {
		return nil, fmt.Errorf("MTP interface probe failed: %w", probeError)
	}
	return selectors, nil
}

func sameUSBDevice(lhs, rhs *Device) bool {
	if lhs == nil || rhs == nil || lhs.dev == nil || rhs.dev == nil {
		return false
	}
	return lhs.dev.GetBusNumber() == rhs.dev.GetBusNumber() &&
		lhs.dev.GetDeviceAddress() == rhs.dev.GetDeviceAddress()
}

func isUSBClaimError(err error) bool {
	details := strings.ToUpper(err.Error())
	return strings.Contains(details, "LIBUSB_ERROR_ACCESS") ||
		strings.Contains(details, "LIBUSB_ERROR_BUSY") ||
		strings.Contains(details, "LIBUSB_ERROR_NOT_FOUND") ||
		strings.Contains(details, "LIBUSB_ERROR_NO_DEVICE") ||
		strings.Contains(details, "LIBUSB_ERROR_TIMEOUT")
}

func isMTPDeviceDescriptor(descriptor usb.DeviceDescriptor) bool {
	return descriptor.DeviceClass == usb.CLASS_PER_INTERFACE
}

func selectorMatches(selector DeviceSelector, vendorID, productID uint16, serialNumber string) bool {
	if selector.VendorID != vendorID || selector.ProductID != productID {
		return false
	}
	return selector.SerialNumber == "" || selector.SerialNumber == serialNumber
}

func hasMTPDataEndpoints(endpoints []usb.EndpointDescriptor) bool {
	var event, inbound, outbound bool
	for _, endpoint := range endpoints {
		switch {
		case endpoint.Direction() == usb.ENDPOINT_IN && endpoint.TransferType() == usb.TRANSFER_TYPE_INTERRUPT:
			event = true
		case endpoint.Direction() == usb.ENDPOINT_IN && endpoint.TransferType() == usb.TRANSFER_TYPE_BULK:
			inbound = true
		case endpoint.Direction() == usb.ENDPOINT_OUT && endpoint.TransferType() == usb.TRANSFER_TYPE_BULK:
			outbound = true
		}
	}
	return event && inbound && outbound
}

func candidateFromDeviceDescriptor(d *usb.Device) *Device {
	dd, err := d.GetDeviceDescriptor()
	if err != nil {
		return nil
	}
	if !isMTPDeviceDescriptor(*dd) {
		return nil
	}
	for i := byte(0); i < dd.NumConfigurations; i++ {
		cdecs, err := d.GetConfigDescriptor(i)
		if err != nil {
			return nil
		}
		for _, iface := range cdecs.Interfaces {
			for _, a := range iface.AltSetting {
				if len(a.EndPoints) != 3 || !hasMTPDataEndpoints(a.EndPoints) {
					continue
				}
				m := Device{}
				for _, s := range a.EndPoints {
					switch {
					case s.Direction() == usb.ENDPOINT_IN && s.TransferType() == usb.TRANSFER_TYPE_INTERRUPT:
						m.eventEP = s.EndpointAddress
					case s.Direction() == usb.ENDPOINT_IN && s.TransferType() == usb.TRANSFER_TYPE_BULK:
						m.fetchEP = s.EndpointAddress
					case s.Direction() == usb.ENDPOINT_OUT && s.TransferType() == usb.TRANSFER_TYPE_BULK:
						m.sendEP = s.EndpointAddress
					}
				}
				if m.sendEP > 0 && m.fetchEP > 0 && m.eventEP > 0 {
					m.devDescr = *dd
					m.ifaceDescr = a
					m.dev = d.Ref()
					m.configValue = cdecs.ConfigurationValue
					return &m
				}
			}
		}
	}

	return nil
}

// FindDevices finds likely MTP devices without opening them.
func FindDevices(c *usb.Context) ([]*Device, error) {
	l, err := c.GetDeviceList()
	if err != nil {
		return nil, err
	}

	var cands []*Device
	for _, d := range l {
		cand := candidateFromDeviceDescriptor(d)
		if cand != nil {
			cands = append(cands, cand)
		}
	}

	if len(l) > 0 {
		l.Done()
	}

	return cands, nil
}

// selectDevice finds a device that matches given pattern
func selectDevice(cands []*Device, pattern string) (*Device, error) {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return nil, err
	}

	var found []*Device
	for _, cand := range cands {
		if err := cand.Open(); err != nil {
			cand.Done()
			continue
		}

		found = append(found, cand)
	}

	if len(found) == 0 {
		return nil, fmt.Errorf("no MTP devices found")
	}

	cands = found
	found = nil
	var ids []string
	for i, cand := range cands {
		id, err := cand.ID()
		if err != nil {
			for _, c := range cands {
				c.Close()
				c.Done()
			}
			return nil, fmt.Errorf("Id dev %d: %v", i, err)
		}

		if pattern == "" || re.FindString(id) != "" {
			found = append(found, cand)
			ids = append(ids, id)
		} else {
			cand.Close()
			cand.Done()
		}
	}

	if len(found) == 0 {
		return nil, fmt.Errorf("no device matched")
	}

	if len(found) > 1 {
		for _, cand := range found {
			cand.Close()
			cand.Done()
		}
		return nil, fmt.Errorf("mtp: more than 1 device: %s", strings.Join(ids, ","))
	}

	cand := found[0]
	config, err := cand.h.GetConfiguration()
	if err != nil {
		cand.Close()
		cand.Done()
		return nil, fmt.Errorf("could not get configuration of %v: %v",
			ids[0], err)
	}
	if config != cand.configValue {
		if err := cand.h.SetConfiguration(cand.configValue); err != nil {
			cand.Close()
			cand.Done()
			return nil, fmt.Errorf("could not set configuration of %v: %v",
				ids[0], err)
		}
	}
	return found[0], nil
}

func SelectDeviceWithSelector(selector DeviceSelector, allowDebugging bool) (*Device, error) {
	c := usb.NewContext()
	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	if len(devs) == 0 {
		return nil, fmt.Errorf("no MTP devices found")
	}

	var matching []*Device
	var matchingError error
	for _, candidate := range devs {
		if candidate.devDescr.IdVendor != selector.VendorID || candidate.devDescr.IdProduct != selector.ProductID {
			candidate.Done()
			continue
		}
		candidate.USBDebug = allowDebugging
		candidate.DataDebug = allowDebugging
		candidate.MTPDebug = allowDebugging
		if err := candidate.Open(); err != nil {
			if matchingError == nil {
				matchingError = err
			}
			candidate.Done()
			continue
		}
		if selector.SerialNumber != "" {
			info, infoErr := candidate.GetUsbInfo()
			if infoErr != nil {
				if matchingError == nil {
					matchingError = infoErr
				}
				candidate.Close()
				candidate.Done()
				continue
			}
			if !selectorMatches(selector, info.IdVendor, info.IdProduct, info.SerialNumber) {
				candidate.Close()
				candidate.Done()
				continue
			}
		}
		matching = append(matching, candidate)
	}

	if len(matching) == 0 && matchingError != nil {
		return nil, fmt.Errorf("opening MTP device vendor=0x%04x product=0x%04x: %w", selector.VendorID, selector.ProductID, matchingError)
	}
	if len(matching) == 0 {
		return nil, fmt.Errorf("no MTP device matched vendor=0x%04x product=0x%04x", selector.VendorID, selector.ProductID)
	}
	if len(matching) > 1 {
		for _, candidate := range matching {
			candidate.Close()
			candidate.Done()
		}
		return nil, fmt.Errorf("more than one MTP device matched vendor=0x%04x product=0x%04x", selector.VendorID, selector.ProductID)
	}

	candidate := matching[0]
	config, err := candidate.h.GetConfiguration()
	if err != nil {
		candidate.Close()
		candidate.Done()
		return nil, fmt.Errorf("could not get configuration: %w", err)
	}
	if config != candidate.configValue {
		if err := candidate.h.SetConfiguration(candidate.configValue); err != nil {
			candidate.Close()
			candidate.Done()
			return nil, fmt.Errorf("could not set configuration: %w", err)
		}
	}
	return candidate, nil
}

// SelectDevice returns opened MTP device that matches the given pattern.
func SelectDevice(pattern string) (*Device, error) {
	c := usb.NewContext()

	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	if len(devs) == 0 {
		return nil, fmt.Errorf("no MTP devices found")
	}

	return selectDevice(devs, pattern)
}

// SelectDeviceForDebugging returns opened MTP device that matches the given pattern and debug information are set true
func SelectDeviceWithDebugging(pattern string, allowDebugging bool) (*Device, error) {
	c := usb.NewContext()

	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	if len(devs) == 0 {
		return nil, fmt.Errorf("no MTP devices found")
	}

	if allowDebugging {
		for _, _dev := range devs {
			_dev.USBDebug = allowDebugging
			_dev.DataDebug = allowDebugging
			_dev.MTPDebug = allowDebugging
		}
	}

	return selectDevice(devs, pattern)
}
