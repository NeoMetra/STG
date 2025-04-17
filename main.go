package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	"github.com/charmbracelet/lipgloss"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// Constants for configuration and UI
const (
	DefaultConfigDir      = "/opt/smtp-to-gotify"
	ConfigFileName        = "config.yaml"
	LogFileName           = "logs.json"
	MaxStatusLines        = 50
	MatrixFPS             = 10 // Frames per second for Matrix animation
	CubeFPS               = 5  // Frames per second for cube rotation
	CubeFrameCount        = 4  // Number of frames for cube rotation animation
	StatusUpdateBuffer    = 200 // Increased buffer to prevent dropped status messages
	StatusUpdateDebounce  = 100 * time.Millisecond
	DefaultSMTPPort       = ":2525"
	DefaultSMTPDomain     = "localhost"
	DefaultSMTPUser       = "admin"
	DefaultSMTPPass       = "password"
	DefaultGotifyHost     = "https://gotify.example.com"
	DefaultGotifyPriority = 5
	GotifyTimeout         = 10 * time.Second
	GotifyMaxRetries      = 3
	// Recommendation 4: Log rotation size limit (10MB)
	MaxLogFileSize        = 10 * 1024 * 1024 // 10MB in bytes
	// Recommendation 6: SMTP connection timeout
	SMTPConnectionTimeout = 30 * time.Second
)

// Color constants for UI styling
const (
	ColorWhite        = "15" // High visibility white
	ColorBrightYellow = "11" // Bright yellow for status
	ColorRed          = "9"  // Red for errors
	ColorBrightGreen  = "10" // Bright green for selections
	ColorGray         = "7"  // Gray for help text
	ColorMatrixGreen  = "#00FF00" // Terminal green for Matrix
	ColorCubeRed      = "#DC143C" // Crimson red for Cube
)

// AppConfig holds the full application configuration
type AppConfig struct {
	SMTP   SMTPConfig
	Gotify GotifyConfig
}

// SMTPConfig holds the SMTP server configuration
type SMTPConfig struct {
	Addr         string
	Domain       string
	SMTPUsername string `mapstructure:"smtp_username"`
	SMTPPassword string `mapstructure:"smtp_password"`
	AuthRequired bool   `mapstructure:"auth_required"`
}

// GotifyConfig holds the configuration for connecting to the Gotify server
type GotifyConfig struct {
	GotifyHost  string `mapstructure:"gotify_host"`
	GotifyToken string `mapstructure:"gotify_token"`
}

// EmailData holds the parsed email data
type EmailData struct {
	From    string
	To      []string
	Subject string
	Body    string
}

// GotifyMessage represents the structure of a message to send to Gotify
type GotifyMessage struct {
	Title    string `json:"title"`
	Message  string `json:"message"`
	Priority int    `json:"priority"`
}

// LogEntry represents a single log entry for various events with description
type LogEntry struct {
	Timestamp   string `json:"timestamp"`
	Category    string `json:"category"`
	Message     string `json:"message"`
	Description string `json:"description"`
}

// LogStore holds the structure for storing logs in JSON
type LogStore struct {
	Entries []LogEntry `json:"entries"`
}

// ZapLogEntry represents a single log entry as written by Zap logger
type ZapLogEntry struct {
	Level       string `json:"level"`
	Timestamp   string `json:"timestamp"`
	Caller      string `json:"caller"`
	Message     string `json:"message"`
	Category    string `json:"category"`
	Description string `json:"description"`
	FullMessage string `json:"message"`
}

// Global variables for configuration and logging
var (
	configDirPath  = getEnv("SMTP_TO_GOTIFY_CONFIG_DIR", DefaultConfigDir)
	configFilePath = filepath.Join(configDirPath, ConfigFileName)
	logFilePath    = filepath.Join(configDirPath, LogFileName)
	zapLogger      *zap.Logger
	logMutex       sync.Mutex
	logUpdateChan  = make(chan LogEntry, StatusUpdateBuffer)
	// Recommendation 14: Track active connections for graceful shutdown
	activeConnections sync.WaitGroup
)

// Global variables for UI state
var (
	statusLog          []string
	statusUpdateChan   = make(chan string, StatusUpdateBuffer) // Increased buffer
	statusUpdateTimer  *time.Timer
	appMutex           sync.Mutex
)

// getEnv retrieves environment variables with a fallback value
func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

// initLogger initializes the Zap logger for JSON output to a file
func initLogger() error {
	logDir := filepath.Dir(logFilePath)
	if err := os.MkdirAll(logDir, 0750); err != nil {
		return fmt.Errorf("failed to create log directory: %v", err)
	}
	cfg := zap.NewProductionConfig()
	cfg.OutputPaths = []string{logFilePath}
	cfg.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	cfg.EncoderConfig.TimeKey = "timestamp"
	cfg.EncoderConfig.LevelKey = "level"
	cfg.EncoderConfig.MessageKey = "message"
	logger, err := cfg.Build()
	if err != nil {
		return fmt.Errorf("failed to build zap logger: %v", err)
	}
	zapLogger = logger
	return nil
}

// logEvent logs an event using Zap and updates UI with detailed description
func logEvent(category, message, description string) {
	if zapLogger != nil {
		zapLogger.Info("Application Event",
			       zap.String("category", category),
			       zap.String("message", message),
			       zap.String("description", description),
		)
	}
	entry := LogEntry{
		Timestamp:   time.Now().Format("1/2/2006 - 15:04:05"),
		Category:    category,
		Message:     message,
		Description: description,
	}
	select {
		case logUpdateChan <- entry:
		default:
			// Log to stderr if channel is full to avoid silent drops
			fmt.Fprintf(os.Stderr, "Log channel full, dropping entry: %s\n", message)
	}
}

// ensureLogFileExists creates the log file if it doesn't exist
func ensureLogFileExists() error {
	if _, err := os.Stat(logFilePath); os.IsNotExist(err) {
		initialData := []byte(`{"entries": []}`)
		if err := os.WriteFile(logFilePath, initialData, 0640); err != nil {
			return fmt.Errorf("failed to create log file: %v", err)
		}
	}
	return nil
}

// Recommendation 4: Log rotation helper function
func rotateLogFile() error {
	logMutex.Lock()
	defer logMutex.Unlock()

	// Check current log file size
	fileInfo, err := os.Stat(logFilePath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to stat log file: %v", err)
	}

	if fileInfo != nil && fileInfo.Size() >= MaxLogFileSize {
		// Generate a rotated log file name with timestamp
		timestamp := time.Now().Format("20060102_150405")
		rotatedPath := fmt.Sprintf("%s.%s", logFilePath, timestamp)
		if err := os.Rename(logFilePath, rotatedPath); err != nil {
			return fmt.Errorf("failed to rotate log file: %v", err)
		}
		// Create a new empty log file
		initialData := []byte(`{"entries": []}`)
		if err := os.WriteFile(logFilePath, initialData, 0640); err != nil {
			return fmt.Errorf("failed to create new log file after rotation: %v", err)
		}
		appendToStatus("Log file rotated due to size limit.")
		logEvent("log_rotation", "Log file rotated", fmt.Sprintf("Log file %s exceeded size limit and was rotated to %s", logFilePath, rotatedPath))
	}
	return nil
}

// loadLogs loads the logs from the JSON file, handling both formats
func loadLogs() (LogStore, error) {
	logMutex.Lock()
	defer logMutex.Unlock()
	if err := ensureLogFileExists(); err != nil {
		fmt.Fprintf(os.Stderr, "Debug: Failed to ensure log file exists: %v\n", err)
		return LogStore{}, err
	}
	file, err := os.Open(logFilePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Debug: Failed to open log file %s: %v\n", logFilePath, err)
		return LogStore{Entries: []LogEntry{}}, fmt.Errorf("failed to open log file: %v", err)
	}
	defer file.Close()
	var entries []LogEntry
	scanner := bufio.NewScanner(file)
	firstLine := ""
	if scanner.Scan() {
		firstLine = scanner.Text()
	}
	if strings.HasPrefix(firstLine, "{\"entries\":") {
		data, err := os.ReadFile(logFilePath)
		if err == nil {
			var store LogStore
			if json.Unmarshal(data, &store) == nil {
				fmt.Fprintf(os.Stderr, "Debug: Successfully loaded %d entries from JSON store format\n", len(store.Entries))
				return store, nil
			} else {
				fmt.Fprintf(os.Stderr, "Debug: Failed to unmarshal JSON store format: %v\n", err)
			}
		}
		file.Seek(0, 0)
		scanner = bufio.NewScanner(file)
	}
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) == 0 {
			continue
		}
		var zapEntry ZapLogEntry
		if err := json.Unmarshal([]byte(line), &zapEntry); err == nil {
			message := zapEntry.FullMessage
			if message == "" {
				message = zapEntry.Message
			}
			timestamp := zapEntry.Timestamp
			if len(timestamp) > 19 {
				timestamp = timestamp[:19]
				timestamp = strings.Replace(timestamp, "T", " ", 1)
			}
			if parsedTime, err := time.Parse("2006-01-02 15:04:05", timestamp); err == nil {
				timestamp = parsedTime.Format("1/2/2006 - 15:04:05")
			}
			entries = append(entries, LogEntry{
				Timestamp:   timestamp,
				Category:    zapEntry.Category,
				Message:     message,
				Description: zapEntry.Description,
			})
		} else {
			fmt.Fprintf(os.Stderr, "Debug: Failed to parse log line: %s, error: %v\n", line, err)
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Debug: Error reading log file line by line: %v\n", err)
		return LogStore{Entries: entries}, fmt.Errorf("error reading log file line by line: %v", err)
	}
	fmt.Fprintf(os.Stderr, "Debug: Loaded %d entries from line-by-line parsing\n", len(entries))
	return LogStore{Entries: entries}, nil
}

// Recommendation 4: Modified saveLogs to check for rotation
func saveLogs(store LogStore) error {
	logMutex.Lock()
	defer logMutex.Unlock()
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal log data: %v", err)
	}
	logDir := filepath.Dir(logFilePath)
	if err := os.MkdirAll(logDir, 0750); err != nil {
		return fmt.Errorf("failed to create log directory: %v", err)
	}
	if err := rotateLogFile(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to rotate log file: %v\n", err)
	}
	if err := os.WriteFile(logFilePath, data, 0640); err != nil {
		return fmt.Errorf("failed to write log file: %v", err)
	}
	return nil
}

// appendLog adds a new log entry and writes it directly to the file
func appendLog(entry LogEntry) error {
	store, err := loadLogs()
	if err != nil {
		store = LogStore{Entries: []LogEntry{}}
	}
	store.Entries = append(store.Entries, entry)
	return saveLogs(store)
}

// initStatusUpdater initializes the status update handler with debouncing
func initStatusUpdater(p *tea.Program) {
	go func() {
		for {
			select {
				case msg, ok := <-statusUpdateChan:
					if !ok {
						return
					}
					appMutex.Lock()
					statusLog = append(statusLog, msg)
					if len(statusLog) > MaxStatusLines {
						statusLog = statusLog[len(statusLog)-MaxStatusLines:]
					}
					appMutex.Unlock()
					if statusUpdateTimer != nil {
						statusUpdateTimer.Stop()
					}
					statusUpdateTimer = time.AfterFunc(StatusUpdateDebounce, func() {
						p.Send(StatusUpdateMsg{})
					})
				case logEntry, ok := <-logUpdateChan:
					if !ok {
						return
					}
					if err := appendLog(logEntry); err != nil {
						fmt.Fprintf(os.Stderr, "Failed to append log: %v\n", err)
					}
					p.Send(LogUpdateMsg{Entry: logEntry})
			}
		}
	}()
}

// appendToStatus adds a message to the status log panel safely
func appendToStatus(message string) {
	timestamp := time.Now().Format("1/2/2006 - 15:04:05")
	select {
				case statusUpdateChan <- fmt.Sprintf("[%s] %s", timestamp, message):
				default:
					fmt.Fprintf(os.Stderr, "Status channel full, dropping message: %s\n", message)
	}
}

// Recommendation 6: Modified handleConnection with timeout
func handleConnection(conn net.Conn, config AppConfig) {
	defer conn.Close()
	// Set a deadline for the connection to prevent hanging
	if err := conn.SetDeadline(time.Now().Add(SMTPConnectionTimeout)); err != nil {
		appendToStatus(fmt.Sprintf("Error setting connection deadline: %v", err))
		logEvent("error", fmt.Sprintf("Error setting connection deadline: %v", err), fmt.Sprintf("Failed to set timeout for SMTP connection from %s: %v", conn.RemoteAddr().String(), err))
	}
	// Recommendation 14: Track active connections
	activeConnections.Add(1)
	defer activeConnections.Done()

	reader := bufio.NewReader(conn)
	writer := bufio.NewWriter(conn)
	remoteAddr := conn.RemoteAddr().String()
	appendToStatus(fmt.Sprintf("New SMTP connection from %s", remoteAddr))
	logEvent("connection", fmt.Sprintf("New SMTP connection from %s", remoteAddr), fmt.Sprintf("Client connected from address %s, initiating SMTP handshake.", remoteAddr))
	fmt.Fprintf(writer, "220 %s SMTP Server Ready\r\n", config.SMTP.Domain)
	writer.Flush()
	var from string
	var to []string
	var data strings.Builder
	authenticated := false
	var authUsername string
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			appendToStatus(fmt.Sprintf("Error reading from connection: %v", err))
			logEvent("error", fmt.Sprintf("Error reading from connection from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to read incoming SMTP command from client at %s due to connection error: %v", remoteAddr, err))
			return
		}
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "HELO") || strings.HasPrefix(line, "EHLO") {
			fmt.Fprintf(writer, "250-%s Hello\r\n", config.SMTP.Domain)
			fmt.Fprintf(writer, "250-AUTH LOGIN PLAIN\r\n")
			fmt.Fprintf(writer, "250-8BITMIME\r\n")
			fmt.Fprintf(writer, "250-ENHANCEDSTATUSCODES\r\n")
			fmt.Fprintf(writer, "250-CHUNKING\r\n")
			fmt.Fprintf(writer, "250 SIZE 1048576\r\n")
			writer.Flush()
			logEvent("smtp_handshake", fmt.Sprintf("Received %s from %s", strings.Split(line, " ")[0], remoteAddr), fmt.Sprintf("Client at %s initiated SMTP handshake with %s command, server responded with supported features including AUTH.", remoteAddr, strings.Split(line, " ")[0]))
		} else if strings.HasPrefix(line, "AUTH LOGIN") {
			fmt.Fprintf(writer, "334 VXNlcm5hbWU6\r\n")
			writer.Flush()
			usernameLine, err := reader.ReadString('\n')
			if err != nil {
				appendToStatus(fmt.Sprintf("Error reading username: %v", err))
				logEvent("error", fmt.Sprintf("Error reading username from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to read username during AUTH LOGIN from client at %s: %v", remoteAddr, err))
				return
			}
			usernameLine = strings.TrimSpace(usernameLine)
			usernameBytes, err := base64.StdEncoding.DecodeString(usernameLine)
			if err != nil {
				appendToStatus(fmt.Sprintf("Error decoding username: %v", err))
				logEvent("error", fmt.Sprintf("Error decoding username from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to decode base64-encoded username during AUTH LOGIN from client at %s: %v", remoteAddr, err))
				fmt.Fprintf(writer, "535 Authentication failed\r\n")
				writer.Flush()
				continue
			}
			authUsername = string(usernameBytes)
			fmt.Fprintf(writer, "334 UGFzc3dvcmQ6\r\n")
			writer.Flush()
			passwordLine, err := reader.ReadString('\n')
			if err != nil {
				appendToStatus(fmt.Sprintf("Error reading password: %v", err))
				logEvent("error", fmt.Sprintf("Error reading password from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to read password during AUTH LOGIN from client at %s: %v", remoteAddr, err))
				return
			}
			passwordLine = strings.TrimSpace(passwordLine)
			passwordBytes, err := base64.StdEncoding.DecodeString(passwordLine)
			if err != nil {
				appendToStatus(fmt.Sprintf("Error decoding password: %v", err))
				logEvent("error", fmt.Sprintf("Error decoding password from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to decode base64-encoded password during AUTH LOGIN from client at %s: %v", remoteAddr, err))
				fmt.Fprintf(writer, "535 Authentication failed\r\n")
				writer.Flush()
				continue
			}
			password := string(passwordBytes)
			// Recommendation 5: Fix authentication comparison bug
			if authUsername == config.SMTP.SMTPUsername && password == config.SMTP.SMTPPassword {
				authenticated = true
				appendToStatus("Authentication successful (LOGIN)")
				logEvent("smtp_auth_success", fmt.Sprintf("User %s authenticated successfully (LOGIN) from %s", authUsername, remoteAddr), fmt.Sprintf("Client at %s provided valid credentials for user %s using AUTH LOGIN method, authentication granted.", remoteAddr, authUsername))
				fmt.Fprintf(writer, "235 Authentication successful\r\n")
			} else {
				appendToStatus("Authentication failed: Invalid credentials (LOGIN)")
				logEvent("smtp_auth_failed", fmt.Sprintf("Failed authentication for user %s (LOGIN) from %s", authUsername, remoteAddr), fmt.Sprintf("Client at %s provided invalid credentials for user %s using AUTH LOGIN method, authentication denied.", remoteAddr, authUsername))
				fmt.Fprintf(writer, "535 Authentication failed\r\n")
			}
			writer.Flush()
		} else if strings.HasPrefix(line, "AUTH PLAIN") {
			parts := strings.Split(line, " ")
			var authData string
			if len(parts) > 2 {
				authData = parts[2]
			} else {
				fmt.Fprintf(writer, "334 \r\n")
				writer.Flush()
				authDataLine, err := reader.ReadString('\n')
				if err != nil {
					appendToStatus(fmt.Sprintf("Error reading PLAIN data: %v", err))
					logEvent("error", fmt.Sprintf("Error reading PLAIN data from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to read authentication data during AUTH PLAIN from client at %s: %v", remoteAddr, err))
					return
				}
				authData = strings.TrimSpace(authDataLine)
			}
			authBytes, err := base64.StdEncoding.DecodeString(authData)
			if err != nil {
				appendToStatus(fmt.Sprintf("Error decoding PLAIN data: %v", err))
				logEvent("error", fmt.Sprintf("Error decoding PLAIN data from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to decode base64-encoded data during AUTH PLAIN from client at %s: %v", remoteAddr, err))
				fmt.Fprintf(writer, "535 Authentication failed\r\n")
				writer.Flush()
				continue
			}
			authParts := strings.Split(string(authBytes), "\x00")
			if len(authParts) < 3 {
				appendToStatus("Invalid PLAIN response format")
				logEvent("error", fmt.Sprintf("Invalid PLAIN response format from %s", remoteAddr), fmt.Sprintf("Client at %s sent malformed data during AUTH PLAIN, missing required fields.", remoteAddr))
				fmt.Fprintf(writer, "535 Authentication failed\r\n")
				writer.Flush()
				continue
			}
			username := authParts[1]
			password := authParts[2]
			// Recommendation 5: Fix authentication comparison bug
			if username == config.SMTP.SMTPUsername && password == config.SMTP.SMTPPassword {
				authenticated = true
				appendToStatus("PLAIN Authentication successful")
				logEvent("smtp_auth_success", fmt.Sprintf("User %s authenticated successfully (PLAIN) from %s", username, remoteAddr), fmt.Sprintf("Client at %s provided valid credentials for user %s using AUTH PLAIN method, authentication granted.", remoteAddr, username))
				fmt.Fprintf(writer, "235 Authentication successful\r\n")
			} else {
				appendToStatus("PLAIN Authentication failed: Invalid credentials")
				logEvent("smtp_auth_failed", fmt.Sprintf("Failed authentication for user %s (PLAIN) from %s", username, remoteAddr), fmt.Sprintf("Client at %s provided invalid credentials for user %s using AUTH PLAIN method, authentication denied.", remoteAddr, username))
				fmt.Fprintf(writer, "535 Authentication failed\r\n")
			}
			writer.Flush()
		} else if strings.HasPrefix(line, "MAIL FROM:") {
			if !authenticated && config.SMTP.AuthRequired {
				appendToStatus("Rejecting MAIL command: Authentication required")
				logEvent("error", fmt.Sprintf("Rejecting MAIL command from %s: Authentication required", remoteAddr), fmt.Sprintf("Client at %s attempted MAIL FROM without authentication, rejected due to auth requirement.", remoteAddr))
				fmt.Fprintf(writer, "530 Authentication required\r\n")
				writer.Flush()
				continue
			}
			from = strings.TrimPrefix(line, "MAIL FROM:")
			from = strings.Trim(from, "<>")
			fmt.Fprintf(writer, "250 OK\r\n")
			writer.Flush()
			logEvent("smtp_command", fmt.Sprintf("MAIL FROM %s accepted from %s", from, remoteAddr), fmt.Sprintf("Client at %s specified sender address %s in MAIL FROM command, accepted by server.", remoteAddr, from))
		} else if strings.HasPrefix(line, "RCPT TO:") {
			if !authenticated && config.SMTP.AuthRequired {
				appendToStatus("Rejecting RCPT command: Authentication required")
				logEvent("error", fmt.Sprintf("Rejecting RCPT command from %s: Authentication required", remoteAddr), fmt.Sprintf("Client at %s attempted RCPT TO without authentication, rejected due to auth requirement.", remoteAddr))
				fmt.Fprintf(writer, "530 Authentication required\r\n")
				writer.Flush()
				continue
			}
			toAddr := strings.TrimPrefix(line, "RCPT TO:")
			toAddr = strings.Trim(toAddr, "<>")
			to = append(to, toAddr)
			fmt.Fprintf(writer, "250 OK\r\n")
			writer.Flush()
			logEvent("smtp_command", fmt.Sprintf("RCPT TO %s accepted from %s", toAddr, remoteAddr), fmt.Sprintf("Client at %s specified recipient address %s in RCPT TO command, accepted by server.", remoteAddr, toAddr))
		} else if line == "DATA" {
			if !authenticated && config.SMTP.AuthRequired {
				appendToStatus("Rejecting DATA command: Authentication required")
				logEvent("error", fmt.Sprintf("Rejecting DATA command from %s: Authentication required", remoteAddr), fmt.Sprintf("Client at %s attempted DATA without authentication, rejected due to auth requirement.", remoteAddr))
				fmt.Fprintf(writer, "530 Authentication required\r\n")
				writer.Flush()
				continue
			}
			fmt.Fprintf(writer, "354 Start mail input; end with <CRLF>.<CRLF>\r\n")
			writer.Flush()
			logEvent("smtp_command", fmt.Sprintf("DATA command received from %s", remoteAddr), fmt.Sprintf("Client at %s initiated DATA command to send email content, server ready to receive message body.", remoteAddr))
			for {
				dataLine, err := reader.ReadString('\n')
				if err != nil {
					appendToStatus(fmt.Sprintf("Error reading data: %v", err))
					logEvent("error", fmt.Sprintf("Error reading data from %s: %v", remoteAddr, err), fmt.Sprintf("Failed to read email content during DATA phase from client at %s: %v", remoteAddr, err))
					return
				}
				if dataLine == ".\r\n" {
					fmt.Fprintf(writer, "250 OK\r\n")
					writer.Flush()
					logEvent("smtp_command", fmt.Sprintf("DATA completed from %s", remoteAddr), fmt.Sprintf("Client at %s completed email content transmission with DATA command, server accepted the message.", remoteAddr))
					break
				}
				data.WriteString(dataLine)
			}
			emailData := parseEmail(from, to, data.String())
			if err := sendToGotify(config.Gotify, emailData); err != nil {
				appendToStatus(fmt.Sprintf("Failed to send to Gotify: %v", err))
				logEvent("gotify_failed", fmt.Sprintf("Failed to send to Gotify for email from %s: %v", emailData.From, err), fmt.Sprintf("Failed to forward email notification to Gotify server for email from %s to %s with subject '%s': %v", emailData.From, strings.Join(emailData.To, ", "), emailData.Subject, err))
			} else {
				appendToStatus(fmt.Sprintf("Successfully sent notification to Gotify for email from %s", emailData.From))
				logEvent("gotify_success", fmt.Sprintf("Successfully sent notification to Gotify for email from %s", emailData.From), fmt.Sprintf("Successfully forwarded email notification to Gotify server for email from %s to %s with subject '%s'.", emailData.From, strings.Join(emailData.To, ", "), emailData.Subject))
			}
		} else if line == "QUIT" {
			fmt.Fprintf(writer, "221 Bye\r\n")
			writer.Flush()
			appendToStatus(fmt.Sprintf("Client disconnected from %s", remoteAddr))
			logEvent("connection", fmt.Sprintf("Client disconnected from %s", remoteAddr), fmt.Sprintf("Client at %s sent QUIT command, server acknowledged and closed connection.", remoteAddr))
			return
		} else {
			fmt.Fprintf(writer, "500 Unknown command\r\n")
			writer.Flush()
			logEvent("error", fmt.Sprintf("Unknown command received from %s: %s", remoteAddr, line), fmt.Sprintf("Client at %s sent an unrecognized or unsupported SMTP command '%s', server responded with error.", remoteAddr, line))
		}
	}
}

// parseEmail extracts relevant information from the email
func parseEmail(from string, to []string, data string) EmailData {
	subject := "No Subject"
	body := data
	lines := strings.Split(data, "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "Subject:") {
			subject = strings.TrimPrefix(line, "Subject:")
			subject = strings.TrimSpace(subject)
			break
		}
	}
	bodyStart := strings.Index(data, "\r\n\r\n")
	if bodyStart != -1 {
		body = data[bodyStart+4:]
	}
	if len(body) > 5000 {
		body = body[:5000] + "... (truncated)"
	}
	return EmailData{
		From:    from,
		To:      to,
		Subject: subject,
		Body:    body,
	}
}

// sendToGotify sends the email content as a notification to Gotify with retry logic
func sendToGotify(config GotifyConfig, email EmailData) error {
	message := GotifyMessage{
		Title:    fmt.Sprintf("New Email: %s", email.Subject),
		Message:  fmt.Sprintf("From: %s\nTo: %s\n\n%s", email.From, strings.Join(email.To, ", "), email.Body),
		Priority: DefaultGotifyPriority,
	}
	jsonData, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("failed to marshal Gotify message: %v", err)
	}
	client := &http.Client{
		Timeout: GotifyTimeout,
	}
	url := fmt.Sprintf("%s/message?token=%s", strings.TrimSuffix(config.GotifyHost, "/"), config.GotifyToken)
	for attempt := 1; attempt <= GotifyMaxRetries; attempt++ {
		resp, err := client.Post(url, "application/json", bytes.NewBuffer(jsonData))
		if err != nil {
			logEvent("gotify_failed", fmt.Sprintf("Attempt %d/%d: Failed to send to Gotify for email from %s: %v", attempt, GotifyMaxRetries, email.From, err), fmt.Sprintf("Attempt %d of %d to send notification to Gotify at %s failed due to network or connection error: %v", attempt, GotifyMaxRetries, config.GotifyHost, err))
			if attempt == GotifyMaxRetries {
				return fmt.Errorf("failed to send to Gotify after %d attempts: %v", GotifyMaxRetries, err)
			}
			time.Sleep(time.Duration(attempt) * time.Second)
			continue
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			logEvent("gotify_failed", fmt.Sprintf("Attempt %d/%d: Gotify API returned non-OK status for email from %s: %d, body: %s", attempt, GotifyMaxRetries, email.From, resp.StatusCode, string(body)), fmt.Sprintf("Attempt %d of %d to send notification to Gotify at %s failed with HTTP status %d, response body: %s", attempt, GotifyMaxRetries, config.GotifyHost, resp.StatusCode, string(body)))
			if attempt == GotifyMaxRetries {
				return fmt.Errorf("Gotify API returned non-OK status: %d, body: %s", resp.StatusCode, string(body))
			}
			time.Sleep(time.Duration(attempt) * time.Second)
			continue
		}
		return nil
	}
	return fmt.Errorf("unexpected error in Gotify send loop")
}

// loadConfig loads the configuration from the YAML file or environment variables
func loadConfig() (AppConfig, error) {
	viper.SetConfigName("config")
	viper.SetConfigType("yaml")
	viper.AddConfigPath(configDirPath)
	viper.AddConfigPath(".")
	viper.SetDefault("smtp.addr", DefaultSMTPPort)
	viper.SetDefault("smtp.domain", DefaultSMTPDomain)
	viper.SetDefault("smtp.smtp_username", DefaultSMTPUser)
	viper.SetDefault("smtp.smtp_password", DefaultSMTPPass)
	viper.SetDefault("smtp.auth_required", true)
	viper.SetDefault("gotify.gotify_host", DefaultGotifyHost)
	viper.SetDefault("gotify.gotify_token", "")
	viper.AutomaticEnv()
	viper.SetEnvPrefix("SMTP_TO_GOTIFY")
	viper.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	err := viper.ReadInConfig()
	if err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); ok {
			err = saveConfig()
			if err != nil {
				return AppConfig{}, fmt.Errorf("failed to create config file: %v", err)
			}
		} else {
			return AppConfig{}, fmt.Errorf("failed to read config: %v", err)
		}
	}
	var config AppConfig
	err = viper.Unmarshal(&config)
	if err != nil {
		return AppConfig{}, fmt.Errorf("failed to unmarshal config: %v", err)
	}
	return config, nil
}

// saveConfig saves the current configuration to the YAML file
func saveConfig() error {
	if err := os.MkdirAll(configDirPath, 0750); err != nil {
		return fmt.Errorf("failed to create config directory: %v", err)
	}
	viper.SetConfigFile(configFilePath)
	if err := viper.WriteConfig(); err != nil {
		return fmt.Errorf("failed to write config file: %v", err)
	}
	if err := os.Chmod(configFilePath, 0640); err != nil {
		// Silently ignore permission setting error
	}
	return nil
}

// UI Types and Messages
type StatusUpdateMsg struct{}
type LogUpdateMsg struct {
	Entry LogEntry
}
type LogLoadedMsg struct {
	Entries []LogEntry
	Err     error
}
type ServiceCmdMsg struct {
	Output string
	Err    error
}
type tickMsg time.Time

// Custom Item type for list.Model
type MenuItem struct {
	title       string
	description string
}

func (i MenuItem) Title() string       { return i.title }
func (i MenuItem) Description() string { return i.description }
func (i MenuItem) FilterValue() string { return i.title }

// BannerModel holds the state for the animated banner (Matrix + Cube)
type BannerModel struct {
	MatrixColumns [][]rune // 2D slice for Matrix characters (column-wise)
	MatrixOffsets []int    // Falling offset for each column
	MatrixSpeeds  []int    // Speed for each column (ticks until next move)
	MatrixTicks   []int    // Tick counter for each column
	CubeFrame     int      // Current frame of cube rotation
	CubeTick      int      // Tick counter for cube animation
	Width         int      // Dynamic width based on terminal
	Height        int      // Dynamic height based on terminal
}

// newBannerModel creates and initializes a new BannerModel
func newBannerModel(width, height int) BannerModel {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	m := BannerModel{
		MatrixColumns: make([][]rune, width),
		MatrixOffsets: make([]int, width),
		MatrixSpeeds:  make([]int, width),
		MatrixTicks:   make([]int, width),
		CubeFrame:     0,
		CubeTick:      0,
		Width:         width,
		Height:        height,
	}
	for x := 0; x < width; x++ {
		m.MatrixColumns[x] = make([]rune, height)
		for y := 0; y < height; y++ {
			if rand.Float32() < 0.2 {
				m.MatrixColumns[x][y] = randomChar()
			} else {
				m.MatrixColumns[x][y] = ' '
			}
		}
		m.MatrixOffsets[x] = rand.Intn(height) // Random starting offset
		m.MatrixSpeeds[x] = rand.Intn(3) + 1   // Speed between 1-3 ticks
		m.MatrixTicks[x] = 0
	}
	return m
}

// randomChar returns a random alphanumeric or symbol character for the Matrix effect
func randomChar() rune {
	chars := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!@#$%^&*()"
	return rune(chars[rand.Intn(len(chars))])
}

// AppModel holds the overall application state
type AppModel struct {
	CurrentScreen   string
	Width           int
	Height          int
	MainMenu        list.Model
	LoggingMenu     list.Model
	ServiceMenu     list.Model
	ProgramConfigs  list.Model
	SMTPConfigs     list.Model
	GotifyConfigs   list.Model
	LogViewer       LogViewerModel
	InputModel      InputModel
	StatusViewport  viewport.Model
	StatusText      string
	Quit            bool
	StartServer     bool
	Help            help.Model
	Keys            KeyMap
	QuitConfirm     bool
	Banner          BannerModel
}

// LogViewerModel for viewing logs with pagination
type LogViewerModel struct {
	Viewport       viewport.Model
	Entries        []LogEntry
	CategoryFilter string
	CurrentPage    int
	PageSize       int
	TotalPages     int
	Loading        bool
	BackScreen     string
	Width          int
	Height         int
}

// RenderPage renders the current page of logs in the viewport
func (m *LogViewerModel) RenderPage() {
	if len(m.Entries) == 0 {
		m.Viewport.SetContent(color.YellowString("No logs found for this category."))
		return
	}
	start := m.CurrentPage * m.PageSize
	end := start + m.PageSize
	if end > len(m.Entries) {
		end = len(m.Entries)
	}
	var content strings.Builder
	content.WriteString(fmt.Sprintf("Page %d/%d (p/←=prev, n/→=next, r=refresh, esc=back, q=quit)\n\n", m.CurrentPage+1, m.TotalPages))
	for i := start; i < end; i++ {
		entry := m.Entries[i]
		var categoryColor string
		switch {
			case strings.HasPrefix(entry.Category, "smtp_auth_failed"):
				categoryColor = "\033[31m" // Red
			case strings.HasPrefix(entry.Category, "smtp_auth_success"):
				categoryColor = "\033[32m" // Green
			case strings.HasPrefix(entry.Category, "gotify_failed"):
				categoryColor = "\033[31m" // Red
			case strings.HasPrefix(entry.Category, "gotify_success"):
				categoryColor = "\033[32m" // Green
			case entry.Category == "error":
				categoryColor = "\033[31m" // Red
			default:
				categoryColor = "\033[0m" // Reset
		}
		timestamp := color.BlueString(entry.Timestamp)
		cat := fmt.Sprintf("%s%-20s\033[0m", categoryColor, strings.ToUpper(strings.ReplaceAll(entry.Category, "_", " ")))
		message := entry.Message
		desc := entry.Description
		if len(desc) > 100 {
			desc = desc[:100] + "..."
		}
		content.WriteString(fmt.Sprintf("%d. [%s] | %s | %s\n    Desc: %s\n", i+1, timestamp, cat, message, desc))
	}
	m.Viewport.SetContent(content.String())
}

// InputModel for handling configuration input fields
type InputModel struct {
	TextInput   textinput.Model
	FieldName   string
	IsPassword  bool
	ErrorMsg    string
	BackScreen  string
	SaveAction  bool
}

// KeyMap defines keybindings for the application
type KeyMap struct {
	Up      key.Binding
	Down    key.Binding
	Quit    key.Binding
	Enter   key.Binding
	Back    key.Binding
	Help    key.Binding
	NextPg  key.Binding
	PrevPg  key.Binding
	Refresh key.Binding
}

func (k KeyMap) ShortHelp() []key.Binding {
	return []key.Binding{k.Up, k.Down, k.Enter, k.Back, k.Quit, k.Help}
}

func (k KeyMap) FullHelp() [][]key.Binding {
	return [][]key.Binding{
		{k.Up, k.Down, k.Enter, k.Back},
		{k.NextPg, k.PrevPg, k.Refresh, k.Quit, k.Help},
	}
}

var DefaultKeyMap = KeyMap{
	Up:      key.NewBinding(key.WithKeys("up", "k"), key.WithHelp("↑/k", "move up")),
	Down:    key.NewBinding(key.WithKeys("down", "j"), key.WithHelp("↓/j", "move down")),
	Quit:    key.NewBinding(key.WithKeys("q", "ctrl+c"), key.WithHelp("q/ctrl+c", "quit")),
	Enter:   key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "select")),
	Back:    key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "back")),
	Help:    key.NewBinding(key.WithKeys("?"), key.WithHelp("?", "toggle help")),
	NextPg:  key.NewBinding(key.WithKeys("n", "right"), key.WithHelp("n/→", "next page")),
	PrevPg:  key.NewBinding(key.WithKeys("p", "left"), key.WithHelp("p/←", "prev page")),
	Refresh: key.NewBinding(key.WithKeys("r"), key.WithHelp("r", "refresh logs")),
}

// Styles for UI rendering
var (
	titleStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(ColorWhite)).Padding(0, 1)
	statusStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorBrightYellow)).Padding(0, 1).Border(lipgloss.NormalBorder(), true)
	errorStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorRed)).Padding(0, 1)
	selectedStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorBrightGreen)).Bold(true)
	bannerStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorWhite)).Padding(0, 1).Align(lipgloss.Right)
	helpStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorGray)).Padding(0, 1)
	confirmStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorWhite)).Background(lipgloss.Color(ColorRed)).Bold(true).Padding(1, 2).Align(lipgloss.Center)
	matrixStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorMatrixGreen)) // Terminal Green for Matrix
	cubeStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color(ColorCubeRed))     // Crimson Red for Cube
)

// renderBanner renders the animated banner (Matrix + Cube)
func (m *AppModel) renderBanner() string {
	bm := m.Banner
	if bm.Width == 0 || bm.Height == 0 {
		return bannerStyle.Width(m.Width).Render("SMTP to Gotify v1.1")
	}
	// Create a 2D buffer for rendering content
	buffer := make([][]rune, bm.Height)
	for y := 0; y < bm.Height; y++ {
		buffer[y] = make([]rune, bm.Width)
		for x := 0; x < bm.Width; x++ {
			if x < len(bm.MatrixColumns) && y < len(bm.MatrixColumns[x]) {
				colY := (y + bm.MatrixOffsets[x]) % bm.Height
				buffer[y][x] = bm.MatrixColumns[x][colY]
			} else {
				buffer[y][x] = ' '
			}
		}
	}
	// Define the cube animation frames (compact to fit within matrix size)
	cubeFrames := [][]string{
		// Frame 0: Front-facing isometric
		{
			`****`,
			`*    *`,
			`S`,
			`*   G  *`,
			`*   R  *`,
			`****`,
		},
		// Frame 1: Slightly rotated right
		{
			`****`,
			`*    *`,
			`S`,
			`G`,
			`R`,
			`**`,
		},
		// Frame 2: Side view
		{
			`****`,
			`S`,
			`G`,
			`R`,
			`*  *`,
			`**`,
		},
		// Frame 3: Slightly rotated left
		{
			`****`,
			`*    *`,
			`S`,
			`*   G *`,
			`*  R  *`,
			`**`,
		},
	}
	// Select the current frame for the cube
	currentCube := cubeFrames[bm.CubeFrame]
	// Overlay the cube on the Matrix background (centered)
	cubeWidth := len(currentCube[0])
	cubeHeight := len(currentCube)
	startX := (bm.Width - cubeWidth) / 2
	if startX < 0 {
		startX = 0
	}
	startY := (bm.Height - cubeHeight) / 2
	if startY < 0 {
		startY = 0
	}
	// Build the final string with colors applied
	var sb strings.Builder
	for y := 0; y < bm.Height; y++ {
		line := make([]string, bm.Width)
		for x := 0; x < bm.Width; x++ {
			char := string(buffer[y][x])
			// Check if this position is part of the cube
			cubeChar := false
			if y >= startY && y < startY+cubeHeight && y < bm.Height && x >= startX && x < startX+cubeWidth && x < bm.Width {
				cy := y - startY
				cx := x - startX
				if cy < len(currentCube) && cx < len(currentCube[cy]) && rune(currentCube[cy][cx]) != ' ' {
					line[x] = cubeStyle.Render(string(rune(currentCube[cy][cx])))
					cubeChar = true
				}
			}
			if !cubeChar && char != " " {
				line[x] = matrixStyle.Render(char)
			} else if !cubeChar {
				line[x] = char
			}
		}
		sb.WriteString(strings.Join(line, ""))
		if y < bm.Height-1 {
			sb.WriteString("\n")
		}
	}
	return bannerStyle.Width(m.Width).Render(sb.String())
}

// Init initializes the AppModel
func (m AppModel) Init() tea.Cmd {
	// Initialize random seed for banner animation
	rand.Seed(time.Now().UnixNano())
	// Initialize banner model with dynamic dimensions
	bannerWidth := m.Width / 2
	if bannerWidth < 20 {
		bannerWidth = 20
	}
	bannerHeight := m.Height / 3
	if bannerHeight < 8 {
		bannerHeight = 8
	}
	m.Banner = newBannerModel(bannerWidth, bannerHeight)
	// Start the animation ticker for banner
	return tea.Tick(time.Second/MatrixFPS, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// Recommendation 3: Add input validation for configuration fields in Update method
func (m AppModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	switch msg := msg.(type) {
		case tea.WindowSizeMsg:
			m.Width = msg.Width
			m.Height = msg.Height
			listHeight := m.Height - 10
			if listHeight < 8 {
				listHeight = 8
			}
			m.MainMenu.SetSize(m.Width-2, listHeight)
			m.LoggingMenu.SetSize(m.Width-2, listHeight)
			m.ProgramConfigs.SetSize(m.Width-2, listHeight)
			m.SMTPConfigs.SetSize(m.Width-2, listHeight)
			m.GotifyConfigs.SetSize(m.Width-2, listHeight)
			m.ServiceMenu.SetSize(m.Width-2, listHeight)
			m.LogViewer.Width = m.Width - 2
			m.LogViewer.Height = listHeight
			m.LogViewer.Viewport = viewport.New(m.Width-2, listHeight)
			if !m.LogViewer.Loading {
				m.LogViewer.RenderPage()
			}
			statusHeight := 4
			if statusHeight > m.Height-6 {
				statusHeight = m.Height - 6
			}
			if statusHeight < 2 {
				statusHeight = 2
			}
			// Preserve existing content in StatusViewport while updating size
			m.StatusViewport = viewport.New(m.Width-2, statusHeight)
			m.StatusViewport.SetContent(m.StatusText)
			m.StatusViewport.GotoBottom()
			// Update banner dimensions dynamically
			bannerWidth := m.Width / 2
			if bannerWidth < 20 {
				bannerWidth = 20
			}
			bannerHeight := m.Height / 3
			if bannerHeight < 8 {
				bannerHeight = 8
			}
			if m.Banner.Width != bannerWidth || m.Banner.Height != bannerHeight {
				m.Banner = newBannerModel(bannerWidth, bannerHeight)
			}
		case tickMsg:
			// Update Matrix animation
			for x := 0; x < m.Banner.Width; x++ {
				m.Banner.MatrixTicks[x]++
				if m.Banner.MatrixTicks[x] >= m.Banner.MatrixSpeeds[x] {
					m.Banner.MatrixTicks[x] = 0
					// Shift characters down by increasing offset
					m.Banner.MatrixOffsets[x] = (m.Banner.MatrixOffsets[x] + 1) % m.Banner.Height
					// Occasionally refresh characters in the column
					if rand.Float32() < 0.1 {
						for y := 0; y < m.Banner.Height; y++ {
							if rand.Float32() < 0.2 {
								m.Banner.MatrixColumns[x][y] = randomChar()
							} else {
								m.Banner.MatrixColumns[x][y] = ' '
							}
						}
					}
				}
			}
			// Update cube rotation animation (slower than Matrix)
			m.Banner.CubeTick++
			if m.Banner.CubeTick >= (MatrixFPS / CubeFPS) {
				m.Banner.CubeTick = 0
				m.Banner.CubeFrame = (m.Banner.CubeFrame + 1) % CubeFrameCount // Cycle through frames
			}
			// Continue the ticker for the next frame
			return m, tea.Tick(time.Second/MatrixFPS, func(t time.Time) tea.Msg {
				return tickMsg(t)
			})
		case tea.KeyMsg:
			if m.QuitConfirm {
				switch msg.String() {
					case "y", "Y", "enter":
						m.Quit = true
						return m, tea.Quit
					default:
						m.QuitConfirm = false
				}
				return m, nil
			}
			if key.Matches(msg, m.Keys.Quit) {
				m.QuitConfirm = true
				return m, nil
			}
			if key.Matches(msg, m.Keys.Help) {
				m.Help.ShowAll = !m.Help.ShowAll
				return m, nil
			}
			switch m.CurrentScreen {
				case "MainMenu":
					if key.Matches(msg, m.Keys.Enter) {
						selected := m.MainMenu.SelectedItem()
						if selected != nil {
							item := selected.(MenuItem)
							switch item.Title() {
								case "Logging":
									m.CurrentScreen = "Logging"
								case "Service Management":
									m.CurrentScreen = "ServiceMenu"
								case "Program Configs":
									m.CurrentScreen = "ProgramConfigs"
								case "Apply Config and Exit":
									go func() {
										if err := saveConfig(); err != nil {
											appendToStatus(color.RedString("Failed to save config: %v", err))
											return
										}
										appendToStatus("Stopping smtp-to-gotify service...")
										stopCmd := exec.Command("systemctl", "stop", "smtp-to-gotify")
										stopOutput, stopErr := stopCmd.CombinedOutput()
										if stopErr != nil {
											appendToStatus(color.RedString("Failed to stop service: %v, output: %s", stopErr, string(stopOutput)))
											return
										}
										appendToStatus(color.GreenString("Service stopped successfully"))
										appendToStatus("Starting smtp-to-gotify service with updated config...")
										startCmd := exec.Command("systemctl", "start", "smtp-to-gotify")
										startOutput, startErr := startCmd.CombinedOutput()
										if startErr != nil {
											appendToStatus(color.RedString("Failed to start service: %v, output: %s", startErr, string(startOutput)))
											return
										}
										appendToStatus(color.GreenString("Service started successfully with updated config"))
										m.Quit = true
									}()
								case "Exit without Starting":
									m.Quit = true
									return m, tea.Quit
							}
						}
					} else {
						m.MainMenu, cmd = m.MainMenu.Update(msg)
					}
								case "Logging":
									if key.Matches(msg, m.Keys.Enter) {
										selected := m.LoggingMenu.SelectedItem()
										if selected != nil {
											item := selected.(MenuItem)
											switch item.Title() {
												case "Back to Main Menu":
													m.CurrentScreen = "MainMenu"
												case "SMTP Authentication":
													m.LogViewer = LogViewerModel{
														Viewport:       viewport.New(m.Width-2, m.Height-10),
														CategoryFilter: "smtp_auth",
														PageSize:       20,
														CurrentPage:    0,
														Loading:        true,
														BackScreen:     "Logging",
														Width:          m.Width - 2,
														Height:         m.Height - 10,
													}
													m.CurrentScreen = "LogViewer"
													return m, loadLogsCmd(m.LogViewer.CategoryFilter)
												case "Gotify Logs":
													m.LogViewer = LogViewerModel{
														Viewport:       viewport.New(m.Width-2, m.Height-10),
														CategoryFilter: "gotify",
														PageSize:       20,
														CurrentPage:    0,
														Loading:        true,
														BackScreen:     "Logging",
														Width:          m.Width - 2,
														Height:         m.Height - 10,
													}
													m.CurrentScreen = "LogViewer"
													return m, loadLogsCmd(m.LogViewer.CategoryFilter)
												case "All Logs":
													m.LogViewer = LogViewerModel{
														Viewport:       viewport.New(m.Width-2, m.Height-10),
														CategoryFilter: "all",
														PageSize:       20,
														CurrentPage:    0,
														Loading:        true,
														BackScreen:     "Logging",
														Width:          m.Width - 2,
														Height:         m.Height - 10,
													}
													m.CurrentScreen = "LogViewer"
													return m, loadLogsCmd(m.LogViewer.CategoryFilter)
											}
										}
									} else if key.Matches(msg, m.Keys.Back) {
										m.CurrentScreen = "MainMenu"
									} else {
										m.LoggingMenu, cmd = m.LoggingMenu.Update(msg)
									}
												case "ProgramConfigs":
													if key.Matches(msg, m.Keys.Enter) {
														selected := m.ProgramConfigs.SelectedItem()
														if selected != nil {
															item := selected.(MenuItem)
															switch item.Title() {
																case "SMTP Configs":
																	m.CurrentScreen = "SMTPConfigs"
																case "Gotify Configs":
																	m.CurrentScreen = "GotifyConfigs"
																case "Back to Main Menu":
																	m.CurrentScreen = "MainMenu"
															}
														}
													} else if key.Matches(msg, m.Keys.Back) {
														m.CurrentScreen = "MainMenu"
													} else {
														m.ProgramConfigs, cmd = m.ProgramConfigs.Update(msg)
													}
																case "SMTPConfigs":
																	if key.Matches(msg, m.Keys.Enter) {
																		selected := m.SMTPConfigs.SelectedItem()
																		if selected != nil {
																			item := selected.(MenuItem)
																			switch item.Title() {
																				case "Back to Program Configs":
																					m.CurrentScreen = "ProgramConfigs"
																				default:
																					fieldName := strings.ToLower(strings.ReplaceAll(item.Title(), " ", "_"))
																					configField := map[string]string{
																						"smtp_domain":   "smtp.domain",
																						"smtp_port":     "smtp.addr",
																						"smtp_username": "smtp.smtp_username",
																						"smtp_password": "smtp.smtp_password",
																					}[fieldName]
																					if configField == "" {
																						appendToStatus(color.RedString("Unknown field: %s", fieldName))
																						break
																					}
																					initialValue := viper.GetString(configField)
																					isPassword := fieldName == "smtp_password"
																					m.InputModel = InputModel{
																						TextInput:  textinput.New(),
																						FieldName:  configField,
																						IsPassword: isPassword,
																						BackScreen: "SMTPConfigs",
																					}
																					m.InputModel.TextInput.SetValue(initialValue)
																					if isPassword {
																						m.InputModel.TextInput.EchoMode = textinput.EchoPassword
																					}
																					m.InputModel.TextInput.Focus()
																					m.CurrentScreen = "Input"
																			}
																		}
																	} else if key.Matches(msg, m.Keys.Back) {
																		m.CurrentScreen = "ProgramConfigs"
																	} else {
																		m.SMTPConfigs, cmd = m.SMTPConfigs.Update(msg)
																	}
																				case "GotifyConfigs":
																					if key.Matches(msg, m.Keys.Enter) {
																						selected := m.GotifyConfigs.SelectedItem()
																						if selected != nil {
																							item := selected.(MenuItem)
																							switch item.Title() {
																								case "Back to Program Configs":
																									m.CurrentScreen = "ProgramConfigs"
																								default:
																									fieldName := strings.ToLower(strings.ReplaceAll(item.Title(), " ", "_"))
																									configField := map[string]string{
																										"gotify_host":  "gotify.gotify_host",
																										"gotify_token": "gotify.gotify_token",
																									}[fieldName]
																									if configField == "" {
																										appendToStatus(color.RedString("Unknown field: %s", fieldName))
																										break
																									}
																									initialValue := viper.GetString(configField)
																									isPassword := fieldName == "gotify_token"
																									m.InputModel = InputModel{
																										TextInput:  textinput.New(),
																										FieldName:  configField,
																										IsPassword: isPassword,
																										BackScreen: "GotifyConfigs",
																									}
																									m.InputModel.TextInput.SetValue(initialValue)
																									if isPassword {
																										m.InputModel.TextInput.EchoMode = textinput.EchoPassword
																									}
																									m.InputModel.TextInput.Focus()
																									m.CurrentScreen = "Input"
																							}
																						}
																					} else if key.Matches(msg, m.Keys.Back) {
																						m.CurrentScreen = "ProgramConfigs"
																					} else {
																						m.GotifyConfigs, cmd = m.GotifyConfigs.Update(msg)
																					}
																								case "ServiceMenu":
																									if key.Matches(msg, m.Keys.Enter) {
																										selected := m.ServiceMenu.SelectedItem()
																										if selected != nil {
																											item := selected.(MenuItem)
																											switch item.Title() {
																												case "Back to Main Menu":
																													m.CurrentScreen = "MainMenu"
																												case "Stop Service":
																													go func() {
																														appendToStatus("Stopping smtp-to-gotify service...")
																														cmd := exec.Command("systemctl", "stop", "smtp-to-gotify")
																														output, err := cmd.CombinedOutput()
																														// Recommendation 10: Improved error handling for systemctl commands
																														if err != nil {
																															appendToStatus(color.RedString("Failed to stop service: %v, output: %s", err, string(output)))
																															logEvent("error", fmt.Sprintf("Failed to stop service: %v", err), fmt.Sprintf("systemctl stop command failed with output: %s", string(output)))
																														} else {
																															appendToStatus(color.GreenString("Service stopped successfully"))
																														}
																													}()
																												case "Start Service":
																													go func() {
																														appendToStatus("Starting smtp-to-gotify service...")
																														cmd := exec.Command("systemctl", "start", "smtp-to-gotify")
																														output, err := cmd.CombinedOutput()
																														// Recommendation 10: Improved error handling for systemctl commands
																														if err != nil {
																															appendToStatus(color.RedString("Failed to start service: %v, output: %s", err, string(output)))
																															logEvent("error", fmt.Sprintf("Failed to start service: %v", err), fmt.Sprintf("systemctl start command failed with output: %s", string(output)))
																														} else {
																															appendToStatus(color.GreenString("Service started successfully"))
																														}
																													}()
																												case "Apply Config and Restart Service":
																													go func() {
																														if err := saveConfig(); err != nil {
																															appendToStatus(color.RedString("Failed to save config: %v", err))
																															return
																														}
																														appendToStatus("Restarting smtp-to-gotify service...")
																														cmd := exec.Command("systemctl", "restart", "smtp-to-gotify")
																														output, err := cmd.CombinedOutput()
																														// Recommendation 10: Improved error handling for systemctl commands
																														if err != nil {
																															appendToStatus(color.RedString("Failed to restart service: %v, output: %s", err, string(output)))
																															logEvent("error", fmt.Sprintf("Failed to restart service: %v", err), fmt.Sprintf("systemctl restart command failed with output: %s", string(output)))
																														} else {
																															appendToStatus(color.GreenString("Service restarted successfully"))
																														}
																													}()
																												case "Service Status":
																													go func() {
																														appendToStatus("Fetching smtp-to-gotify service status...")
																														cmd := exec.Command("systemctl", "status", "smtp-to-gotify")
																														output, err := cmd.CombinedOutput()
																														// Recommendation 10: Improved error handling for systemctl commands
																														if err != nil {
																															appendToStatus(color.RedString("Failed to fetch service status: %v", err))
																															logEvent("error", fmt.Sprintf("Failed to fetch service status: %v", err), fmt.Sprintf("systemctl status command failed with output: %s", string(output)))
																														} else {
																															outStr := string(output)
																															if len(outStr) > 500 {
																																outStr = outStr[:500] + "... (truncated)"
																															}
																															appendToStatus(color.CyanString("Service Status:\n%s", outStr))
																														}
																													}()
																											}
																										}
																									} else if key.Matches(msg, m.Keys.Back) {
																										m.CurrentScreen = "MainMenu"
																									} else {
																										m.ServiceMenu, cmd = m.ServiceMenu.Update(msg)
																									}
																												case "LogViewer":
																													if key.Matches(msg, m.Keys.Back) {
																														m.CurrentScreen = m.LogViewer.BackScreen
																													} else if key.Matches(msg, m.Keys.PrevPg) {
																														if m.LogViewer.CurrentPage > 0 {
																															m.LogViewer.CurrentPage--
																															m.LogViewer.RenderPage()
																														}
																													} else if key.Matches(msg, m.Keys.NextPg) {
																														if m.LogViewer.CurrentPage < m.LogViewer.TotalPages-1 {
																															m.LogViewer.CurrentPage++
																															m.LogViewer.RenderPage()
																														}
																													} else if key.Matches(msg, m.Keys.Refresh) {
																														m.LogViewer.Loading = true
																														return m, loadLogsCmd(m.LogViewer.CategoryFilter)
																													} else if key.Matches(msg, m.Keys.Up) {
																														m.LogViewer.Viewport.LineUp(1)
																													} else if key.Matches(msg, m.Keys.Down) {
																														m.LogViewer.Viewport.LineDown(1)
																													}
																												case "Input":
																													m.InputModel.TextInput, cmd = m.InputModel.TextInput.Update(msg)
																													if key.Matches(msg, m.Keys.Back) {
																														m.CurrentScreen = m.InputModel.BackScreen
																													} else if key.Matches(msg, m.Keys.Enter) {
																														m.InputModel.SaveAction = true
																														value := m.InputModel.TextInput.Value()
																														// Recommendation 3: Enhanced input validation for configuration fields
																														if m.InputModel.FieldName == "smtp.addr" {
																															if !strings.HasPrefix(value, ":") && !strings.Contains(value, ":") {
																																m.InputModel.ErrorMsg = "Invalid address format, must include port (e.g., :2525)"
																																return m, nil
																															}
																															viper.Set(m.InputModel.FieldName, value)
																														} else if m.InputModel.FieldName == "gotify.gotify_host" {
																															if !strings.HasPrefix(value, "http://") && !strings.HasPrefix(value, "https://") {
																																m.InputModel.ErrorMsg = "Invalid host format, must start with http:// or https://"
																																return m, nil
																															}
																															viper.Set(m.InputModel.FieldName, value)
																														} else if m.InputModel.FieldName == "smtp.smtp_username" {
																															if len(value) < 1 || len(value) > 50 || strings.ContainsAny(value, " \t\r\n") {
																																m.InputModel.ErrorMsg = "Invalid username, must be 1-50 characters without spaces or newlines"
																																return m, nil
																															}
																															viper.Set(m.InputModel.FieldName, value)
																														} else if m.InputModel.FieldName == "smtp.smtp_password" {
																															if len(value) < 1 || len(value) > 100 {
																																m.InputModel.ErrorMsg = "Invalid password, must be 1-100 characters"
																																return m, nil
																															}
																															viper.Set(m.InputModel.FieldName, value)
																														} else if m.InputModel.FieldName == "smtp.domain" {
																															if len(value) < 1 || len(value) > 100 || strings.ContainsAny(value, " \t\r\n") {
																																m.InputModel.ErrorMsg = "Invalid domain, must be 1-100 characters without spaces or newlines"
																																return m, nil
																															}
																															viper.Set(m.InputModel.FieldName, value)
																														} else if m.InputModel.FieldName == "gotify.gotify_token" {
																															if len(value) < 1 || len(value) > 200 {
																																m.InputModel.ErrorMsg = "Invalid token, must be 1-200 characters"
																																return m, nil
																															}
																															viper.Set(m.InputModel.FieldName, value)
																														} else {
																															viper.Set(m.InputModel.FieldName, value)
																														}
																														appendToStatus(color.GreenString("Updated %s successfully", strings.Title(strings.ReplaceAll(strings.Split(m.InputModel.FieldName, ".")[1], "_", " "))))
																														m.CurrentScreen = m.InputModel.BackScreen
																													}
			}
			case StatusUpdateMsg:
				appMutex.Lock()
				statusText := strings.Join(statusLog, "\n")
				appMutex.Unlock()
				m.StatusText = statusText
				m.StatusViewport.SetContent(m.StatusText)
				m.StatusViewport.GotoBottom()
			case LogUpdateMsg:
				if m.CurrentScreen == "LogViewer" {
					if m.LogViewer.CategoryFilter == "all" || strings.HasPrefix(msg.Entry.Category, m.LogViewer.CategoryFilter) {
						m.LogViewer.Entries = append(m.LogViewer.Entries, msg.Entry)
						m.LogViewer.TotalPages = (len(m.LogViewer.Entries) + m.LogViewer.PageSize - 1) / m.LogViewer.PageSize
						if m.LogViewer.TotalPages == 0 {
							m.LogViewer.TotalPages = 1
						}
						m.LogViewer.RenderPage()
					}
				}
			case LogLoadedMsg:
				if msg.Err != nil {
					m.LogViewer.Loading = false
					m.LogViewer.Viewport.SetContent(color.RedString("Failed to load logs: %v", msg.Err))
					fmt.Fprintf(os.Stderr, "Debug: Log load error in UI: %v\n", msg.Err)
					return m, nil
				}
				m.LogViewer.Entries = msg.Entries
				m.LogViewer.TotalPages = (len(msg.Entries) + m.LogViewer.PageSize - 1) / m.LogViewer.PageSize
				if m.LogViewer.TotalPages == 0 {
					m.LogViewer.TotalPages = 1
				}
				m.LogViewer.Loading = false
				fmt.Fprintf(os.Stderr, "Debug: Loaded %d log entries into UI, total pages: %d\n", len(msg.Entries), m.LogViewer.TotalPages)
				m.LogViewer.RenderPage()
	}
	return m, cmd
}

// View renders the UI
func (m AppModel) View() string {
	var content string
	// Calculate help text height with a minimum to ensure it's always visible
	helpText := m.Help.View(m.Keys)
	helpHeight := strings.Count(helpText, "\n") + 1
	if helpHeight < 2 {
		helpHeight = 2
	}
	// Calculate banner height with a minimum
	banner := m.renderBanner()
	bannerHeight := strings.Count(banner, "\n") + 1
	if bannerHeight < 2 {
		bannerHeight = 2
	}
	// Calculate title height
	title := titleStyle.Render(fmt.Sprintf("SMTP to Gotify Forwarder - %s", m.CurrentScreen))
	titleHeight := 1
	// Calculate status height with a minimum to ensure visibility
	status := statusStyle.Width(m.Width - 2).Render("Status:\n" + m.StatusViewport.View())
	statusHeight := strings.Count(status, "\n") + 1
	if statusHeight < 3 {
		statusHeight = 3
	}
	// Ensure status height does not exceed available space
	totalFixedHeight := bannerHeight + titleHeight + statusHeight + helpHeight
	if totalFixedHeight > m.Height {
		// Reduce status height if necessary to fit within terminal height
		statusHeight = m.Height - bannerHeight - titleHeight - helpHeight
		if statusHeight < 2 {
			statusHeight = 2
			helpHeight = m.Height - bannerHeight - titleHeight - statusHeight
			if helpHeight < 1 {
				helpHeight = 1
			}
		}
		// Update status viewport height if changed
		m.StatusViewport = viewport.New(m.Width-2, statusHeight)
		m.StatusViewport.SetContent(m.StatusText)
		m.StatusViewport.GotoBottom()
		status = statusStyle.Width(m.Width - 2).Render("Status:\n" + m.StatusViewport.View())
	}
	if m.QuitConfirm {
		confirmMsg := confirmStyle.Width(m.Width - 2).Render("Are you sure you want to quit? (y/N)")
		confirmHeight := strings.Count(confirmMsg, "\n") + 2
		if confirmHeight < 3 {
			confirmHeight = 3
		}
		availableHeight := m.Height - bannerHeight - titleHeight - confirmHeight - statusHeight - helpHeight
		if availableHeight < 3 {
			availableHeight = 3
		}
		// Ensure the main content area overwrites previous content, set default foreground
		mainContent := lipgloss.NewStyle().Width(m.Width-2).Height(availableHeight).Foreground(lipgloss.Color(ColorWhite)).Render("")
		return lipgloss.JoinVertical(lipgloss.Top, banner, title, mainContent, confirmMsg, status, helpText)
	}
	switch m.CurrentScreen {
		case "MainMenu":
			content = m.MainMenu.View()
		case "Logging":
			content = m.LoggingMenu.View()
		case "ProgramConfigs":
			content = m.ProgramConfigs.View()
		case "SMTPConfigs":
			content = m.SMTPConfigs.View()
		case "GotifyConfigs":
			content = m.GotifyConfigs.View()
		case "ServiceMenu":
			content = m.ServiceMenu.View()
		case "LogViewer":
			if m.LogViewer.Loading {
				content = "Loading logs...\n\n" + m.LogViewer.Viewport.View()
			} else {
				content = m.LogViewer.Viewport.View()
			}
		case "Input":
			content = fmt.Sprintf("Enter value for %s:\n\n%s\n", strings.Title(strings.ReplaceAll(strings.Split(m.InputModel.FieldName, ".")[1], "_", " ")), m.InputModel.TextInput.View())
			if m.InputModel.ErrorMsg != "" {
				content += errorStyle.Render(m.InputModel.ErrorMsg) + "\n"
			}
			content += "\n(Enter to save, Esc to cancel)"
	}
	availableHeight := m.Height - bannerHeight - titleHeight - statusHeight - helpHeight
	if availableHeight < 3 {
		availableHeight = 3
	}
	// Ensure main content area fully overwrites previous content with default foreground
	mainContent := lipgloss.NewStyle().Width(m.Width-2).Height(availableHeight).Foreground(lipgloss.Color(ColorWhite)).Render(content)
	return lipgloss.JoinVertical(lipgloss.Top, banner, title, mainContent, status, helpText)
}

// loadLogsCmd loads logs asynchronously
func loadLogsCmd(categoryFilter string) tea.Cmd {
	return func() tea.Msg {
		store, err := loadLogs()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Debug: Failed to load logs in loadLogsCmd: %v\n", err)
			return LogLoadedMsg{Err: err}
		}
		filtered := []LogEntry{}
		for _, entry := range store.Entries {
			if categoryFilter == "all" || strings.HasPrefix(entry.Category, categoryFilter) {
				filtered = append(filtered, entry)
			}
		}
		fmt.Fprintf(os.Stderr, "Debug: Filtered %d logs for category '%s' out of %d total entries\n", len(filtered), categoryFilter, len(store.Entries))
		// Reverse to show newest first
		for i, j := 0, len(filtered)-1; i < j; i, j = i+1, j-1 {
			filtered[i], filtered[j] = filtered[j], filtered[i]
		}
		return LogLoadedMsg{Entries: filtered}
	}
}

// sortMenuItems sorts items by title length and moves "Back" and "Exit" items to the bottom
func sortMenuItems(items []list.Item) []list.Item {
	// Separate "Back" and "Exit" items from others
	var regularItems []list.Item
	var backExitItems []list.Item
	for _, item := range items {
		menuItem := item.(MenuItem)
		title := menuItem.Title()
		if strings.Contains(strings.ToLower(title), "back") || strings.Contains(strings.ToLower(title), "exit") {
			backExitItems = append(backExitItems, item)
		} else {
			regularItems = append(regularItems, item)
		}
	}
	// Sort regular items by title length (ascending)
	sort.Slice(regularItems, func(i, j int) bool {
		return len(regularItems[i].(MenuItem).Title()) < len(regularItems[j].(MenuItem).Title())
	})
	// Append "Back" and "Exit" items at the bottom
	return append(regularItems, backExitItems...)
}

// NewAppModel creates a new AppModel with enhanced help and sorted menu items
func NewAppModel() AppModel {
	// Define menu items for each section
	mainItems := []list.Item{
		MenuItem{title: "Logging", description: "View application logs"},
		MenuItem{title: "Service Management", description: "Control the SMTP service"},
		MenuItem{title: "Program Configs", description: "Configure application settings"},
		MenuItem{title: "Apply Config and Exit", description: "Apply changes, restart service, and exit"},
		MenuItem{title: "Exit without Starting", description: "Exit without starting the server"},
	}
	mainItems = sortMenuItems(mainItems)
	loggingItems := []list.Item{
		MenuItem{title: "SMTP Authentication", description: "View successful and failed SMTP authentication events"},
		MenuItem{title: "Gotify Logs", description: "View Gotify notification send events and errors"},
		MenuItem{title: "All Logs", description: "View all logged events"},
		MenuItem{title: "Back to Main Menu", description: "Return to main menu"},
	}
	loggingItems = sortMenuItems(loggingItems)
	programItems := []list.Item{
		MenuItem{title: "SMTP Configs", description: "Configure SMTP server settings"},
		MenuItem{title: "Gotify Configs", description: "Configure Gotify notification settings"},
		MenuItem{title: "Back to Main Menu", description: "Return to main menu"},
	}
	programItems = sortMenuItems(programItems)
	smtpItems := []list.Item{
		MenuItem{title: "SMTP Domain", description: "Set SMTP domain (e.g., localhost)"},
		MenuItem{title: "SMTP Port", description: "Set SMTP port (e.g., :2525)"},
		MenuItem{title: "SMTP Username", description: "Set SMTP username for client authentication"},
		MenuItem{title: "SMTP Password", description: "Set SMTP password for client authentication"},
		MenuItem{title: "Back to Program Configs", description: "Return to program configs"},
	}
	smtpItems = sortMenuItems(smtpItems)
	gotifyItems := []list.Item{
		MenuItem{title: "Gotify Host", description: "Set Gotify host (e.g., https://gotify.example.com)"},
		MenuItem{title: "Gotify Token", description: "Set Gotify API token"},
		MenuItem{title: "Back to Program Configs", description: "Return to program configs"},
	}
	gotifyItems = sortMenuItems(gotifyItems)
	serviceItems := []list.Item{
		MenuItem{title: "Stop Service", description: "Stop the SMTP-to-Gotify service"},
		MenuItem{title: "Start Service", description: "Start the SMTP-to-Gotify service"},
		MenuItem{title: "Apply Config and Restart Service", description: "Save config and restart service"},
		MenuItem{title: "Service Status", description: "View current service status"},
		MenuItem{title: "Back to Main Menu", description: "Return to main menu"},
	}
	serviceItems = sortMenuItems(serviceItems)
	defaultWidth, defaultHeight := 80, 24
		statusHeight := 4
		if statusHeight > defaultHeight-6 {
			statusHeight = defaultHeight - 6
		}
		return AppModel{
			CurrentScreen:  "MainMenu",
			Width:          defaultWidth,
			Height:         defaultHeight,
			MainMenu:       list.New(mainItems, list.NewDefaultDelegate(), defaultWidth-2, defaultHeight-10),
			LoggingMenu:    list.New(loggingItems, list.NewDefaultDelegate(), defaultWidth-2, defaultHeight-10),
			ProgramConfigs: list.New(programItems, list.NewDefaultDelegate(), defaultWidth-2, defaultHeight-10),
			SMTPConfigs:    list.New(smtpItems, list.NewDefaultDelegate(), defaultWidth-2, defaultHeight-10),
			GotifyConfigs:  list.New(gotifyItems, list.NewDefaultDelegate(), defaultWidth-2, defaultHeight-10),
			ServiceMenu:    list.New(serviceItems, list.NewDefaultDelegate(), defaultWidth-2, defaultHeight-10),
			LogViewer:      LogViewerModel{Viewport: viewport.New(defaultWidth-2, defaultHeight-10), PageSize: 20, Width: defaultWidth - 2, Height: defaultHeight - 10},
			StatusViewport: viewport.New(defaultWidth-2, statusHeight),
			StatusText:     "Status Panel: SMTP server events will appear here.",
			Help:           help.New(),
			Keys:           DefaultKeyMap,
			Banner:         newBannerModel(defaultWidth/2, defaultHeight/3),
		}
}

// interactiveConfig runs the BubbleTea UI
func interactiveConfig() error {
	model := NewAppModel()
	p := tea.NewProgram(model, tea.WithAltScreen())
	initStatusUpdater(p)
	finalModel, err := p.Run()
	if err != nil {
		return fmt.Errorf("failed to run bubbletea app: %v", err)
	}
	appModel := finalModel.(AppModel)
	if appModel.Quit && !appModel.StartServer {
		os.Exit(0)
	}
	return nil
}

// Recommendation 14: Modified startServer for graceful shutdown
func startServer(config AppConfig) error {
	listener, err := net.Listen("tcp", config.SMTP.Addr)
	if err != nil {
		logEvent("error", fmt.Sprintf("Failed to start TCP listener on %s: %v", config.SMTP.Addr, err), fmt.Sprintf("Unable to bind TCP listener to address %s for SMTP server startup: %v", config.SMTP.Addr, err))
		return fmt.Errorf("failed to start TCP listener on %s: %v", config.SMTP.Addr, err)
	}
	appendToStatus(fmt.Sprintf("SMTP server started on %s, forwarding to Gotify at %s", config.SMTP.Addr, config.Gotify.GotifyHost))
	logEvent("connection", fmt.Sprintf("SMTP server started on %s, forwarding to Gotify at %s", config.SMTP.Addr, config.Gotify.GotifyHost), fmt.Sprintf("SMTP server successfully started and listening on %s, configured to forward incoming emails as notifications to Gotify server at %s.", config.SMTP.Addr, config.Gotify.GotifyHost))
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigChan
		logEvent("connection", "Received shutdown signal, closing listener...", fmt.Sprintf("Received system signal to terminate (SIGTERM or SIGINT), initiating graceful shutdown of SMTP server by closing listener on %s.", config.SMTP.Addr))
		if err := listener.Close(); err != nil {
			logEvent("error", fmt.Sprintf("Error closing listener: %v", err), fmt.Sprintf("Failed to close TCP listener on %s during shutdown: %v", config.SMTP.Addr, err))
		}
		// Recommendation 14: Wait for active connections to complete with timeout
		shutdownTimeout := 30 * time.Second
		shutdownChan := make(chan struct{})
		go func() {
			activeConnections.Wait()
			close(shutdownChan)
		}()
		select {
			case <-shutdownChan:
				logEvent("connection", "All active connections closed, shutdown complete.", fmt.Sprintf("Graceful shutdown completed, all SMTP connections on %s have been closed.", config.SMTP.Addr))
			case <-time.After(shutdownTimeout):
				logEvent("warning", "Shutdown timeout reached, forcing exit with active connections.", fmt.Sprintf("Graceful shutdown timeout of %v reached, forcing exit while connections may still be active on %s.", shutdownTimeout, config.SMTP.Addr))
		}
		os.Exit(0)
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if opErr, ok := err.(*net.OpError); ok && opErr.Op == "accept" {
				break
			}
			logEvent("error", fmt.Sprintf("Error accepting connection: %v", err), fmt.Sprintf("Failed to accept incoming TCP connection on %s: %v", config.SMTP.Addr, err))
			continue
		}
		go handleConnection(conn, config)
	}
	return nil
}

func main() {
	var rootCmd = &cobra.Command{
		Use:   "smtp-to-gotify",
		Short: "A local SMTP server that forwards emails to Gotify",
	}
	if err := initLogger(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize logger: %v\n", err)
		os.Exit(1)
	}
	defer zapLogger.Sync()
	var startCmd = &cobra.Command{
		Use:   "start",
		Short: "Start the SMTP server directly",
		Run: func(cmd *cobra.Command, args []string) {
			config, err := loadConfig()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Failed to load config: %v\n", err)
				logEvent("error", fmt.Sprintf("Failed to load config: %v", err), fmt.Sprintf("Failed to load application configuration from file or environment variables: %v", err))
				os.Exit(1)
			}
			if err := startServer(config); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to start SMTP server: %v\n", err)
				logEvent("error", fmt.Sprintf("Failed to start SMTP server: %v", err), fmt.Sprintf("SMTP server failed to start due to configuration or network issues: %v", err))
				os.Exit(1)
			}
		},
	}
	var configCmd = &cobra.Command{
		Use:   "config",
		Short: "Run interactive configuration UI",
		Run: func(cmd *cobra.Command, args []string) {
			config, err := loadConfig()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Failed to load config: %v\n", err)
				logEvent("error", fmt.Sprintf("Failed to load config: %v", err), fmt.Sprintf("Failed to load application configuration for interactive UI: %v", err))
				os.Exit(1)
			}
			if err := interactiveConfig(); err != nil {
				fmt.Fprintf(os.Stderr, "Interactive config failed: %v\n", err)
				logEvent("error", fmt.Sprintf("Interactive config failed: %v", err), fmt.Sprintf("Interactive configuration UI encountered an error and could not proceed: %v", err))
				os.Exit(1)
			}
			config, err = loadConfig()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Failed to reload config: %v\n", err)
				logEvent("error", fmt.Sprintf("Failed to reload config: %v", err), fmt.Sprintf("Failed to reload application configuration after interactive UI changes: %v", err))
				os.Exit(1)
			}
			if err := startServer(config); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to start SMTP server: %v\n", err)
				logEvent("error", fmt.Sprintf("Failed to start SMTP server: %v", err), fmt.Sprintf("SMTP server failed to start after interactive configuration: %v", err))
				os.Exit(1)
			}
		},
	}
	rootCmd.PersistentFlags().StringVar(&configDirPath, "config-dir", configDirPath, "Directory for configuration files")
	viper.BindPFlag("config_dir", rootCmd.PersistentFlags().Lookup("config-dir"))
	rootCmd.AddCommand(startCmd, configCmd)
	rootCmd.Run = func(cmd *cobra.Command, args []string) {
		config, err := loadConfig()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to load config: %v\n", err)
			logEvent("error", fmt.Sprintf("Failed to load config: %v", err), fmt.Sprintf("Failed to load application configuration on default run: %v", err))
			os.Exit(1)
		}
		if os.Getenv("RUN_AS_SERVICE") == "true" {
			if err := startServer(config); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to start SMTP server: %v\n", err)
				logEvent("error", fmt.Sprintf("Failed to start SMTP server: %v", err), fmt.Sprintf("SMTP server failed to start when running as a service: %v", err))
				os.Exit(1)
			}
			return
		}
		if err := interactiveConfig(); err != nil {
			fmt.Fprintf(os.Stderr, "Interactive config failed: %v\n", err)
			logEvent("error", fmt.Sprintf("Interactive config failed: %v", err), fmt.Sprintf("Interactive configuration UI failed on default run: %v", err))
			os.Exit(1)
		}
		config, err = loadConfig()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to reload config: %v\n", err)
			logEvent("error", fmt.Sprintf("Failed to reload config: %v", err), fmt.Sprintf("Failed to reload application configuration after interactive UI on default run: %v", err))
			os.Exit(1)
		}
		if err := startServer(config); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to start SMTP server: %v\n", err)
			logEvent("error", fmt.Sprintf("Failed to start SMTP server: %v", err), fmt.Sprintf("SMTP server failed to start after interactive configuration on default run: %v", err))
			os.Exit(1)
		}
	}
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Command execution failed: %v\n", err)
		logEvent("error", fmt.Sprintf("Command execution failed: %v", err), fmt.Sprintf("Execution of CLI command failed due to error: %v", err))
		os.Exit(1)
	}
}
