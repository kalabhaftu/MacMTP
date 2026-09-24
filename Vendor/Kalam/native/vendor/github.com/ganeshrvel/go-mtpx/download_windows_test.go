package mtpx

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"testing"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

func TestWindowedDownloadAdvancesByActualBytesAndCancelsBetweenTransactions(t *testing.T) {
	var requests []string
	var destination bytes.Buffer
	cancelled := errors.New("cancelled")
	err := downloadObjectInWindows(10, &destination, func(offset int64, size uint32, w io.Writer) error {
		requests = append(requests, fmt.Sprintf("%d:%d", offset, size))
		_, err := w.Write([]byte{1, 2, 3})
		return err
	}, func(sent int64) error {
		if sent == 6 {
			return cancelled
		}
		return nil
	})
	if !errors.Is(err, cancelled) {
		t.Fatalf("error = %v, want cancellation", err)
	}
	if got, want := fmt.Sprint(requests), "[0:10 3:7]"; got != want {
		t.Fatalf("requests = %s, want %s", got, want)
	}
	if destination.Len() != 6 {
		t.Fatalf("wrote %d bytes, want 6", destination.Len())
	}
}

func TestWindowedDownloadRejectsZeroAndOversizedReads(t *testing.T) {
	for name, writeSize := range map[string]int{"zero": 0, "oversized": 5} {
		t.Run(name, func(t *testing.T) {
			err := downloadObjectInWindows(4, io.Discard, func(_ int64, _ uint32, w io.Writer) error {
				if writeSize > 0 {
					_, _ = w.Write(make([]byte, writeSize))
				}
				return nil
			}, func(int64) error { return nil })
			if err == nil {
				t.Fatal("invalid read should fail")
			}
		})
	}
}

func TestWindowedDownloadSplitsAtEightMiB(t *testing.T) {
	total := int64(downloadWindowSize) + 2
	var requests []uint32
	err := downloadObjectInWindows(total, io.Discard, func(_ int64, size uint32, w io.Writer) error {
		requests = append(requests, size)
		_, err := w.Write(make([]byte, size))
		return err
	}, func(int64) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if got, want := fmt.Sprint(requests), fmt.Sprintf("[%d 2]", downloadWindowSize); got != want {
		t.Fatalf("requests = %s, want %s", got, want)
	}
}

func TestPartialDownloadSelectionPrefers64BitAndFallsBackSafely(t *testing.T) {
	supports := func(operations ...uint16) func(uint16) bool {
		return func(candidate uint16) bool {
			for _, operation := range operations {
				if candidate == operation {
					return true
				}
			}
			return false
		}
	}
	if got := selectPartialDownloadMode(1, supports(mtp.OC_ANDROID_GET_PARTIAL_OBJECT64, mtp.OC_GetPartialObject)); got != android64PartialDownload {
		t.Fatalf("mode = %v, want Android 64-bit", got)
	}
	if got := selectPartialDownloadMode(1, supports(mtp.OC_GetPartialObject)); got != standardPartialDownload {
		t.Fatalf("mode = %v, want standard partial", got)
	}
	if got := selectPartialDownloadMode(int64(^uint32(0))+1, supports(mtp.OC_GetPartialObject)); got != fullObjectDownload {
		t.Fatalf("mode = %v, want full-object fallback", got)
	}
	if got := selectPartialDownloadMode(1, supports()); got != fullObjectDownload {
		t.Fatalf("mode = %v, want unsupported fallback", got)
	}
}
