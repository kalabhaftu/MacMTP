package mtp

import (
	"bytes"
	"reflect"
	"testing"
)

func TestInstantiateTypeRejectsUnknownType(t *testing.T) {
	if _, err := InstantiateType(DataTypeSelector(0xfffe)); err == nil {
		t.Fatal("expected unknown data type to return an error")
	}
}

func TestDecodeArrayRejectsShortReads(t *testing.T) {
	_, err := decodeArray(bytes.NewReader([]byte{2, 0, 0, 0, 1}), reflect.TypeOf([]uint8{}))
	if err == nil {
		t.Fatal("expected truncated array payload to return an error")
	}
}
