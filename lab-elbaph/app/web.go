package main

import (
	"bytes"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

type appConfig struct {
	AppMode    string
	ListenAddr string
	OpsLinkURL string
}

type serviceStatus struct {
	Name    string
	Status  string
	Details string
}

type pageData struct {
	Title       string
	OpsLinkURL  string
	Result      string
	Command     string
	Target      string
	Services    []serviceStatus
	GeneratedAt string
}

func main() {
	cfg := appConfig{
		AppMode:    envOrDefault("APP_MODE", "web"),
		ListenAddr: ":" + envOrDefault("PORT", "8080"),
		OpsLinkURL: envOrDefault("OPS_LINK_URL", "http://127.0.0.1:8080"),
	}

	mux := http.NewServeMux()
	mux.Handle("/assets/", http.StripPrefix("/assets/", http.FileServer(http.Dir("./frontend/assets"))))
	// Geo-block HTML is plain static on disk; deploy bakes ALB DNS via Terraform (see terraform/templates/geo-blocked.html.tftpl).
	mux.Handle("/errors/", http.StripPrefix("/errors/", http.FileServer(http.Dir("./frontend/errors"))))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		if cfg.AppMode == "ops" {
			renderTemplate(w, "frontend/ops.html", pageData{
				Title:       "Operations console",
				OpsLinkURL:  cfg.OpsLinkURL,
				GeneratedAt: time.Now().Format(time.RFC3339),
				Services:    opsStatuses(),
			})
			return
		}

		switch r.Method {
		case http.MethodGet:
			renderTemplate(w, "frontend/index.html", pageData{
				Title:       "ELBaph lab",
				OpsLinkURL:  cfg.OpsLinkURL,
				GeneratedAt: time.Now().Format(time.RFC3339),
			})
		case http.MethodPost:
			target := strings.TrimSpace(r.FormValue("target"))
			command := "dig +short " + target
			output := executeShell(command)
			renderTemplate(w, "frontend/index.html", pageData{
				Title:       "ELBaph lab",
				OpsLinkURL:  cfg.OpsLinkURL,
				Target:      target,
				Command:     command,
				Result:      output,
				GeneratedAt: time.Now().Format(time.RFC3339),
			})
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	mux.HandleFunc("/diagnostics", func(w http.ResponseWriter, r *http.Request) {
		renderTemplate(w, "frontend/diagnostics.html", pageData{
			Title:       "Diagnostics",
			OpsLinkURL:  cfg.OpsLinkURL,
			GeneratedAt: time.Now().Format(time.RFC3339),
			Services:    edgeServiceStatuses(),
		})
	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("ok"))
	})

	log.Printf("starting elbaph web app mode=%s on %s", cfg.AppMode, cfg.ListenAddr)
	log.Fatal(http.ListenAndServe(cfg.ListenAddr, requestLogger(mux)))
}

func executeShell(command string) string {
	cmd := exec.Command("/bin/sh", "-c", command)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stdout
	if err := cmd.Run(); err != nil {
		if stdout.Len() == 0 {
			return err.Error()
		}
	}
	return stdout.String()
}

func renderTemplate(w http.ResponseWriter, path string, data pageData) {
	tmpl, err := template.ParseFiles(path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.Execute(w, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}

func edgeServiceStatuses() []serviceStatus {
	return []serviceStatus{
		{Name: "web", Status: "healthy", Details: "Public portal web tier is serving requests on :443"},
		{Name: "ops", Status: "restricted", Details: "Support dashboard is intended for VPN users only"},
		{Name: "dig-worker", Status: "degraded", Details: "Resolver checks are slow under heavy uploads"},
	}
}

func opsStatuses() []serviceStatus {
	return []serviceStatus{
		{Name: "ops-dashboard", Status: "healthy", Details: "Internal support dashboard is available"},
		{Name: "queue-bridge", Status: "healthy", Details: "Manifest queue is draining normally"},
		{Name: "ingest-adapter", Status: "warning", Details: "One upstream callback is retrying"},
	}
}

func envOrDefault(name, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}
