package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

type helloResponse struct {
	Message string `json:"message"`
	Time    string `json:"time"`
}

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/hello", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")

		response := helloResponse{
			Message: "Привет! Бэкенд работает",
			Time:    time.Now().Format(time.RFC3339),
		}

		if err := json.NewEncoder(w).Encode(response); err != nil {
			http.Error(w, "failed to encode response", http.StatusInternalServerError)
			return
		}
	})

	// Serve static files from the project root.
	mux.Handle("/", http.FileServer(http.Dir(".")))

	server := &http.Server{
		Addr:    ":8080",
		Handler: mux,
	}

	log.Println("Server started on http://localhost:8080")
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
