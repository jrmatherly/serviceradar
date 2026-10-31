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
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

const leafRoleURI = "spiffe://serviceradar.local/nats-leaf/default"

// The fixtures are NatsLeafConfigGenerator output; its test pins them.
func TestLeafEnforcesCollectorAuthorization(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	pki := newLeafTestPKI(t)
	hub, leafPort := runLeafTestHub(t, pki)
	leaf := runRenderedLeaf(t, pki, hub, leafPort, "leaf-collectors.conf")
	creds := leafTestCreds(t)
	admin := connectHubAdmin(t, pki, hub)

	js, err := admin.JetStream()
	if err != nil {
		t.Fatal(err)
	}
	for name, subjects := range map[string][]string{
		"events": {"logs.>", "otel.>"},
		"flows":  {"flows.raw.>"},
	} {
		if _, err := js.AddStream(&nats.StreamConfig{Name: name, Subjects: subjects, MaxBytes: 1 << 20}); err != nil {
			t.Fatalf("add stream %s: %v", name, err)
		}
	}

	collectors := []struct {
		cn      string
		stream  string
		allowed []string
		denied  []string
	}{
		{
			cn:      "flowgger-11111111222243338444555555550001.default.serviceradar",
			stream:  "events",
			allowed: []string{"logs.syslog"},
			denied:  []string{"logs.snmp", "otel.traces.x", "flows.raw.netflow"},
		},
		{
			cn:      "trapd-11111111222243338444555555550002.default.serviceradar",
			stream:  "events",
			allowed: []string{"logs.snmp"},
			denied:  []string{"logs.syslog", "logs.otel"},
		},
		{
			cn:      "otel-11111111222243338444555555550003.default.serviceradar",
			stream:  "events",
			allowed: []string{"otel.traces.x", "otel.metrics.x", "logs.otel"},
			denied:  []string{"logs.syslog", "otel.other"},
		},
		{
			cn:      "netflow-11111111222243338444555555550004.default.serviceradar",
			stream:  "flows",
			allowed: []string{"flows.raw.netflow"},
			denied:  []string{"flows.raw.sflow", "logs.syslog"},
		},
		{
			cn:      "sflow-11111111222243338444555555550005.default.serviceradar",
			stream:  "flows",
			allowed: []string{"flows.raw.sflow"},
			denied:  []string{"flows.raw.netflow", "logs.snmp"},
		},
	}

	for _, c := range collectors {
		t.Run(strings.SplitN(c.cn, "-", 2)[0], func(t *testing.T) {
			// A real bundle's collector sends its credential too; the leaf ignores it.
			conn := connectToLeaf(t, pki, leaf, c.cn, nats.UserCredentials(creds))
			collector, err := conn.JetStream()
			if err != nil {
				t.Fatal(err)
			}

			for _, subject := range c.allowed {
				before := streamMessages(t, js, c.stream)
				publishUntilAcked(t, collector, subject)
				if after := streamMessages(t, js, c.stream); after != before+1 {
					t.Errorf("%s: hub stream %s went from %d to %d messages", subject, c.stream, before, after)
				}
			}

			for _, subject := range c.denied {
				before := streamMessages(t, js, c.stream)
				if _, err := collector.Publish(subject, []byte(`{}`), nats.AckWait(300*time.Millisecond)); !deniedJS(err) {
					t.Errorf("publish %s: got %v, want a denied (timed out) request", subject, err)
				}
				if after := streamMessages(t, js, c.stream); after != before {
					t.Errorf("denied publish %s reached the hub stream", subject)
				}
			}

			for _, api := range []string{"$JS.API.STREAM.CREATE.owned", "$JS.API.STREAM.DELETE.events", "$JS.API.STREAM.INFO.events"} {
				if _, err := conn.Request(api, nil, 300*time.Millisecond); !errors.Is(err, nats.ErrTimeout) {
					t.Errorf("request %s: got %v, want a denied (timed out) request", api, err)
				}
			}
		})
	}

	t.Run("a collector cannot read what others publish", func(t *testing.T) {
		denied := make(chan error, 1)
		conn := connectToLeaf(t, pki, leaf, collectors[0].cn, nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
			select {
			case denied <- err:
			default:
			}
		}))
		if _, err := conn.SubscribeSync("logs.syslog"); err != nil {
			t.Fatal(err)
		}
		if err := conn.Flush(); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-denied:
			if !isPermErr(err) {
				t.Errorf("subscribe logs.syslog: got %v, want a permissions violation", err)
			}
		case <-time.After(2 * time.Second):
			t.Error("subscribe logs.syslog was not denied")
		}
	})

	t.Run("a CA-signed certificate with no user is refused", func(t *testing.T) {
		assertLeafRefuses(t, pki, leaf, "flowgger-99999999999999999999999999999999.default.serviceradar")
	})
}

func TestLeafWithNoCollectorsRefusesEveryClient(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	pki := newLeafTestPKI(t)
	hub, leafPort := runLeafTestHub(t, pki)
	leaf := runRenderedLeaf(t, pki, hub, leafPort, "leaf-no-collectors.conf")

	assertLeafRefuses(t, pki, leaf, "flowgger-11111111222243338444555555550001.default.serviceradar")
}

func assertLeafRefuses(t *testing.T, pki *leafTestPKI, leaf *server.Server, cn string) {
	t.Helper()

	clientCert, clientKey := pki.issue(t, cn, nil, nil)
	conn, err := nats.Connect(leaf.ClientURL(), nats.RootCAs(pki.caFile), nats.ClientCert(clientCert, clientKey), nats.MaxReconnects(0))
	if err == nil {
		conn.Close()
		t.Fatalf("%s connected to the leaf, want it refused", cn)
	}
	if !errors.Is(err, nats.ErrAuthorization) {
		t.Fatalf("%s: got %v, want an authorization violation", cn, err)
	}
}

// Interest in the hub stream reaches the leaf a moment after the link comes up, and
// until then a publish has no responders.
func publishUntilAcked(t *testing.T, js nats.JetStreamContext, subject string) {
	t.Helper()

	deadline := time.Now().Add(10 * time.Second)
	for {
		_, err := js.Publish(subject, []byte(`{}`), nats.AckWait(time.Second))
		if err == nil {
			return
		}
		if !errors.Is(err, nats.ErrNoStreamResponse) || time.Now().After(deadline) {
			t.Fatalf("publish %s: %v", subject, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func streamMessages(t *testing.T, js nats.JetStreamContext, stream string) uint64 {
	t.Helper()

	info, err := js.StreamInfo(stream)
	if err != nil {
		t.Fatalf("stream info %s: %v", stream, err)
	}
	return info.State.Msgs
}

func leafTestCreds(t *testing.T) string {
	t.Helper()

	operator, _, err := accounts.BootstrapOperator("leaf-test", "", true)
	if err != nil {
		t.Fatal(err)
	}
	account, err := accounts.NewAccountSigner(operator).CreateAccount("platform", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	creds, err := accounts.GenerateUserCredentials("platform", account.AccountSeed, "edge-collector", accounts.CredentialTypeCollector,
		&accounts.UserPermissions{PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{"_INBOX.>"}}, 0)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "collector.creds")
	if err := os.WriteFile(path, []byte(creds.CredsFileContent), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func connectToLeaf(t *testing.T, pki *leafTestPKI, leaf *server.Server, cn string, opts ...nats.Option) *nats.Conn {
	t.Helper()

	clientCert, clientKey := pki.issue(t, cn, nil, nil)
	opts = append(opts, nats.RootCAs(pki.caFile), nats.ClientCert(clientCert, clientKey))
	conn, err := nats.Connect(leaf.ClientURL(), opts...)
	if err != nil {
		t.Fatalf("connect %s: %v", cn, err)
	}
	t.Cleanup(conn.Close)
	return conn
}

func connectHubAdmin(t *testing.T, pki *leafTestPKI, hub *server.Server) *nats.Conn {
	t.Helper()

	clientCert, clientKey := pki.issue(t, "hub-admin", nil, nil)
	conn, err := nats.Connect(hub.ClientURL(), nats.RootCAs(pki.caFile), nats.ClientCert(clientCert, clientKey))
	if err != nil {
		t.Fatalf("connect hub admin: %v", err)
	}
	t.Cleanup(conn.Close)
	return conn
}

// Mirrors helm/serviceradar/templates/nats.yaml: leaf certificates bind to the
// platform account by their role URI SAN.
func runLeafTestHub(t *testing.T, pki *leafTestPKI) (*server.Server, int) {
	t.Helper()

	free, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	leafPort := free.Addr().(*net.TCPAddr).Port
	_ = free.Close()

	serverCert, serverKey := pki.issue(t, "hub.example.com", []string{"localhost"}, nil)
	tlsBlock := fmt.Sprintf(`tls { cert_file: %q, key_file: %q, ca_file: %q, verify_and_map: true, timeout: 5 }`, serverCert, serverKey, pki.caFile)
	conf := fmt.Sprintf(`server_name: hub
listen: 127.0.0.1:-1
jetstream { store_dir: %q, max_memory_store: 1G, max_file_store: 1G }
%s
leafnodes {
  listen: 127.0.0.1:%d
  %s
  authorization { users: [ { user: %q, account: PLATFORM } ] }
}
accounts {
  SYS: { users: [] }
  PLATFORM: {
    jetstream: enabled
    users: [ { user: "CN=hub-admin", permissions: { publish: { allow: [">"] }, subscribe: { allow: [">"] } } } ]
  }
}
system_account: SYS
`, t.TempDir(), tlsBlock, leafPort, tlsBlock, leafRoleURI)

	return runLeafTestServer(t, conf), leafPort
}

func runRenderedLeaf(t *testing.T, pki *leafTestPKI, hub *server.Server, leafPort int, fixture string) *server.Server {
	t.Helper()

	rendered, err := os.ReadFile(filepath.Join("testdata", fixture))
	if err != nil {
		t.Fatal(err)
	}

	serverCert, serverKey := pki.issue(t, "leaf-site01-server.default.serviceradar", []string{"localhost"}, nil)
	leafCert, leafKey := pki.issue(t, "leaf-site01.default.serviceradar", nil, []string{leafRoleURI})

	replacer := strings.NewReplacer(
		"/etc/nats/certs/nats-server.pem", serverCert,
		"/etc/nats/certs/nats-server-key.pem", serverKey,
		"/etc/nats/certs/nats-leaf.pem", leafCert,
		"/etc/nats/certs/nats-leaf-key.pem", leafKey,
		"/etc/nats/certs/ca-chain.pem", pki.caFile,
		"/var/lib/nats/jetstream", t.TempDir(),
		"/var/log/nats/nats.log", filepath.Join(t.TempDir(), "nats.log"),
		"listen: 0.0.0.0:4222", "listen: 127.0.0.1:-1",
		"tls://hub.example.com:7422", fmt.Sprintf("tls://localhost:%d", leafPort),
	)
	conf := replacer.Replace(string(rendered))

	leaf := runLeafTestServer(t, conf)

	deadline := time.Now().Add(10 * time.Second)
	for hub.NumLeafNodes() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("leaf did not connect to the hub")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return leaf
}

func runLeafTestServer(t *testing.T, conf string) *server.Server {
	t.Helper()

	path := filepath.Join(t.TempDir(), "nats.conf")
	if err := os.WriteFile(path, []byte(conf), 0o600); err != nil {
		t.Fatal(err)
	}
	opts, err := server.ProcessConfigFile(path)
	if err != nil {
		t.Fatalf("parse config: %v\n%s", err, conf)
	}
	opts.NoSigs = true
	srv := runACLServer(t, opts)
	t.Cleanup(func() {
		srv.Shutdown()
		srv.WaitForShutdown()
	})
	return srv
}

// An invented CA. Issued certificates carry the SANs CertIssuer gives them: a DNS
// name equal to the CN and a SPIFFE URI, so the leaf maps by subject as it would in
// production.
type leafTestPKI struct {
	dir    string
	caFile string
	caCert *x509.Certificate
	caKey  *ecdsa.PrivateKey
	serial int64
}

func newLeafTestPKI(t *testing.T) *leafTestPKI {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Invented Test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	caFile := filepath.Join(dir, "ca-chain.pem")
	writePEM(t, caFile, "CERTIFICATE", der)
	return &leafTestPKI{dir: dir, caFile: caFile, caCert: cert, caKey: key, serial: 1}
}

func (p *leafTestPKI) issue(t *testing.T, cn string, extraDNS, extraURIs []string) (string, string) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p.serial++

	uris := []*url.URL{{Scheme: "spiffe", Host: "serviceradar.local", Path: "/collector/default/" + cn}}
	for _, raw := range extraURIs {
		parsed, err := url.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		uris = []*url.URL{parsed}
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(p.serial),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     append([]string{cn}, extraDNS...),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		URIs:         uris,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, p.caCert, &key.PublicKey, p.caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}

	certFile := filepath.Join(p.dir, fmt.Sprintf("%d.pem", p.serial))
	keyFile := filepath.Join(p.dir, fmt.Sprintf("%d-key.pem", p.serial))
	writePEM(t, certFile, "CERTIFICATE", der)
	writePEM(t, keyFile, "EC PRIVATE KEY", keyDER)
	return certFile, keyFile
}

func writePEM(t *testing.T, path, kind string, der []byte) {
	t.Helper()

	encoded := pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: der})
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}
