package log

import (
	"github.com/sirupsen/logrus"
)

var log *logrus.Logger

// InitLogs initializes log instance
func InitLogs() *logrus.Logger {
	log = logrus.New()
	log.SetReportCaller(true)
	return log
}

// GetLogger returns log instance
func GetLogger() *logrus.Logger {
	return log
}
