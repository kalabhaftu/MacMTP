package mtp

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

	"github.com/ganeshrvel/usb"
)

// An MTP device.
type Device struct {
	h   *usb.DeviceHandle
	dev *usb.Device

	claimed bool

	// split off descriptor?
	devDescr    usb.DeviceDescriptor
	ifaceDescr  usb.InterfaceDescriptor
	sendEP      byte
	fetchEP     byte
	eventEP     byte
	configValue byte

	// In milliseconds. Defaults to 2 seconds.
	Timeout int

	// Print request/response codes.
	MTPDebug bool

	// Print USB calls.
	USBDebug bool

	// Print data as it passes over the USB connection.
	DataDebug bool

	// If set, send header in separate write.
	SeparateHeader bool

	session *sessionData
}

type UsbDeviceInfo struct {
	// USB-IF vendor ID.
	IdVendor uint16
	// USB-IF product ID.
	IdProduct uint16
	// Device release number in binary-coded decimal.
	Device uint16

	// Index of string descriptor describing manufacturer.
	Manufacturer string
	// Index of string descriptor describing product.
	Product string
	// Index of string descriptor containing device serial number.
	SerialNumber string
}

type sessionData struct {
	tid uint32
	sid uint32
}

// ErrTransferCancelled is returned by progress callbacks when the host asks
// the current data phase to stop.
var ErrTransferCancelled = errors.New("transfer cancelled")

const (
	mtpRequestCancel          = 0x64
	mtpRequestReset           = 0x66
	mtpRequestGetDeviceStatus = 0x67
	cancelDrainIdleTimeout    = 300 * time.Millisecond
	cancelDrainMaxDuration    = 2 * time.Second
	cancelRecoveryTimeout     = 2 * time.Second
	cancelRecoveryPollDelay   = 50 * time.Millisecond
)

func isMTPInterfaceString(value string) bool {
	return strings.Contains(value, "MTP") || strings.Contains(value, "CDC") || strings.Contains(value, "ACM")
}

// RCError are return codes from the Container.Code field.
type RCError uint16

func (e RCError) Error() string {
	n, ok := RC_names[int(e)]
	if ok {
		return n
	}
	return fmt.Sprintf("RetCode %x", uint16(e))
}

func (d *Device) fetchMaxPacketSize() int {
	return d.dev.GetMaxPacketSize(d.fetchEP)
}

func (d *Device) sendMaxPacketSize() int {
	return d.dev.GetMaxPacketSize(d.sendEP)
}

// empty placeholder function for progress callback
func EmptyProgressFunc(_ int64) error {
	return nil
}

// Close releases the interface, and closes the device.
func (d *Device) Close() error {
	if d.h == nil {
		return nil // or error?
	}

	if d.session != nil {
		var req, rep Container
		req.Code = OC_CloseSession
		// RunTransaction runs close, so can't use CloseSession().

		if err := d.runTransaction(&req, &rep, nil, nil, 0, EmptyProgressFunc); err != nil {
			err := d.h.Reset()
			if d.USBDebug {
				log.Printf("USB: Reset, err: %v", err)
			}
		}
	}

	if d.claimed {
		err := d.h.ReleaseInterface(d.ifaceDescr.InterfaceNumber)
		if d.USBDebug {
			log.Printf("USB: ReleaseInterface 0x%x, err: %v", d.ifaceDescr.InterfaceNumber, err)
		}
		d.claimed = false
	}
	err := d.h.Close()
	d.h = nil

	if d.USBDebug {
		log.Printf("USB: Close, err: %v", err)
	}
	return err
}

// Abort closes a broken transport without resetting the physical USB bus.
func (d *Device) Abort() error {
	if d.h != nil {
		if err := d.h.ClearHalt(d.sendEP); err != nil && d.USBDebug {
			log.Printf("USB: ClearHalt(sendEP) after abort, err: %v", err)
		}
		if err := d.h.ClearHalt(d.fetchEP); err != nil && d.USBDebug {
			log.Printf("USB: ClearHalt(fetchEP) after abort, err: %v", err)
		}
	}
	d.session = nil
	return d.Close()
}

func cancelRequestData(transactionID uint32) []byte {
	data := make([]byte, 6)
	byteOrder.PutUint16(data, EC_CancelTransaction)
	byteOrder.PutUint32(data[2:], transactionID)
	return data
}

func parseDeviceStatus(data []byte) (uint16, error) {
	if len(data) < 4 {
		return 0, fmt.Errorf("short device status: %d bytes", len(data))
	}
	length := int(byteOrder.Uint16(data))
	if length < 4 || length > len(data) {
		return 0, fmt.Errorf("invalid device status length %d", length)
	}
	return byteOrder.Uint16(data[2:4]), nil
}

func cancelStatusAction(status uint16) (done, clearHalts bool, err error) {
	switch status {
	case RC_OK:
		return true, false, nil
	case RC_DeviceBusy:
		return false, false, nil
	case RC_TransactionCanceled:
		return false, true, nil
	default:
		return false, false, fmt.Errorf("unexpected device status 0x%04x", status)
	}
}

func clearEndpointHalts(clearHalt func(byte) error, endpoints ...byte) error {
	var firstErr error
	for _, endpoint := range endpoints {
		if err := clearHalt(endpoint); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("clear bulk endpoint 0x%x halt: %w", endpoint, err)
		}
	}
	return firstErr
}

func awaitCancelRecovery(
	drain func() error,
	readStatus func() (uint16, error),
	clearHalts func() error,
	verify func() error,
	timeout time.Duration,
) error {
	if err := drain(); err != nil {
		return fmt.Errorf("drain stale USB data: %w", err)
	}

	deadline := time.Now().Add(timeout)
	var lastError error
	for time.Now().Before(deadline) {
		status, err := readStatus()
		if err != nil {
			lastError = err
			time.Sleep(cancelRecoveryPollDelay)
			continue
		}
		done, shouldClearHalts, err := cancelStatusAction(status)
		if err != nil {
			return err
		}
		if shouldClearHalts {
			if err := clearHalts(); err != nil {
				return err
			}
		}
		if done {
			if verify != nil {
				if err := verify(); err != nil {
					return fmt.Errorf("verify MTP session after cancellation: %w", err)
				}
			}
			return nil
		}
		time.Sleep(cancelRecoveryPollDelay)
	}
	if lastError != nil {
		return fmt.Errorf("device status did not recover: %w", lastError)
	}
	return fmt.Errorf("device status did not return OK before timeout")
}

func (d *Device) clearBulkHalts() error {
	if d.h == nil {
		return nil
	}
	return clearEndpointHalts(d.h.ClearHalt, d.sendEP, d.fetchEP)
}

func (d *Device) drainEndpoint(endpoint byte, interrupt bool) (int64, error) {
	if d.h == nil {
		return 0, fmt.Errorf("device is not open")
	}

	packetSize := 512
	if d.dev != nil {
		if size := d.dev.GetMaxPacketSize(endpoint); size > 0 {
			packetSize = size
		}
	}
	buffer := make([]byte, packetSize)
	// Android can leave the canceled data container queued even after the
	// class status request reports OK. Drain immediately after cancellation;
	// delaying this until after GetDeviceStatus lets stale bytes poison the
	// next MTP transaction.
	deadline := time.Now().Add(cancelDrainMaxDuration)
	var drained int64

	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		timeout := cancelDrainIdleTimeout
		if remaining < timeout {
			timeout = remaining
		}
		timeoutMS := int(timeout / time.Millisecond)
		if timeoutMS < 1 {
			break
		}

		var actual int
		var err error
		if interrupt {
			actual, err = d.h.InterruptTransfer(endpoint, buffer, timeoutMS)
		} else {
			actual, err = d.h.BulkTransfer(endpoint, buffer, timeoutMS)
		}
		if err != nil {
			if err == usb.ERROR_TIMEOUT {
				drained += int64(actual)
				return drained, nil
			}
			return drained, err
		}
		if actual <= 0 {
			return drained, nil
		}
		drained += int64(actual)
	}

	return drained, nil
}

func (d *Device) drainCancelPipes() (int64, error) {
	bulkBytes, err := d.drainEndpoint(d.fetchEP, false)
	if err != nil {
		return bulkBytes, fmt.Errorf("drain bulk IN: %w", err)
	}
	eventBytes, err := d.drainEndpoint(d.eventEP, true)
	if err != nil {
		return bulkBytes + eventBytes, fmt.Errorf("drain interrupt IN: %w", err)
	}
	log.Printf("MTP transport drain completed bulk_in=%d interrupt_in=%d", bulkBytes, eventBytes)
	return bulkBytes + eventBytes, nil
}

func (d *Device) verifyTransactionSync() error {
	var data bytes.Buffer
	var req, rep Container
	req.Code = OC_GetDeviceInfo
	if err := d.runTransaction(&req, &rep, &data, nil, 0, EmptyProgressFunc); err != nil {
		return err
	}
	var info DeviceInfo
	return Decode(&data, &info)
}

func (d *Device) recoverCancelledTransaction(transactionID uint32) error {
	if d.h == nil {
		return fmt.Errorf("device is not open")
	}

	interfaceNumber := uint16(d.ifaceDescr.InterfaceNumber)
	requestType := byte(usb.REQUEST_TYPE_CLASS | usb.RECIPIENT_INTERFACE)
	if err := d.h.ControlTransfer(
		requestType,
		mtpRequestCancel,
		0,
		interfaceNumber,
		cancelRequestData(transactionID),
		d.Timeout,
	); err != nil {
		return fmt.Errorf("cancel request: %w", err)
	}

	clearHalts := func() error {
		return d.clearBulkHalts()
	}
	drain := func() error {
		_, err := d.drainCancelPipes()
		return err
	}
	statusRequestType := byte(usb.ENDPOINT_IN | usb.REQUEST_TYPE_CLASS | usb.RECIPIENT_INTERFACE)
	statusTimeout := d.Timeout
	if statusTimeout <= 0 || statusTimeout > 250 {
		statusTimeout = 250
	}
	readStatus := func() (uint16, error) {
		statusData := make([]byte, 8)
		if err := d.h.ControlTransfer(
			statusRequestType,
			mtpRequestGetDeviceStatus,
			0,
			interfaceNumber,
			statusData,
			statusTimeout,
		); err != nil {
			return 0, err
		}
		return parseDeviceStatus(statusData)
	}
	return awaitCancelRecovery(drain, readStatus, clearHalts, d.verifyTransactionSync, cancelRecoveryTimeout)
}

func (d *Device) resetTransport() error {
	if d.h == nil {
		return nil
	}
	if err := d.h.ControlTransfer(
		byte(usb.REQUEST_TYPE_CLASS|usb.RECIPIENT_INTERFACE),
		mtpRequestReset,
		0,
		uint16(d.ifaceDescr.InterfaceNumber),
		nil,
		d.Timeout,
	); err != nil {
		return err
	}
	clearErr := d.clearBulkHalts()
	_, drainErr := d.drainCancelPipes()
	if clearErr != nil {
		return clearErr
	}
	return drainErr
}

func (d *Device) recoverTransferError(transactionID uint32, err error) error {
	if !errors.Is(err, ErrTransferCancelled) {
		return err
	}
	if recoveryErr := d.recoverCancelledTransaction(transactionID); recoveryErr == nil {
		log.Printf("MTP cancellation recovery completed transaction=0x%x", transactionID)
		return ErrTransferCancelled
	} else {
		resetErr := d.resetTransport()
		d.session = nil
		_ = d.Abort()
		return SyncError(fmt.Sprintf(
			"MTP cancellation recovery failed transaction=0x%x: %v; device reset=%v",
			transactionID,
			recoveryErr,
			resetErr,
		))
	}
}

// Done releases the libusb device reference.
func (d *Device) Done() {
	d.dev.Unref()
	d.dev = nil
}

// Claims the USB interface of the device.
func (d *Device) claim() error {
	if d.h == nil {
		return fmt.Errorf("mtp: claim: device not open")
	}

	err := d.h.ClaimInterface(d.ifaceDescr.InterfaceNumber)
	if d.USBDebug {
		log.Printf("USB: ClaimInterface 0x%x, err: %v", d.ifaceDescr.InterfaceNumber, err)
	}
	if err == nil {
		d.claimed = true
	}

	return err
}

// Open opens an MTP device.
func (d *Device) Open() error {
	if d.Timeout == 0 {
		d.Timeout = 2000
	}

	if d.h != nil {
		return fmt.Errorf("already open")
	}

	var err error
	d.h, err = d.dev.Open()
	if d.USBDebug {
		log.Printf("USB: Open, err: %v", err)
	}
	if err != nil {
		return err
	}

	if err := d.claim(); err != nil {
		d.Close()
		return err
	}
	if d.ifaceDescr.AlternateSetting != 0 {
		if err := d.h.SetInterfaceAltSetting(int(d.ifaceDescr.InterfaceNumber), int(d.ifaceDescr.AlternateSetting)); err != nil {
			d.Close()
			return err
		}
	}

	if d.ifaceDescr.InterfaceStringIndex != 0 {
		iface, err := d.h.GetStringDescriptorASCII(d.ifaceDescr.InterfaceStringIndex)
		if err != nil {
			d.Close()
			return err
		}

		if d.USBDebug {
			log.Printf("USB: interface: %s", iface)
		}
		if !isMTPInterfaceString(iface) {
			d.Close()
			return fmt.Errorf("mtp: interface does not identify MTP: %q", iface)
		}

		log.Printf("MTP interface=%q class=%d subclass=%d protocol=%d", iface, d.ifaceDescr.InterfaceClass, d.ifaceDescr.InterfaceSubClass, d.ifaceDescr.InterfaceProtocol)
	}

	return nil
}

// ID is the manufacturer + product + serial
func (d *Device) ID() (string, error) {
	if d.h == nil {
		return "", fmt.Errorf("mtp: ID: device not open")
	}

	var ids []string
	for _, b := range []byte{
		d.devDescr.Manufacturer,
		d.devDescr.Product,
		d.devDescr.SerialNumber} {
		var descriptor string
		if b == 0 {
			// All three of the descriptors are optional.
			// Index of 0 means the string is not available.
			descriptor = ""
		} else {
			s, err := d.h.GetStringDescriptorASCII(b)
			if err != nil {
				if d.USBDebug {
					log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
				}
				return "", err
			}
			descriptor = s
		}

		ids = append(ids, descriptor)
	}

	return strings.Join(ids, " "), nil
}

func (d *Device) GetUsbInfo() (*UsbDeviceInfo, error) {
	if d.h == nil {
		return nil, fmt.Errorf("mtp: ID: device not open")
	}

	ui := UsbDeviceInfo{
		IdVendor:  d.devDescr.IdVendor,
		IdProduct: d.devDescr.IdProduct,
		Device:    d.devDescr.Device,
	}

	if d.devDescr.Manufacturer != 0 {
		manufacturer, err := d.h.GetStringDescriptorASCII(d.devDescr.Manufacturer)
		if err != nil {
			if d.USBDebug {
				log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
			}
			return nil, err
		}
		ui.Manufacturer = manufacturer
	} else {
		ui.Manufacturer = ""
	}

	if d.devDescr.SerialNumber != 0 {
		serialNumber, err := d.h.GetStringDescriptorASCII(d.devDescr.SerialNumber)
		if err != nil {
			if d.USBDebug {
				log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
			}
			return nil, err
		}
		ui.SerialNumber = serialNumber
	} else {
		ui.SerialNumber = ""
	}

	if d.devDescr.Product != 0 {
		product, err := d.h.GetStringDescriptorASCII(d.devDescr.Product)
		if err != nil {
			if d.USBDebug {
				log.Printf("USB: GetStringDescriptorASCII, err: %v", err)
			}
			return nil, err
		}
		ui.Product = product
	} else {
		ui.Product = ""
	}

	return &ui, nil
}

func (d *Device) sendReq(req *Container) error {
	c := usbBulkContainer{
		usbBulkHeader: usbBulkHeader{
			Length:        uint32(usbHdrLen + 4*len(req.Param)),
			Type:          USB_CONTAINER_COMMAND,
			Code:          req.Code,
			TransactionID: req.TransactionID,
		},
	}
	for i := range req.Param {
		c.Param[i] = req.Param[i]
	}

	var wData [usbBulkLen]byte
	buf := bytes.NewBuffer(wData[:0])

	binary.Write(buf, binary.LittleEndian, c.usbBulkHeader)
	if err := binary.Write(buf, binary.LittleEndian, c.Param[:len(req.Param)]); err != nil {
		return err
	}

	d.dataPrint(d.sendEP, buf.Bytes())
	_, err := d.h.BulkTransfer(d.sendEP, buf.Bytes(), d.Timeout)
	if err != nil {
		return err
	}
	return nil
}

// Fetches one USB packet. The header is split off, and the remainder is returned.
// dest should be at least 512bytes.
func (d *Device) fetchPacket(dest []byte, header *usbBulkHeader) (rest []byte, bytesRead int, err error) {
	n, err := d.h.BulkTransfer(d.fetchEP, dest[:d.fetchMaxPacketSize()], d.Timeout)
	if n > 0 {
		d.dataPrint(d.fetchEP, dest[:n])
	}

	if err != nil {
		return nil, n, err
	}

	buf := bytes.NewBuffer(dest[:n])
	if err = binary.Read(buf, binary.LittleEndian, header); err != nil {
		return nil, n, err
	}
	return buf.Bytes(), n, nil
}

func (d *Device) decodeRep(h *usbBulkHeader, rest []byte, rep *Container) error {
	if h.Type != USB_CONTAINER_RESPONSE {
		return SyncError(fmt.Sprintf("got type %d (%s) in response, want CONTAINER_RESPONSE.", h.Type, USB_names[int(h.Type)]))
	}

	rep.Code = h.Code
	rep.TransactionID = h.TransactionID

	restLen := int(h.Length) - usbHdrLen
	if restLen > len(rest) {
		return fmt.Errorf("header specified 0x%x bytes, but have 0x%x",
			restLen, len(rest))
	}
	nParam := restLen / 4
	for i := 0; i < nParam; i++ {
		rep.Param = append(rep.Param, byteOrder.Uint32(rest[4*i:]))
	}

	if rep.Code != RC_OK {
		return RCError(rep.Code)
	}
	return nil
}

// SyncError is an error type that indicates lost transaction
// synchronization in the protocol.
type SyncError string

func (s SyncError) Error() string {
	return string(s)
}

// Runs a single MTP transaction. dest and src cannot be specified at
// the same time.  The request should fill out Code and Param as
// necessary. The response is provided here, but usually only the
// return code is of interest.  If the return code is an error, this
// function will return an RCError instance.
//
// Errors that are likely to affect future transactions lead to
// closing the connection. Such errors include: invalid transaction
// IDs, USB errors (BUSY, IO, ACCESS etc.), and receiving data for
// operations that expect no data.
func (d *Device) RunTransaction(req *Container, rep *Container,
	dest io.Writer, src io.Reader, writeSize int64, progressCb ProgressFunc) error {
	if d.h == nil {
		return fmt.Errorf("mtp: cannot run operation %v, device is not open",
			OC_names[int(req.Code)])
	}
	if err := d.runTransaction(req, rep, dest, src, writeSize, progressCb); err != nil {
		_, ok2 := err.(SyncError)
		_, ok1 := err.(usb.Error)
		if ok1 || ok2 {
			operation := getName(OC_names, int(req.Code))
			log.Printf("fatal error operation=%s code=0x%x transaction=0x%x: %v; closing connection.", operation, req.Code, req.TransactionID, err)
			// Abort without a physical USB bus reset; a reset would create false
			// unplug/replug events on macOS.
			d.Abort()
		}
		return err
	}
	return nil
}

// runTransaction is like RunTransaction, but without sanity checking
// before and after the call.
func (d *Device) runTransaction(req *Container, rep *Container,
	dest io.Writer, src io.Reader, writeSize int64, progressCb ProgressFunc) error {
	var finalPacket []byte
	if d.session != nil {
		req.SessionID = d.session.sid
		req.TransactionID = d.session.tid
		d.session.tid++
	}

	if d.MTPDebug {
		log.Printf("MTP request %s %v\n", OC_names[int(req.Code)], req.Param)
	}

	if err := d.sendReq(req); err != nil {
		if d.MTPDebug {
			log.Printf("MTP sendreq failed: %v\n", err)
		}
		log.Printf("MTP operation=%s phase=command-send: %v", getName(OC_names, int(req.Code)), err)
		return err
	}

	if src != nil {
		hdr := usbBulkHeader{
			Type:          USB_CONTAINER_DATA,
			Code:          req.Code,
			Length:        uint32(writeSize),
			TransactionID: req.TransactionID,
		}

		_, err := d.bulkWrite(&hdr, src, writeSize, req, progressCb)
		if err != nil {
			err = d.recoverTransferError(req.TransactionID, err)
			log.Printf("MTP operation=%s phase=data-send: %v", getName(OC_names, int(req.Code)), err)
			return err
		}
	}
	fetchPacketSize := d.fetchMaxPacketSize()
	data := make([]byte, fetchPacketSize)
	h := &usbBulkHeader{}
	rest, n, err := d.fetchPacket(data[:], h)
	if err != nil {
		log.Printf("MTP operation=%s phase=response-read: %v", getName(OC_names, int(req.Code)), err)
		return err
	}
	var unexpectedData bool
	if h.Type == USB_CONTAINER_DATA {
		if dest == nil {
			dest = &NullWriter{}
			unexpectedData = true
			if d.MTPDebug {
				log.Printf("MTP discarding unexpected data 0x%x bytes", h.Length)
			}
		}
		if d.MTPDebug {
			log.Printf("MTP data 0x%x bytes", h.Length)
		}

		dest.Write(rest)

		if len(rest)+usbHdrLen == fetchPacketSize || uint32(n) < h.Length {
			// Special case: From appendix H in the MTP 1.1 spec, the
			// device can send a 12-byte packet followed by the rest of the
			// data in a separate packet. After that point, both parties must
			// follow the same rule.
			// To detect this, if this is the first packet of a larger container
			// data packet AND it's 12 bytes, set SeparateHeader to TRUE so we
			// correctly send data back to the receiver.
			if n == usbHdrLen && len(rest) == 0 && uint32(n) < h.Length {
				d.SeparateHeader = true
				if d.MTPDebug {
					log.Printf("Device appears to have split header/data. Switched to separate header mode.")
				}
			}

			// If this was a full packet, or if the packet wasn't full but
			// the device said it was sending more data than we received,
			// continue reading until we have a read less than a full packet.
			_, finalPacket, err = d.bulkRead(dest, progressCb)
			if err != nil {
				return d.recoverTransferError(req.TransactionID, err)
			}
		}

		h = &usbBulkHeader{}
		if len(finalPacket) > 0 {
			if d.MTPDebug {
				log.Printf("Reusing final packet")
			}
			rest = finalPacket
			finalBuf := bytes.NewBuffer(finalPacket[:len(finalPacket)])
			err = binary.Read(finalBuf, binary.LittleEndian, h)
		} else {
			rest, _, err = d.fetchPacket(data[:], h)
		}
	}

	err = d.decodeRep(h, rest, rep)
	if d.MTPDebug {
		log.Printf("MTP response %s %v", getName(RC_names, int(rep.Code)), rep.Param)
	}
	if unexpectedData {
		return SyncError(fmt.Sprintf("unexpected data for code %s", getName(RC_names, int(req.Code))))
	}

	if err != nil {
		return err
	}
	if d.session != nil && rep.TransactionID != req.TransactionID {
		return SyncError(fmt.Sprintf("transaction ID mismatch got %x want %x",
			rep.TransactionID, req.TransactionID))
	}
	rep.SessionID = req.SessionID
	return nil
}

// Prints data going over the USB connection.
func (d *Device) dataPrint(ep byte, data []byte) {
	if !d.DataDebug {
		return
	}
	dir := "send"
	if 0 != ep&usb.ENDPOINT_IN {
		dir = "recv"
	}
	fmt.Fprintf(os.Stderr, "%s: 0x%x bytes with ep 0x%x:\n", dir, len(data), ep)
	hexDump(data)
}

func writeUSBPacket(write func([]byte) (int, error), packet []byte) (int64, error) {
	if len(packet) == 0 {
		actual, err := write(packet)
		if err != nil {
			return int64(actual), err
		}
		if actual != 0 {
			return int64(actual), fmt.Errorf("USB bulk zero-length write returned %d bytes", actual)
		}
		return 0, nil
	}

	var written int64
	for len(packet) > 0 {
		actual, err := write(packet)
		written += int64(actual)
		if err != nil {
			return written, err
		}
		if actual <= 0 {
			return written, fmt.Errorf("USB bulk write made no progress")
		}
		packet = packet[actual:]
	}
	return written, nil
}

// bulkWrite returns the number of non-header bytes written.
func (d *Device) bulkWrite(hdr *usbBulkHeader, r io.Reader, size int64, req *Container, progressCb ProgressFunc) (n int64, err error) {
	totalSize := size
	packetSize := d.sendMaxPacketSize()
	if packetSize <= 0 {
		return 0, fmt.Errorf("invalid USB bulk OUT packet size %d", packetSize)
	}
	writePacket := func(packet []byte) (int64, error) {
		return writeUSBPacket(func(data []byte) (int, error) {
			return d.h.BulkTransfer(d.sendEP, data, d.Timeout)
		}, packet)
	}

	if hdr != nil {
		if size+usbHdrLen > 0xFFFFFFFF {
			hdr.Length = 0xFFFFFFFF
		} else {
			hdr.Length = uint32(size + usbHdrLen)
		}

		packetArr := make([]byte, packetSize)
		var packet []byte
		if d.SeparateHeader {
			packet = packetArr[:usbHdrLen]
		} else {
			packet = packetArr[:]
		}

		buf := bytes.NewBuffer(packet[:0])
		if err := binary.Write(buf, byteOrder, hdr); err != nil {
			return 0, err
		}
		cpSize := int64(len(packet) - usbHdrLen)
		if cpSize > size {
			cpSize = size
		}
		if cpSize > 0 {
			payload := make([]byte, cpSize)
			read, readErr := io.ReadFull(r, payload)
			if read > 0 {
				_, _ = buf.Write(payload[:read])
			}
			if readErr != nil {
				return 0, readErr
			}
		}

		d.dataPrint(d.sendEP, buf.Bytes())
		written, writeErr := writePacket(buf.Bytes())
		if writeErr != nil {
			log.Printf("MTP operation=%s phase=data-header sent=%d requested=%d packet=%d: %v", getName(OC_names, int(req.Code)), written, int64(buf.Len()), packetSize, writeErr)
			return written, writeErr
		}
		size -= cpSize
		n += cpSize

		if err = progressCb(totalSize - size); err != nil {
			return n, err
		}
	}

	payloadChunkSize := packetSize
	if d.SeparateHeader {
		payloadChunkSize = rwBufSize
	}
	buf := make([]byte, payloadChunkSize)
	var lastPayloadSize int64

	for size > 0 {
		want := int64(len(buf))
		if want > size {
			want = size
		}
		read, readErr := io.ReadFull(r, buf[:want])
		if read == 0 && readErr != nil {
			return n, readErr
		}
		d.dataPrint(d.sendEP, buf[:read])
		written, writeErr := writePacket(buf[:read])
		n += written
		size -= written
		lastPayloadSize = written
		if writeErr != nil || written != int64(read) {
			if writeErr == nil {
				writeErr = fmt.Errorf("USB bulk write incomplete: sent=%d requested=%d", written, read)
			}
			log.Printf("MTP operation=%s phase=data-payload sent=%d requested=%d packet=%d: %v", getName(OC_names, int(req.Code)), n, read, packetSize, writeErr)
			return n, writeErr
		}
		if readErr != nil {
			return n, readErr
		}
		if err = progressCb(totalSize - size); err != nil {
			return n, err
		}
	}

	if d.SeparateHeader && lastPayloadSize > 0 && lastPayloadSize%int64(packetSize) == 0 {
		if _, err = writePacket(buf[:0]); err != nil {
			return n, fmt.Errorf("MTP operation=%s phase=short-packet: %w", getName(OC_names, int(req.Code)), err)
		}
	}

	return n, err
}

const rwBufSize = 0x4000

func (d *Device) bulkRead(w io.Writer, progressCb ProgressFunc) (n int64, lastPacket []byte, err error) {
	var buf [rwBufSize]byte
	var lastRead int

	for {
		toread := buf[:]
		lastRead, err = d.h.BulkTransfer(d.fetchEP, toread, d.Timeout)
		if err != nil {
			break
		}

		if lastRead > 0 {
			d.dataPrint(d.fetchEP, buf[:lastRead])

			w, err := w.Write(buf[:lastRead])
			n += int64(w)
			if err != nil {
				break
			}
		}

		if err = progressCb(n); err != nil {
			break
		}

		if d.MTPDebug {
			log.Printf("MTP bulk read 0x%x bytes.", lastRead)
		}
		if lastRead < len(toread) {
			// short read.
			break
		}
	}
	if err != nil {
		return n, buf[:0], err
	}
	packetSize := d.fetchMaxPacketSize()
	if lastRead%packetSize == 0 {
		// This should be a null packet, but on Linux + XHCI it's actually
		// CONTAINER_OK instead. To be liberal with the XHCI behavior, return
		// the final packet and inspect it in the calling function.
		var nullReadSize int
		nullReadSize, err = d.h.BulkTransfer(d.fetchEP, buf[:], d.Timeout)
		if d.MTPDebug {
			log.Printf("Expected null packet, read %d bytes", nullReadSize)
		}

		return n, buf[:nullReadSize], err
	}

	return n, buf[:0], err
}

// Configure is a robust version of OpenSession. On failure, it asks the MTP
// interface to reset its session state, then reopens the same USB handle.
func (d *Device) Configure() error {
	if d.h == nil {
		if err := d.Open(); err != nil {
			return err
		}
	}

	err := d.OpenSession()
	if err == RCError(RC_SessionAlreadyOpened) {
		// This works without a transaction ID on most Android devices. If the
		// stale response is already fatal, RunTransaction closes the handle;
		// the reset path below will reopen it before issuing the class request.
		_ = d.CloseSession()
		if d.h != nil {
			err = d.OpenSession()
		}
	}

	if err != nil {
		log.Printf("MTP OpenSession failed: %v; resetting MTP transport", err)
		if d.h == nil {
			if openErr := d.Open(); openErr != nil {
				return fmt.Errorf("opening for MTP reset: %w", openErr)
			}
		}
		resetErr := d.resetTransport()
		d.session = nil
		_ = d.Close()
		time.Sleep(250 * time.Millisecond)
		if openErr := d.Open(); openErr != nil {
			return fmt.Errorf("opening after MTP reset (reset=%v): %w", resetErr, openErr)
		}
		if openErr := d.OpenSession(); openErr != nil {
			_ = d.Close()
			return fmt.Errorf("OpenSession after MTP reset (reset=%v): %w", resetErr, openErr)
		}
	}
	return nil
}
