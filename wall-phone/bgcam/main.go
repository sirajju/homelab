package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

var (
	listenAddr = flag.String("listen", "0.0.0.0:8088", "HTTP listen address")
	camID      = flag.String("cam", "1", "Camera ID (1=front, 0=back)")
	snapFile   = flag.String("out", "/data/data/com.termux/files/home/shot.jpg", "Snapshot output path")
	authUser   = flag.String("user", "sirajju", "Basic auth user")
	authPass   = flag.String("pass", "siraju24@", "Basic auth password")

	mu       sync.Mutex
	lastSnap []byte
	lastTime time.Time
)

const termuxCameraBin = "/data/data/com.termux/files/usr/bin/termux-camera-photo"

func init() {
	_ = os.Setenv("PATH", "/data/data/com.termux/files/usr/bin:/system/bin:"+os.Getenv("PATH"))
}

func handleShot(w http.ResponseWriter, r *http.Request) {
	// Check basic auth if user & pass provided
	if *authUser != "" && *authPass != "" {
		u, p, ok := r.BasicAuth()
		if !ok || u != *authUser || p != *authPass {
			if r.URL.Query().Get("user") != *authUser || r.URL.Query().Get("pass") != *authPass {
				w.Header().Set("WWW-Authenticate", `Basic realm="bgcam"`)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
		}
	}

	mu.Lock()
	defer mu.Unlock()

	// Cache within 2 seconds so rapid calls don't hammer the camera sensor
	if len(lastSnap) > 0 && time.Since(lastTime) < 2*time.Second {
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(lastSnap)))
		w.Write(lastSnap)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, termuxCameraBin, "-c", *camID, *snapFile)
	cmd.Env = append(os.Environ(), "PATH=/data/data/com.termux/files/usr/bin:/system/bin")
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Printf("camera snap error: %v (%s), fallback cam 0", err, string(out))
		cmd0 := exec.CommandContext(ctx, termuxCameraBin, "-c", "0", *snapFile)
		cmd0.Env = cmd.Env
		_ = cmd0.Run()
	}

	data, err := os.ReadFile(*snapFile)
	if err != nil || len(data) == 0 {
		http.Error(w, "snap capture failed", http.StatusInternalServerError)
		return
	}

	lastSnap = data
	lastTime = time.Now()

	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(data)))
	w.Write(data)
}

func main() {
	flag.Parse()
	http.HandleFunc("/shot.jpg", handleShot)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok\n"))
	})
	log.Printf("bgcam listening on %s (camera %s)", *listenAddr, *camID)
	if err := http.ListenAndServe(*listenAddr, nil); err != nil {
		log.Fatalf("listen failed: %v", err)
	}
}
