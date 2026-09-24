package mtpx

import (
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"os"
)

const PathSep = string(os.PathSeparator)

const ParentObjectId = mtp.GOH_ROOT_PARENT

// Android can spend longer finalizing a large SendObject after the payload is
// complete (media indexing and storage flush). Keep USB operations bounded but
// allow that response time before declaring the session dead.
const devTimeout = 30000

const newLocalDirectoryMode = 0755

const disallowedFileName = ":*?\"<>|"

var disallowedFiles = []string{".DS_Store", "[-----DS_Store.mtp.test----].txt"}

var allowedSecondExtensions allowedSecondExtMap = map[string]string{"tar": "tar"}
