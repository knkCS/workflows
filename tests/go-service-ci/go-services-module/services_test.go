// Package goservicesmodule is a self-test fixture for go-service-ci's
// `services` test mode: its one test fails unless the Postgres and Redis
// service containers that mode promises are listening, so a green run proves
// the `go` job started them. It needs them locally too — it is not meant to
// pass on a laptop without them.
package goservicesmodule

import (
	"net"
	"testing"
	"time"
)

func TestServiceContainersListen(t *testing.T) {
	for _, addr := range []string{"localhost:5432", "localhost:6379"} {
		conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
		if err != nil {
			t.Errorf("no service container on %s: %v", addr, err)
			continue
		}
		conn.Close()
	}
}
