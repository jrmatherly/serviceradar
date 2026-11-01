/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package cli

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

const revokedCollectorCN = "flowgger-11111111222243338444555555550001.default.serviceradar"

// The credential is revoked for real on an operator-mode hub, and the hub's refusal
// is the control: a leaf that keeps serving the package is then the gap, not a test
// that never revoked anything.
func TestLeafRefusesCollectorRevokedAtHub(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	pki := newLeafTestPKI(t)
	operator, boot, err := accounts.BootstrapOperator("leaf-revoke-test", "", true)
	if err != nil {
		t.Fatal(err)
	}
	signer := accounts.NewAccountSigner(operator).WithJetStreamSizing(&accounts.JetStreamSizing{DiskStorage: 1 << 30})
	account, err := signer.CreateAccount("platform", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	hub, leafPort := runOperatorLeafHub(t, pki, boot, account)
	mintCreds := func(name string, kind accounts.UserCredentialType, perms *accounts.UserPermissions) (string, string) {
		creds, err := accounts.GenerateUserCredentials("platform", account.AccountSeed, name, kind, perms, 0)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(t.TempDir(), name+".creds")
		if err := os.WriteFile(path, []byte(creds.CredsFileContent), 0o600); err != nil {
			t.Fatal(err)
		}
		return creds.UserPublicKey, path
	}

	_, leafCreds := mintCreds("leaf-site01", accounts.CredentialTypeService, &accounts.UserPermissions{
		PublishAllow: []string{"logs.>", "$JS.ACK.>", "_INBOX.>"}, SubscribeAllow: []string{"$JS.ACK.>", "_INBOX.>"},
	})
	collectorKey, collectorCreds := mintCreds("edge-flowgger", accounts.CredentialTypeCollector, &accounts.UserPermissions{
		PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{"_INBOX.>"},
	})
	_, adminCreds := mintCreds("hub-admin", accounts.CredentialTypeService, &accounts.UserPermissions{
		PublishAllow: []string{"$JS.API.>"}, SubscribeAllow: []string{"_INBOX.>"},
	})

	conf := strings.Replace(renderLeafConf(t, pki, leafPort, "leaf-collectors.conf"),
		fmt.Sprintf(`url: "tls://localhost:%d"`, leafPort),
		fmt.Sprintf(`url: "tls://localhost:%d"`+"\n            credentials: %q", leafPort, leafCreds), 1)
	leaf := runLeafTestServer(t, conf)
	waitForLeafLink(t, hub)

	admin, err := nats.Connect(hub.ClientURL(), nats.UserCredentials(adminCreds))
	if err != nil {
		t.Fatalf("connect hub admin: %v", err)
	}
	t.Cleanup(admin.Close)
	adminJS, err := admin.JetStream()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := adminJS.AddStream(&nats.StreamConfig{Name: "events", Subjects: []string{"logs.>"}, MaxBytes: 1 << 20}); err != nil {
		t.Fatalf("add stream: %v", err)
	}

	// Before revoking, the same package works by both routes.
	direct, err := nats.Connect(hub.ClientURL(), nats.UserCredentials(collectorCreds), nats.NoReconnect())
	if err != nil {
		t.Fatalf("credential refused by the hub before revocation: %v", err)
	}
	direct.Close()

	open := connectToLeaf(t, pki, leaf, revokedCollectorCN, nats.UserCredentials(collectorCreds))
	openJS, err := open.JetStream()
	if err != nil {
		t.Fatal(err)
	}
	publishUntilAcked(t, openJS, "logs.syslog")

	revokeAtHub(t, signer, boot, account, collectorKey, hub)

	if _, err := nats.Connect(hub.ClientURL(), nats.UserCredentials(collectorCreds), nats.NoReconnect()); err == nil {
		t.Fatal("control failed: the hub still accepts the revoked credential")
	}

	before := streamMessages(t, adminJS, "events")
	if _, err := openJS.Publish("logs.syslog", []byte(`{}`), nats.AckWait(2*time.Second)); err == nil {
		t.Errorf("open connection through the leaf: publish acked after revocation, stream %d -> %d",
			before, streamMessages(t, adminJS, "events"))
	}

	again, err := nats.Connect(leaf.ClientURL(), nats.RootCAs(pki.caFile), nats.UserCredentials(collectorCreds),
		nats.ClientCert(pki.issue(t, revokedCollectorCN, nil, nil)), nats.NoReconnect())
	if err == nil {
		again.Close()
		t.Errorf("new connection through the leaf: accepted after revocation")
	} else if !errors.Is(err, nats.ErrAuthorization) {
		t.Errorf("new connection through the leaf: got %v, want an authorization violation", err)
	}
}

func revokeAtHub(
	t *testing.T, signer *accounts.AccountSigner, boot *accounts.BootstrapResult,
	account *accounts.AccountResult, userKey string, hub *server.Server,
) {
	t.Helper()

	updated, err := signer.RevokeUsers(account.AccountJWT, []string{userKey})
	if err != nil {
		t.Fatal(err)
	}
	system, err := accounts.GenerateUserCredentials("SYS", boot.SystemAccountSeed, "system-resolver", accounts.CredentialTypeService,
		&accounts.UserPermissions{
			PublishAllow: []string{"$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE"}, SubscribeAllow: []string{"_INBOX.>"},
			AllowResponses: true, MaxResponses: 10,
		}, 0)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "system.creds")
	if err := os.WriteFile(path, []byte(system.CredsFileContent), 0o600); err != nil {
		t.Fatal(err)
	}
	conn, err := nats.Connect(hub.ClientURL(), nats.UserCredentials(path))
	if err != nil {
		t.Fatalf("connect system user: %v", err)
	}
	defer conn.Close()
	subject := fmt.Sprintf("$SYS.REQ.ACCOUNT.%s.CLAIMS.UPDATE", account.AccountPublicKey)
	if _, err := conn.Request(subject, []byte(updated), 5*time.Second); err != nil {
		t.Fatalf("push revocation: %v", err)
	}
}

// Mirrors docker/compose/nats.docker.conf (operator and full resolver) plus a leaf
// listener, which that file does not have.
func runOperatorLeafHub(t *testing.T, pki *leafTestPKI, boot *accounts.BootstrapResult, account *accounts.AccountResult) (*server.Server, int) {
	t.Helper()

	free, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	leafPort := free.Addr().(*net.TCPAddr).Port
	_ = free.Close()

	dir := t.TempDir()
	jwtDir := filepath.Join(dir, "jwt")
	if err := os.MkdirAll(jwtDir, 0o700); err != nil {
		t.Fatal(err)
	}
	for key, token := range map[string]string{
		boot.SystemAccountPublicKey: boot.SystemAccountJWT,
		account.AccountPublicKey:    account.AccountJWT,
	} {
		if err := os.WriteFile(filepath.Join(jwtDir, key+".jwt"), []byte(token), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	operatorFile := filepath.Join(dir, "operator.jwt")
	if err := os.WriteFile(operatorFile, []byte(boot.OperatorJWT), 0o600); err != nil {
		t.Fatal(err)
	}

	serverCert, serverKey := pki.issue(t, "hub.example.com", []string{"localhost"}, nil)
	conf := fmt.Sprintf(`server_name: hub
listen: 127.0.0.1:-1
operator: %q
resolver: { type: full, dir: %q, allow_delete: false, interval: "2m" }
system_account: %s
jetstream { store_dir: %q, max_memory_store: 4G, max_file_store: 4G }
leafnodes {
  listen: 127.0.0.1:%d
  tls { cert_file: %q, key_file: %q, ca_file: %q, verify: true, timeout: 5 }
}
`, operatorFile, jwtDir, boot.SystemAccountPublicKey, t.TempDir(), leafPort, serverCert, serverKey, pki.caFile)

	return runLeafTestServer(t, conf), leafPort
}
