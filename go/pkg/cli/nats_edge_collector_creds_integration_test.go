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
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

// Edge collector credentials are minted as collector-type users through the
// same GenerateUserCredentials call datasvc serves. The shape core requests
// (data subject plus read-only stream info) must pass the validator, publish
// into the owner's stream, and be unable to rewrite or delete it.
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
	trapd := mint("edge-trapd", accounts.CredentialTypeCollector, accounts.UserPermissions{
		PublishAllow:   []string{"logs.snmp", "$JS.API.STREAM.INFO.events"},
		PublishDeny:    []string{"$SYS.>"},
		SubscribeAllow: []string{"_INBOX.>"},
	})

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
	if _, err := ownerJS.AddStream(&nats.StreamConfig{Name: "events", Subjects: []string{"logs.>"}, MaxBytes: 1 << 20}); err != nil {
		t.Fatalf("owner create events: %v", err)
	}

	js := connect(trapd)
	info, err := js.StreamInfo("events")
	if err != nil {
		t.Fatalf("trapd stream info: %v", err)
	}
	if _, err := js.Publish("logs.snmp", []byte(`{}`), nats.AckWait(2*time.Second)); err != nil {
		t.Errorf("trapd publish logs.snmp: %v", err)
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
