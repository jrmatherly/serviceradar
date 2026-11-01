package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// CI cannot run the Compose stack, and a service with no credential only logs
// reconnects while its container stays healthy, so the wiring is pinned here.
func TestComposeWiresEveryIdentity(t *testing.T) {
	root := filepath.Join("..", "..", "..")

	read := func(path string) string {
		t.Helper()

		contents, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}

		return string(contents)
	}

	compose := read("docker-compose.yml")
	initScript := read(filepath.Join("docker", "compose", "init-nats-creds.sh"))

	for _, identity := range serviceIdentities() {
		creds := identity.user + ".creds"

		if !strings.Contains(initScript, " "+creds) {
			t.Errorf("init-nats-creds.sh does not require %s, so a volume without it counts as complete", creds)
		}

		if !strings.Contains(compose, "subpath: "+creds) {
			t.Errorf("docker-compose.yml mounts %s nowhere, so %s cannot authenticate", creds, identity.user)
		}
	}
}

// EventWriter stays off without a credential, and web-ng without NATS_ENABLED, and
// neither says so: streams fill while nothing reaches CNPG.
func TestComposeEnablesEveryNatsClient(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "..", "..", "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}

	compose := string(contents)

	for _, setting := range []string{
		"EVENT_WRITER_ENABLED=true",
		"EVENT_WRITER_NATS_CREDS_FILE=/etc/serviceradar/creds/core.creds",
		"AGENT_GATEWAY_NATS_URL=nats://nats:4222",
		"AGENT_GATEWAY_NATS_CREDS_FILE=/etc/serviceradar/creds/agent-gateway.creds",
		"NATS_CREDS_FILE=/etc/serviceradar/creds/web-ng.creds",
	} {
		if !strings.Contains(compose, setting) {
			t.Errorf("docker-compose.yml is missing %s", setting)
		}
	}
}

// The CNPG image ships no docker-entrypoint, so this script is what runs initdb, and
// left alone initdb picks SQL_ASCII, which AGE and the migrations reject.
func TestComposeDatabaseIsUTF8(t *testing.T) {
	script, err := os.ReadFile(filepath.Join("..", "..", "..", "docker", "compose", "check-cnpg-major-version.sh"))
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(string(script), "--encoding=UTF8") {
		t.Error("check-cnpg-major-version.sh runs initdb without --encoding=UTF8")
	}
}
