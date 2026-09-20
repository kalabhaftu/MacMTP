package main

import (
	"fmt"
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/go-mtpx"
	jsoniter "github.com/json-iterator/go"
	"kalam/send_to_js"
	"log"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

/*	#include "stdint.h"
	typedef void (* on_cb_result_t)(char*);
*/
/*
#include <signal.h>
static void ignore_signal(int sig) {
    signal(sig, SIG_IGN);
}
*/
import "C"

var container deviceContainer

var transferCancelRequested uint32

const maxNativeInputJSONBytes = 1 << 20

func decodeInputJSON(input *C.char, target interface{}) error {
	if input == nil {
		return fmt.Errorf("native input JSON is nil")
	}
	raw := C.GoString(input)
	if len(raw) > maxNativeInputJSONBytes {
		return fmt.Errorf("native input JSON exceeds %d bytes", maxNativeInputJSONBytes)
	}
	return jsoniter.ConfigFastest.UnmarshalFromString(raw, target)
}

func transferCancellationRequested() bool {
	return atomic.LoadUint32(&transferCancelRequested) == 1
}

//export BeginTransfer
func BeginTransfer() {
	atomic.StoreUint32(&transferCancelRequested, 0)
}

//export CancelTransfer
func CancelTransfer() {
	atomic.StoreUint32(&transferCancelRequested, 1)
}

//export SetOperationID
func SetOperationID(id *C.char) {
	if id == nil {
		send_to_js.SetOperationID("")
		return
	}
	send_to_js.SetOperationID(C.GoString(id))
}

func snapshotProgress(p *mtpx.ProgressInfo) *mtpx.ProgressInfo {
	if p == nil {
		return nil
	}

	snapshot := *p
	if p.FileInfo != nil {
		fileInfo := *p.FileInfo
		snapshot.FileInfo = &fileInfo
	}
	if p.ActiveFileSize != nil {
		activeSize := *p.ActiveFileSize
		snapshot.ActiveFileSize = &activeSize
	}
	if p.BulkFileSize != nil {
		bulkSize := *p.BulkFileSize
		snapshot.BulkFileSize = &bulkSize
	}
	return &snapshot
}

//export Initialize
func Initialize(inputJSON *C.char) {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	var input InitializeInput
	if err := decodeInputJSON(inputJSON, &input); err != nil {
		send_to_js.SendError(err)
		return
	}
	if input.VendorID == 0 || input.ProductID == 0 {
		send_to_js.SendError(fmt.Errorf("USB selector requires nonzero vendorId and productId"))
		return
	}

	_, err := _initialize(mtpx.Init{
		DebugMode: false,
		Selector: &mtp.DeviceSelector{
			VendorID:     input.VendorID,
			ProductID:    input.ProductID,
			SerialNumber: input.SerialNumber,
		},
	})
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	dInfo, err := _fetchDeviceInfo()
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	usbDesc, err := container.dev.GetUsbInfo()
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendInitialize(dInfo, usbDesc)
}

//export DiscoverMTPDevices
func DiscoverMTPDevices() {
	lockMtp()
	defer unlockMtp()

	selectors, err := mtp.DiscoverDeviceSelectors()
	if err != nil {
		send_to_js.SendError(err)
		return
	}
	send_to_js.SendMTPDevices(selectors)
}

//export FetchDeviceInfo
func FetchDeviceInfo() {
	lockMtp()
	defer unlockMtp()

	dInfo, err := _fetchDeviceInfo()
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	usbDesc, err := container.dev.GetUsbInfo()
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendDeviceInfo(dInfo, usbDesc)
}

//export FetchStorages
func FetchStorages() {
	lockMtp()
	defer unlockMtp()

	_sendFetchStorages(true)
}

func init() {
	// Ignore all non-fatal signals before any exported function runs.
	// When Go is embedded via cgo, the runtime installs signal handlers
	// that can crash the app if they receive a signal on a non-Go thread.
	C.ignore_signal(C.SIGURG)
	C.ignore_signal(C.SIGPIPE)
}

func _sendFetchStorages(retry bool) {
	storages, err := _fetchStorages()

	if err != nil {
		if container.dev != nil && container.deviceInfo != nil {
			if strings.Contains(err.Error(), "EOF") {
				err = fmt.Errorf("error allow storage access. %+v", err.Error())

				// this is done to prevent samsung devices from returning usb timeouts
				_ = _dispose()
			}
		}

		send_to_js.SendError(err)

		return
	}

	send_to_js.SendStorages(storages)
}

//export MakeDirectory
func MakeDirectory(makeDirectoryInputJson *C.char) {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	i := MakeDirectoryInput{}

	err := decodeInputJSON(makeDirectoryInputJson, &i)
	if err != nil {
		send_to_js.SendError(fmt.Errorf("error occured while Unmarshalling MakeDirectory input data %+v: ", err))

		return
	}
	if err := validateMakeDirectoryInput(i); err != nil {
		send_to_js.SendError(err)
		return
	}

	objectId, err := makeDirectoryWithResult(i.StorageId, i.FullPath)
	if cancelledErr := abortIfTransferCancelled(); cancelledErr != nil {
		err = cancelledErr
	}
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendMakeDirectory(objectId)
}

//export FileExists
func FileExists(fileExistsInputJson *C.char) {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	i := FileExistsInput{}

	err := decodeInputJSON(fileExistsInputJson, &i)
	if err != nil {
		send_to_js.SendError(fmt.Errorf("error occured while Unmarshalling FileExists input data %+v: ", err))

		return
	}
	if err := validateFileListInput(i.StorageId, i.Files); err != nil {
		send_to_js.SendError(err)
		return
	}

	var fProps []mtpx.FileProp
	for _, f := range i.Files {
		fProp := mtpx.FileProp{FullPath: f}

		fProps = append(fProps, fProp)
	}

	fc, err := _fileExists(i.StorageId, fProps)
	if cancelledErr := abortIfTransferCancelled(); cancelledErr != nil {
		err = cancelledErr
	}
	if err != nil {
		send_to_js.SendError(err)

		return
	}
	if len(fc) != len(i.Files) {
		send_to_js.SendError(fmt.Errorf("incomplete file existence response: got %d results for %d paths", len(fc), len(i.Files)))

		return
	}

	send_to_js.SendFileExists(fc, i.Files)
}

//export DeleteFile
func DeleteFile(deleteFileInputJson *C.char) {
	lockMtp()
	defer unlockMtp()

	i := DeleteFileInput{}

	err := decodeInputJSON(deleteFileInputJson, &i)
	if err != nil {
		send_to_js.SendError(fmt.Errorf("error occured while Unmarshalling DeleteFile input data %+v: ", err))

		return
	}
	if err := validateFileListInput(i.StorageId, i.Files); err != nil {
		send_to_js.SendError(err)
		return
	}

	var fProps []mtpx.FileProp
	for _, f := range i.Files {
		fProp := mtpx.FileProp{FullPath: f}

		fProps = append(fProps, fProp)
	}

	err = _deleteFile(i.StorageId, fProps)
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendDeleteFile()
}

//export RenameFile
func RenameFile(renameFileInputJson *C.char) {
	lockMtp()
	defer unlockMtp()

	i := RenameFileInput{}

	err := decodeInputJSON(renameFileInputJson, &i)
	if err != nil {
		send_to_js.SendError(fmt.Errorf("error occured while Unmarshalling RenameFile input data %+v: ", err))

		return
	}
	if err := validateRenameInput(i); err != nil {
		send_to_js.SendError(err)
		return
	}

	var fProp = mtpx.FileProp{
		FullPath: i.FullPath,
	}

	objectId, err := renameFileWithResult(i.StorageId, fProp, i.NewFileName)
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendRenameFile(objectId)
}

func makeDirectoryWithResult(storageId uint32, fullPath string) (uint32, error) {
	if err := abortIfTransferCancelled(); err != nil {
		return 0, err
	}
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return 0, err
	}
	objectId, err := mtpx.MakeDirectory(container.dev, storageId, fullPath)
	if err != nil {
		return 0, err
	}
	return objectId, nil
}

func renameFileWithResult(storageId uint32, fileProp mtpx.FileProp, newFileName string) (uint32, error) {
	if err := verifyMtpSession(verifyMtpSessionMode{}); err != nil {
		return 0, err
	}
	objectId, err := mtpx.RenameFile(container.dev, storageId, fileProp, newFileName)
	if err != nil {
		return 0, err
	}
	return objectId, nil
}

//export Walk
func Walk(walkInputJson *C.char) {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	i := WalkInput{}

	err := decodeInputJSON(walkInputJson, &i)
	if err != nil {
		send_to_js.SendError(fmt.Errorf("error occured while Unmarshalling Walk input data %+v: ", err))

		return
	}
	if err := validateWalkInput(i); err != nil {
		send_to_js.SendError(err)
		return
	}

	files, err := _walk(i.StorageId, i.FullPath, i.Recursive, i.SkipDisallowedFiles, i.SkipHiddenFiles)
	if cancelledErr := abortIfTransferCancelled(); cancelledErr != nil {
		err = cancelledErr
	}
	if err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendWalk(files)
}

//export UploadFiles
func UploadFiles(uploadFilesInputJson *C.char) {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	i := UploadFilesInput{}

	err := decodeInputJSON(uploadFilesInputJson, &i)
	if err != nil {
		send_to_js.SendTransferError(fmt.Errorf("error occured while Unmarshalling UploadFiles input data %+v: ", err))

		return
	}
	if err := validateTransferInput(i.StorageId, i.Sources, i.Destination); err != nil {
		send_to_js.SendTransferError(err)
		return
	}

	var pInterface interface{}
	var progressMu sync.RWMutex

	done := make(chan struct{})
	defer close(done)
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				progressMu.RLock()
				progress := pInterface
				progressMu.RUnlock()
				if progress != nil {
					switch v := progress.(type) {
					case UploadPreprocessContainer:
						send_to_js.SendUploadFilesPreprocess(v.fi, v.fullPath)

					case ProgressContainer:
						send_to_js.SendTransferFilesProgress(v.pInfo)

					default:
						log.Panicln("unimplemented UploadFiles.pInterface type")
					}
				}
			}
		}
	}()

	err = _uploadFiles(i.StorageId, i.Sources, i.Destination, i.PreprocessFiles,
		func(fi *os.FileInfo, fullPath string, err error) error {
			if transferCancellationRequested() {
				return mtpx.ErrTransferCancelled
			}
			if err != nil {
				return err
			}
			if fi == nil {
				return fmt.Errorf("upload preprocessing returned no file information")
			}

			progressMu.Lock()
			fileInfo := *fi
			pInterface = UploadPreprocessContainer{
				fi:       &fileInfo,
				fullPath: fullPath,
			}
			progressMu.Unlock()

			return nil
		},
		func(p *mtpx.ProgressInfo, err error) error {
			if transferCancellationRequested() {
				return mtpx.ErrTransferCancelled
			}
			if err != nil {
				return err
			}
			if p == nil || p.FileInfo == nil || p.ActiveFileSize == nil || p.BulkFileSize == nil {
				return fmt.Errorf("upload progress returned incomplete information")
			}

			progressMu.Lock()
			pInterface = ProgressContainer{
				pInfo: snapshotProgress(p),
			}
			progressMu.Unlock()

			return nil
		})
	if err == nil {
		err = abortIfTransferCancelled()
	}
	if err != nil {
		send_to_js.SendTransferError(err)

		return
	}

	send_to_js.SendTransferFilesDone()
}

//export DownloadFiles
func DownloadFiles(downloadFilesInputJson *C.char) {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	i := DownloadFilesInput{}

	err := decodeInputJSON(downloadFilesInputJson, &i)
	if err != nil {
		send_to_js.SendTransferError(fmt.Errorf("error occured while Unmarshalling DownloadFiles input data %+v: ", err))

		return
	}
	if err := validateTransferInput(i.StorageId, i.Sources, i.Destination); err != nil {
		send_to_js.SendTransferError(err)
		return
	}

	var pInterface interface{}
	var progressMu sync.RWMutex

	done := make(chan struct{})
	defer close(done)
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				progressMu.RLock()
				progress := pInterface
				progressMu.RUnlock()
				if progress != nil {
					switch v := progress.(type) {
					case DownloadPreprocessContainer:
						send_to_js.SendDownloadFilesPreprocess(v.fi)

					case ProgressContainer:
						send_to_js.SendTransferFilesProgress(v.pInfo)

					default:
						log.Panicln("unimplemented DownloadFiles.pInterface type")
					}
				}
			}
		}
	}()

	err = _downloadFiles(i.StorageId, i.Sources, i.Destination, i.PreprocessFiles,
		func(fi *mtpx.FileInfo, err error) error {
			if transferCancellationRequested() {
				return mtpx.ErrTransferCancelled
			}
			if err != nil {
				return err
			}
			if fi == nil {
				return fmt.Errorf("download preprocessing returned no file information")
			}

			progressMu.Lock()
			fileInfo := *fi
			pInterface = DownloadPreprocessContainer{
				fi: &fileInfo,
			}
			progressMu.Unlock()

			return nil
		},
		func(p *mtpx.ProgressInfo, err error) error {
			if transferCancellationRequested() {
				return mtpx.ErrTransferCancelled
			}
			if err != nil {
				return err
			}
			if p == nil || p.FileInfo == nil || p.ActiveFileSize == nil || p.BulkFileSize == nil {
				return fmt.Errorf("download progress returned incomplete information")
			}

			progressMu.Lock()
			pInterface = ProgressContainer{
				pInfo: snapshotProgress(p),
			}
			progressMu.Unlock()

			return nil
		})
	if err == nil {
		err = abortIfTransferCancelled()
	}
	if err != nil {
		send_to_js.SendTransferError(err)

		return
	}

	send_to_js.SendTransferFilesDone()
}

//export Dispose
func Dispose() {
	lockMtp()
	defer unlockMtp()
	defer atomic.StoreUint32(&transferCancelRequested, 0)

	if err := _dispose(); err != nil {
		send_to_js.SendError(err)

		return
	}

	send_to_js.SendDispose()
}

func main() {}
