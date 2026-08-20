package mtpx

import "errors"

// ErrTransferCancelled is returned by transfer progress callbacks when the
// host asks the current native transfer to stop.
var ErrTransferCancelled = errors.New("transfer cancelled")

type MtpDetectFailedError struct {
	error
}

type ConfigureError struct {
	error
}

type DeviceInfoError struct {
	error
}

type StorageInfoError struct {
	error
}

type NoStorageError struct {
	error
}

type ListDirectoryError struct {
	error
}

type FileNotFoundError struct {
	error
}

type FilePermissionError struct {
	error
}

type LocalFileError struct {
	error
}

type InvalidPathError struct {
	error
}

type FileTransferError struct {
	error
}

type FileObjectError struct {
	error
}

type SendObjectError struct {
	error
}
