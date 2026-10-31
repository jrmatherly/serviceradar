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
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

// corePermissions reads what core requests from the fixture its Elixir test pins.
func corePermissions(t *testing.T, name string) accounts.UserPermissions {
	t.Helper()

	contents, err := os.ReadFile(filepath.Join("testdata", "nats-permissions.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]accounts.UserPermissions
	if err := json.Unmarshal(contents, &fixture); err != nil {
		t.Fatal(err)
	}
	permissions, ok := fixture[name]
	if !ok {
		t.Fatalf("no %s in nats-permissions.json", name)
	}

	return permissions
}

// Edge collector credentials are minted as collector-type users through the
// same GenerateUserCredentials call datasvc serves. The shape core requests must
// publish into the owner's stream and hold no stream API: not even a read.
func TestEdgeCollectorTypeCredsPublishWithoutStreamAdmin(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	operator, boot, err := accounts.BootstrapOperator("edge-test", "", true)
	if err != nil {
		t.Fatalf("BootstrapOperator: %v", err)
	}
	account, err := accounts.NewAccountSigner(operator).CreateAccount("platform", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}

	mint := func(user string, credType accounts.UserCredentialType, perms accounts.UserPermissions) string {
		creds, err := accounts.GenerateUserCredentials("platform", account.AccountSeed, user, credType, &perms, 0)
		if err != nil {
			t.Fatalf("mint %s: %v", user, err)
		}
		path := filepath.Join(t.TempDir(), user+".creds")
		if err := os.WriteFile(path, []byte(creds.CredsFileContent), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	owner := mint("owner", accounts.CredentialTypeService, accounts.UserPermissions{
		PublishAllow:   []string{"$JS.API.>", "_INBOX.>"},
		SubscribeAllow: []string{"_INBOX.>"},
	})
	trapd := mint("edge-trapd", accounts.CredentialTypeCollector, corePermissions(t, "trapd"))

	operatorClaims, err := jwt.DecodeOperatorClaims(boot.OperatorJWT)
	if err != nil {
		t.Fatal(err)
	}
	resolver := &server.MemAccResolver{}
	if err := resolver.Store(boot.SystemAccountPublicKey, boot.SystemAccountJWT); err != nil {
		t.Fatal(err)
	}
	if err := resolver.Store(account.AccountPublicKey, account.AccountJWT); err != nil {
		t.Fatal(err)
	}
	srv := runACLServer(t, &server.Options{
		Host:             "127.0.0.1",
		Port:             -1,
		JetStream:        true,
		StoreDir:         t.TempDir(),
		TrustedOperators: []*jwt.OperatorClaims{operatorClaims},
		AccountResolver:  resolver,
		SystemAccount:    boot.SystemAccountPublicKey,
	})
	t.Cleanup(srv.Shutdown)

	connect := func(creds string) nats.JetStreamContext {
		nc, err := nats.Connect(srv.ClientURL(), nats.UserCredentials(creds))
		if err != nil {
			t.Fatalf("connect %s: %v", filepath.Base(creds), err)
		}
		t.Cleanup(nc.Close)
		js, err := nc.JetStream()
		if err != nil {
			t.Fatal(err)
		}
		return js
	}

	ownerJS := connect(owner)
	info, err := ownerJS.AddStream(&nats.StreamConfig{Name: "events", Subjects: []string{"logs.>"}, MaxBytes: 1 << 20})
	if err != nil {
		t.Fatalf("owner create events: %v", err)
	}

	js := connect(trapd)
	ack, err := js.Publish("logs.snmp", []byte(`{}`), nats.AckWait(2*time.Second))
	if err != nil {
		t.Fatalf("trapd publish logs.snmp: %v", err)
	}
	if ack.Stream != "events" {
		t.Errorf("ack stream = %q, want events", ack.Stream)
	}
	if _, err := js.StreamInfo("events", shortJSContext(t)); !deniedJS(err) {
		t.Errorf("trapd stream info: got %v, want a denied (timed out) request", err)
	}
	shrunk := info.Config
	shrunk.MaxBytes = 1024
	if _, err := js.UpdateStream(&shrunk, shortJSContext(t)); !deniedJS(err) {
		t.Errorf("trapd update events: got %v, want a denied (timed out) request", err)
	}
	if err := js.DeleteStream("events", shortJSContext(t)); !deniedJS(err) {
		t.Errorf("trapd delete events: got %v, want a denied (timed out) request", err)
	}
}

// A leaf server answers $JS.API locally (its own JetStream, domain edge), so a
// local client's stream lookup says not-found while its publish still lands on
// the hub's stream. That is why the leaf credential needs no $JS.API.> and why
// collectors behind a leaf cannot gate on a stream lookup.
func TestLeafCredsReachHubStreamWithoutJetStreamAPI(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	operator, boot, err := accounts.BootstrapOperator("leaf-test", "", true)
	if err != nil {
		t.Fatalf("BootstrapOperator: %v", err)
	}
	account, err := accounts.NewAccountSigner(operator).CreateAccount("platform", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	mint := func(user string, perms accounts.UserPermissions) string {
		creds, err := accounts.GenerateUserCredentials("platform", account.AccountSeed, user, accounts.CredentialTypeService, &perms, 0)
		if err != nil {
			t.Fatalf("mint %s: %v", user, err)
		}
		path := filepath.Join(t.TempDir(), user+".creds")
		if err := os.WriteFile(path, []byte(creds.CredsFileContent), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}

	operatorClaims, err := jwt.DecodeOperatorClaims(boot.OperatorJWT)
	if err != nil {
		t.Fatal(err)
	}
	resolver := &server.MemAccResolver{}
	if err := resolver.Store(boot.SystemAccountPublicKey, boot.SystemAccountJWT); err != nil {
		t.Fatal(err)
	}
	if err := resolver.Store(account.AccountPublicKey, account.AccountJWT); err != nil {
		t.Fatal(err)
	}
	listener, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	leafPort := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	hub := runACLServer(t, &server.Options{
		Host:             "127.0.0.1",
		Port:             -1,
		ServerName:       "hub",
		JetStream:        true,
		StoreDir:         t.TempDir(),
		TrustedOperators: []*jwt.OperatorClaims{operatorClaims},
		AccountResolver:  resolver,
		SystemAccount:    boot.SystemAccountPublicKey,
		LeafNode:         server.LeafNodeOpts{Host: "127.0.0.1", Port: leafPort},
	})
	t.Cleanup(hub.Shutdown)

	owner, err := nats.Connect(hub.ClientURL(), nats.UserCredentials(mint("owner", accounts.UserPermissions{
		PublishAllow:   []string{"$JS.API.>", "_INBOX.>"},
		SubscribeAllow: []string{"_INBOX.>"},
	})))
	if err != nil {
		t.Fatalf("connect owner: %v", err)
	}
	t.Cleanup(owner.Close)
	ownerJS, err := owner.JetStream()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ownerJS.AddStream(&nats.StreamConfig{Name: "events", Subjects: []string{"logs.>"}, MaxBytes: 1 << 20}); err != nil {
		t.Fatalf("owner create events: %v", err)
	}

	leafCreds := mint("leaf", corePermissions(t, "leaf"))
	hubLeafURL, err := url.Parse(fmt.Sprintf("nats-leaf://127.0.0.1:%d", leafPort))
	if err != nil {
		t.Fatal(err)
	}
	leaf := runACLServer(t, &server.Options{
		Host:            "127.0.0.1",
		Port:            -1,
		ServerName:      "edge-leaf",
		JetStream:       true,
		JetStreamDomain: "edge",
		StoreDir:        t.TempDir(),
		LeafNode: server.LeafNodeOpts{Remotes: []*server.RemoteLeafOpts{
			{URLs: []*url.URL{hubLeafURL}, Credentials: leafCreds},
		}},
	})
	t.Cleanup(leaf.Shutdown)
	for deadline := time.Now().Add(10 * time.Second); leaf.NumLeafNodes() == 0; {
		if time.Now().After(deadline) {
			t.Fatal("leaf never connected to the hub")
		}
		time.Sleep(50 * time.Millisecond)
	}

	client, err := nats.Connect(leaf.ClientURL())
	if err != nil {
		t.Fatalf("connect to leaf: %v", err)
	}
	t.Cleanup(client.Close)
	js, err := client.JetStream(nats.Domain("edge"))
	if err != nil {
		t.Fatal(err)
	}

	if _, err := js.StreamInfo("events", nats.MaxWait(2*time.Second)); !errors.Is(err, nats.ErrStreamNotFound) {
		t.Errorf("stream lookup behind the leaf: got %v, want stream not found", err)
	}

	// Interest in the hub stream's subject crosses the leaf asynchronously.
	var ack *nats.PubAck
	for deadline := time.Now().Add(10 * time.Second); ack == nil; {
		ack, err = js.Publish("logs.snmp", []byte(`{}`), nats.AckWait(time.Second))
		if err != nil {
			if time.Now().After(deadline) {
				t.Fatalf("publish behind the leaf: %v", err)
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	if ack.Stream != "events" {
		t.Errorf("ack stream = %q, want events", ack.Stream)
	}
	info, err := ownerJS.StreamInfo("events")
	if err != nil {
		t.Fatalf("hub stream info: %v", err)
	}
	if info.State.Msgs == 0 {
		t.Error("the hub stream stored nothing")
	}
}
