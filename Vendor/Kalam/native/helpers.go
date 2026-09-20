package main

import (
	"fmt"
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/go-mtpx"
	"log"
	"strings"
	"sync"
)

const (
	maxNativePathLength = 4096
)

var mtpOperationMu sync.Mutex

func verifyMtpSession(c verifyMtpSessionMode) error {
	if container.dev == nil {
		return fmt.Errorf("ErrorMtpDetectFailed")
	}
	// Device information is a connection-time check. Repeating it before every
	// operation corrupts Android sessions after cancellation and adds traffic.
	return nil
}

func abortIfTransferCancelled() error {
	if !transferCancellationRequested() {
		return nil
	}
	// Only signal cancellation. Do NOT call _abort() here — that would
	// nil out container.dev and break any subsequent operation (refresh,
	// directory listing) on the still-live USB connection.
	return mtpx.ErrTransferCancelled
}

func _initialize(i mtpx.Init) (*mtp.Device, error) {
	d, err := mtpx.Initialize(i)
	if err != nil {
		return nil, err
	}

	container.dev = d

	return d, nil
}

func _fetchDeviceInfo() (*mtp.DeviceInfo, error) {
	v := verifyMtpSessionMode{skipDeviceChangeCheck: true}

	if !v.skipDeviceChangeCheck {
		log.Panicln("'skipDeviceChangeCheck' should be 'true' in _fetchDeviceInfo.verifyMtpSessionMode")
	}

	if err := verifyMtpSession(v); err != nil {
		return nil, err
	}

	dInfo, err := mtpx.FetchDeviceInfo(container.dev)
	if err != nil {
		container.deviceInfo = nil

		return nil, err
	}

	container.deviceInfo = dInfo

	return dInfo, nil
}

func _fetchStorages() ([]mtpx.StorageData, error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return nil, err
	}

	storages, err := mtpx.FetchStorages(container.dev)
	if err != nil {
		return nil, err
	}

	return storages, nil
}

func _makeDirectory(storageId uint32, fullPath string) error {
	if err := abortIfTransferCancelled(); err != nil {
		return err
	}
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, err := mtpx.MakeDirectory(container.dev, storageId, fullPath)
	if err != nil {
		return err
	}

	return nil
}

func _fileExists(storageId uint32, fileProps []mtpx.FileProp) (exists []mtpx.FileExistsContainer, error error) {
	if err := abortIfTransferCancelled(); err != nil {
		return []mtpx.FileExistsContainer{}, err
	}
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return []mtpx.FileExistsContainer{}, err
	}

	exists, err := mtpx.FileExists(container.dev, storageId, fileProps)
	if err != nil {
		return exists, err
	}

	return exists, nil
}

func _deleteFile(storageId uint32, fileProps []mtpx.FileProp) (error error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	err := mtpx.DeleteFile(container.dev, storageId, fileProps)
	if err != nil {
		return err
	}

	return nil
}

func _renameFile(storageId uint32, fileProp mtpx.FileProp, newFileName string) (error error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, err := mtpx.RenameFile(container.dev, storageId, fileProp, newFileName)
	if err != nil {
		return err
	}

	return nil
}

func _walk(storageId uint32, fullPath string, recursive, skipDisallowedFiles, skipHiddenFiles bool) (files []*mtpx.FileInfo, err error) {
	if err := abortIfTransferCancelled(); err != nil {
		return []*mtpx.FileInfo{}, err
	}
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return []*mtpx.FileInfo{}, err
	}

	_, _, _, err = mtpx.Walk(container.dev, storageId, fullPath, recursive, skipDisallowedFiles, skipHiddenFiles, func(objectId uint32, fi *mtpx.FileInfo, err error) error {
		if transferCancellationRequested() {
			return mtpx.ErrTransferCancelled
		}
		if err != nil {
			return err
		}

		files = append(files, fi)

		return nil
	})
	if err != nil {
		return []*mtpx.FileInfo{}, err
	}

	return files, nil
}

func _uploadFiles(storageId uint32, sources []string, destination string, preprocessFiles bool, preprocessCb mtpx.LocalPreprocessCb, progressCb mtpx.ProgressCb) (err error) {
	if err := abortIfTransferCancelled(); err != nil {
		return err
	}
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, _, _, err = mtpx.UploadFiles(container.dev, storageId, sources, destination, preprocessFiles, preprocessCb, progressCb)
	if err != nil {
		return err
	}

	return nil
}

func _downloadFiles(storageId uint32, sources []string, destination string, preprocessFiles bool, preprocessCb mtpx.MtpPreprocessCb, progressCb mtpx.ProgressCb) (err error) {
	if err := abortIfTransferCancelled(); err != nil {
		return err
	}
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return err
	}

	_, _, err = mtpx.DownloadFiles(container.dev, storageId, sources, destination, preprocessFiles, preprocessCb, progressCb)
	if err != nil {
		return err
	}

	return nil
}

func _dispose() error {
	dev := container.dev
	container.dev = nil
	container.deviceInfo = nil
	if dev == nil {
		return nil
	}

	return mtpx.Dispose(dev)
}

func _abort() error {
	dev := container.dev
	container.dev = nil
	container.deviceInfo = nil
	if dev == nil {
		return nil
	}
	return mtpx.Abort(dev)
}

func lockMtp() {
	mtpOperationMu.Lock()
}

func unlockMtp() {
	mtpOperationMu.Unlock()
}

func validateStorageID(storageID uint32) error {
	if storageID == 0 {
		return fmt.Errorf("storage ID must be nonzero")
	}
	return nil
}

func validateMTPPath(value string) error {
	if value == "" || len(value) > maxNativePathLength || strings.IndexByte(value, 0) >= 0 {
		return fmt.Errorf("invalid MTP path")
	}
	return nil
}

func validateMTPName(value string) error {
	if value == "" || value == "." || value == ".." || strings.ContainsAny(value, "/\\") || strings.IndexByte(value, 0) >= 0 {
		return fmt.Errorf("invalid MTP name")
	}
	return validateMTPPath(value)
}

func validateMTPPaths(paths []string, allowEmpty bool) error {
	if !allowEmpty && len(paths) == 0 {
		return fmt.Errorf("at least one MTP path is required")
	}
	for _, path := range paths {
		if err := validateMTPPath(path); err != nil {
			return err
		}
	}
	return nil
}

func validateMakeDirectoryInput(input MakeDirectoryInput) error {
	if err := validateStorageID(input.StorageId); err != nil {
		return err
	}
	return validateMTPPath(input.FullPath)
}

func validateFileListInput(storageID uint32, files []string) error {
	if err := validateStorageID(storageID); err != nil {
		return err
	}
	return validateMTPPaths(files, false)
}

func validateRenameInput(input RenameFileInput) error {
	if err := validateStorageID(input.StorageId); err != nil {
		return err
	}
	if err := validateMTPPath(input.FullPath); err != nil {
		return err
	}
	return validateMTPName(input.NewFileName)
}

func validateWalkInput(input WalkInput) error {
	if err := validateStorageID(input.StorageId); err != nil {
		return err
	}
	return validateMTPPath(input.FullPath)
}

func validateTransferInput(storageID uint32, sources []string, destination string) error {
	if err := validateStorageID(storageID); err != nil {
		return err
	}
	if err := validateMTPPaths(sources, false); err != nil {
		return err
	}
	return validateMTPPath(destination)
}
