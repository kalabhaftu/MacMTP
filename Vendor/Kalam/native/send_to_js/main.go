package send_to_js

/*
	#include "stdlib.h"

	extern void macMTP_done_callback(char* json);
	extern void macMTP_preprocess_callback(char* json);
	extern void macMTP_progress_callback(char* json);
	extern void macMTP_transfer_done_callback(char* json);

	void call_done(char* json) {
		macMTP_done_callback(json);
	}
	void call_preprocess(char* json) {
		macMTP_preprocess_callback(json);
	}
	void call_progress(char* json) {
		macMTP_progress_callback(json);
	}
	void call_transfer_done(char* json) {
		macMTP_transfer_done_callback(json);
	}
*/
import "C"
import (
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/go-mtpx"
	"os"
	"time"
)

func SendError(err error) {
	errorType, errorMsg := processError(err)

	o := ErrorResult{
		ErrorType: errorType,
		Error:     errorMsg,
		Data:      nil,
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendTransferError(err error) {
	errorType, errorMsg := processError(err)
	o := ErrorResult{ErrorType: errorType, Error: errorMsg, Data: nil}
	C.call_transfer_done(C.CString(toJson(o)))
}

func SendInitialize(deviceInfo *mtp.DeviceInfo, usbDesc *mtp.UsbDeviceInfo) {
	o := InitializeResult{
		Data: DeviceInfo{
			MtpDeviceInfo: deviceInfo,
			UsbDeviceInfo: usbDesc,
		},
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendDeviceInfo(deviceInfo *mtp.DeviceInfo, usbDesc *mtp.UsbDeviceInfo) {
	o := DeviceInfoResult{
		Data: DeviceInfo{
			MtpDeviceInfo: deviceInfo,
			UsbDeviceInfo: usbDesc,
		},
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendStorages(storages []mtpx.StorageData) {
	if storages == nil {
		storages = make([]mtpx.StorageData, 0)
	}
	o := StoragesResult{
		Data: storages,
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

type MutationResult struct {
	ErrorType ErrorType `json:"errorType"`
	Error     string    `json:"error"`
	Data      bool      `json:"data"`
	ObjectId  uint32    `json:"objectId"`
}

func SendMakeDirectory(objectId uint32) {
	o := MutationResult{Data: true, ObjectId: objectId}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendFileExists(fc []mtpx.FileExistsContainer, inputFiles []string) {
	fdSlice := make([]FileExistsData, 0, len(fc))
	for i, f := range fc {
		fd := FileExistsData{
			Fullpath: inputFiles[i],
			Exists:   f.Exists,
		}

		fdSlice = append(fdSlice, fd)
	}

	o := FileExistsResult{
		Data: fdSlice,
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendDeleteFile() {
	o := DeleteFileResult{
		Data: true,
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendRenameFile(objectId uint32) {
	o := MutationResult{Data: true, ObjectId: objectId}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendWalk(files []*mtpx.FileInfo) {
	outputFiles := make([]FileInfo, 0, len(files))

	for _, f := range files {
		outputFile := FileInfo{
			Size:       f.Size,
			IsDir:      f.IsDir,
			ModTime:    f.ModTime.Format(DateTimeFormat),
			Name:       f.Name,
			FullPath:   f.FullPath,
			ParentPath: f.ParentPath,
			Extension:  f.Extension,
			ParentId:   f.ParentId,
			ObjectId:   f.ObjectId,
		}

		outputFiles = append(outputFiles, outputFile)
	}

	o := WalkResult{
		Data: outputFiles,
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}

func SendUploadFilesPreprocess(fi *os.FileInfo, fullPath string) {
	o := UploadFilesPreprocessResult{
		Data: TransferPreprocessData{
			FullPath: fullPath,
			Name:     (*fi).Name(),
			Size:     (*fi).Size(),
		},
	}

	json := toJson(o)

	C.call_preprocess(C.CString(json))
}

func SendDownloadFilesPreprocess(fi *mtpx.FileInfo) {
	o := DownloadFilesPreprocessResult{
		Data: TransferPreprocessData{
			FullPath: fi.FullPath,
			Name:     fi.Name,
			Size:     fi.Size,
		},
	}

	json := toJson(o)

	C.call_preprocess(C.CString(json))
}

func SendTransferFilesProgress(p *mtpx.ProgressInfo) {
	o := UploadFilesProgressResult{
		Data: TransferProgressInfo{
			FullPath:          p.FileInfo.FullPath,
			Name:              p.FileInfo.Name,
			ElapsedTime:       time.Since(p.StartTime).Milliseconds(),
			Speed:             p.Speed,
			TotalFiles:        p.TotalFiles,
			TotalDirectories:  p.TotalDirectories,
			FilesSent:         p.FilesSent,
			FilesSentProgress: p.FilesSentProgress,
			ActiveFileSize: TransferSizeInfo{
				Total:    p.ActiveFileSize.Total,
				Sent:     p.ActiveFileSize.Sent,
				Progress: p.ActiveFileSize.Progress,
			},
			BulkFileSize: TransferSizeInfo{
				Total:    p.BulkFileSize.Total,
				Sent:     p.BulkFileSize.Sent,
				Progress: p.BulkFileSize.Progress,
			},
			Status: p.Status,
		},
	}

	json := toJson(o)

	C.call_progress(C.CString(json))
}

func SendTransferFilesDone() {
	o := UploadFilesDoneResult{
		Data: true,
	}

	json := toJson(o)

	C.call_transfer_done(C.CString(json))
}

func SendDispose() {
	o := DisposeResult{
		Data: true,
	}

	json := toJson(o)

	C.call_done(C.CString(json))
}
