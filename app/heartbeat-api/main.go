// heartbeat-api: minimal HTTP service for CloudOps portfolio platform.
//
// Endpoints:
//   GET /health       — liveness check; returns 200 {"status":"ok"}
//   GET /metrics      — Prometheus-style plaintext counters
//   GET /work?ms=N    — simulate CPU work for N milliseconds (default 100)
//
// Build:
//   GOARCH=arm64 GOOS=linux go build -o heartbeat-api .
//
// The binary is embedded into the Golden AMI via EC2 Image Builder.
// See terraform/modules/image-builder/main.tf (heartbeat_api_install component).

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

var (
	healthRequests  atomic.Int64
	metricsRequests atomic.Int64
	workRequests    atomic.Int64
	startTime       = time.Now()
)

func healthHandler(w http.ResponseWriter, r *http.Request) {
	healthRequests.Add(1)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"uptime":  time.Since(startTime).Round(time.Second).String(),
		"version": "1.0.0",
	})
}

func metricsHandler(w http.ResponseWriter, _ *http.Request) {
	metricsRequests.Add(1)
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w,
		"# HELP heartbeat_requests_total Total requests per endpoint\n"+
			"# TYPE heartbeat_requests_total counter\n"+
			"heartbeat_requests_total{endpoint=\"health\"} %d\n"+
			"heartbeat_requests_total{endpoint=\"metrics\"} %d\n"+
			"heartbeat_requests_total{endpoint=\"work\"} %d\n"+
			"# HELP heartbeat_uptime_seconds Seconds since process start\n"+
			"# TYPE heartbeat_uptime_seconds gauge\n"+
			"heartbeat_uptime_seconds %.0f\n",
		healthRequests.Load(),
		metricsRequests.Load(),
		workRequests.Load(),
		time.Since(startTime).Seconds(),
	)
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	workRequests.Add(1)
	msStr := r.URL.Query().Get("ms")
	if msStr == "" {
		msStr = "100"
	}
	ms, err := strconv.Atoi(msStr)
	if err != nil || ms < 0 || ms > 30000 {
		http.Error(w, "ms must be 0–30000", http.StatusBadRequest)
		return
	}

	start := time.Now()
	// Busy-wait to produce measurable CPU load visible in CloudWatch metrics
	deadline := start.Add(time.Duration(ms) * time.Millisecond)
	for time.Now().Before(deadline) {
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":    "ok",
		"requested_ms": ms,
		"elapsed_ms": time.Since(start).Milliseconds(),
	})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/metrics", metricsHandler)
	mux.HandleFunc("/work", workHandler)

	addr := ":" + port
	log.Printf("heartbeat-api listening on %s", addr)

	server := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 35 * time.Second, // > max work ms (30s)
		IdleTimeout:  60 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}
