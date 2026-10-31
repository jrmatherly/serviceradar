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
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nkeys"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

const testGiB = int64(1) << 30

// bootstrapLocalCreds runs the real local nats-bootstrap into a temp creds
// directory, with whatever SERVICERADAR_NATS_MAX_FILE_STORE the caller set.
func bootstrapLocalCreds(t *testing.T) string {
	t.Helper()

	dir := filepath.Join(t.TempDir(), "creds")
	cfg := &CmdConfig{
		NATSLocalBootstrap:   true,
		NATSOutputDir:        dir,
		NATSOperatorName:     "limits-test-operator",
		NATSJetStream:        true,
		NATSJetStreamDir:     filepath.Join(dir, "js"),
		NATSNoTLS:            true,
		NATSWriteSystemCreds: true,
		NATSWritePlatform:    true,
		NATSPlatformAccount:  defaultPlatformAccount,
		NATSPlatformUser:     defaultPlatformUser,
		NATSSystemUser:       defaultSystemUser,
		NATSOutputFormat:     outputFormatJSON,
	}
	if err := RunNatsBootstrap(cfg); err != nil {
		t.Fatalf("nats-bootstrap --local: %v", err)
	}

	return dir
}

// platformAccountJWT returns the platform account JWT file and its claims.
func platformAccountJWT(t *testing.T, credsDir string) (string, *jwt.AccountClaims) {
	t.Helper()

	seed, err := os.ReadFile(filepath.Join(credsDir, natsOperatorSeedFile))
	if err != nil {
		t.Fatal(err)
	}

	op, err := accounts.NewOperator(&accounts.OperatorConfig{Name: "x", OperatorSeed: strings.TrimSpace(string(seed))})
	if err != nil {
		t.Fatal(err)
	}

	path, token, err := findAccountJWT(filepath.Join(credsDir, natsAccountJWTSubdir), defaultPlatformAccount, op.PublicKey(), &bytes.Buffer{})
	if err != nil || path == "" {
		t.Fatalf("platform account JWT not found: %q %v", path, err)
	}

	claims, err := jwt.DecodeAccountClaims(token)
	if err != nil {
		t.Fatal(err)
	}

	return path, claims
}

func TestNatsBootstrapKeepsDefaultQuotaWithoutProfile(t *testing.T) {
	t.Setenv(accounts.MaxFileStoreEnv, "")

	_, claims := platformAccountJWT(t, bootstrapLocalCreds(t))
	js := claims.Limits.JetStreamLimits

	if js.DiskStorage != 8*testGiB || js.DiskMaxStreamBytes != 5*testGiB || !js.MaxBytesRequired {
		t.Fatalf("without a profile the platform account must keep the default quota, got %+v", js)
	}
}

func TestNatsBootstrapSizesQuotaFromProfile(t *testing.T) {
	t.Setenv(accounts.MaxFileStoreEnv, "30G")

	_, claims := platformAccountJWT(t, bootstrapLocalCreds(t))
	js := claims.Limits.JetStreamLimits

	if js.DiskStorage != 30_000_000_000 || js.DiskMaxStreamBytes != 0 || !js.MaxBytesRequired {
		t.Fatalf("platform account quota = %+v, want DiskStorage 30000000000, no per-stream cap, max bytes required", js)
	}
}

func TestNatsBootstrapRejectsInvalidProfileSize(t *testing.T) {
	t.Setenv(accounts.MaxFileStoreEnv, "thirty")

	cfg := &CmdConfig{
		NATSLocalBootstrap:  true,
		NATSOutputDir:       filepath.Join(t.TempDir(), "creds"),
		NATSNoTLS:           true,
		NATSWritePlatform:   true,
		NATSPlatformAccount: defaultPlatformAccount,
		NATSOutputFormat:    outputFormatJSON,
	}
	if err := RunNatsBootstrap(cfg); !errors.Is(err, accounts.ErrInvalidMaxFileStore) {
		t.Fatalf("RunNatsBootstrap with an invalid size = %v, want ErrInvalidMaxFileStore", err)
	}
}

func TestResizeAccountJetStreamNoOps(t *testing.T) {
	t.Setenv(accounts.MaxFileStoreEnv, "")
	credsDir := bootstrapLocalCreds(t)
	path, _ := platformAccountJWT(t, credsDir)

	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer

	if changed, err := resizeAccountJetStream(credsDir, defaultPlatformAccount, "seed-unused", nil, &out); err != nil || changed {
		t.Fatalf("nil sizing: changed=%v err=%v", changed, err)
	}

	sizing := &accounts.JetStreamSizing{DiskStorage: 30_000_000_000}

	out.Reset()

	if changed, err := resizeAccountJetStream(credsDir, defaultPlatformAccount, "", sizing, &out); err != nil || changed {
		t.Fatalf("missing seed: changed=%v err=%v", changed, err)
	}

	if !strings.Contains(out.String(), "WARNING: no operator seed") {
		t.Fatalf("missing seed was not reported: %q", out.String())
	}

	seed, err := os.ReadFile(filepath.Join(credsDir, natsOperatorSeedFile))
	if err != nil {
		t.Fatal(err)
	}

	if changed, err := resizeAccountJetStream(credsDir, "no-such-account", string(seed), sizing, &out); err != nil || changed {
		t.Fatalf("unknown account: changed=%v err=%v", changed, err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Equal(before, after) {
		t.Fatal("a no-op run rewrote the platform account JWT")
	}
}

// TestExistingInstallConvergesToProfileQuota is the Compose upgrade path: an
// install bootstrapped with the fixed 8 GiB / 5 GiB quota cannot place the
// small profile's streams; nats-account-limits re-issues the account JWT under
// the same key, the resolver directory is refreshed the way nats-config-init
// copies it, and after a NATS restart the same user credentials can create
// them. A second run changes nothing.
func TestExistingInstallConvergesToProfileQuota(t *testing.T) {
	if testing.Short() {
		t.Skip("boots an embedded nats-server")
	}

	t.Setenv(accounts.MaxFileStoreEnv, "")
	credsDir := bootstrapLocalCreds(t)
	path, oldClaims := platformAccountJWT(t, credsDir)
	storeDir := filepath.Join(t.TempDir(), "jetstream")

	// Old quota: a second 4.5 GiB stream exceeds the 8 GiB account quota, and
	// a 6 GiB stream the 5 GiB per-stream cap.
	half := 9 * testGiB / 2

	withPlatformJetStream(t, credsDir, storeDir, func(js nats.JetStreamContext) {
		_, err := js.AddStream(&nats.StreamConfig{Name: "wide", Subjects: []string{"wide.>"}, MaxBytes: 6 * testGiB})
		if !isAPIError(err, jsErrMaxStreamBytesExceeded) {
			t.Fatalf("6 GiB stream under the default 5 GiB per-stream cap: got %v, want max stream bytes exceeded", err)
		}

		if _, err := js.AddStream(&nats.StreamConfig{Name: "first", Subjects: []string{"first.>"}, MaxBytes: half}); err != nil {
			t.Fatalf("first 4.5 GiB stream under the default quota: %v", err)
		}

		_, err = js.AddStream(&nats.StreamConfig{Name: "second", Subjects: []string{"second.>"}, MaxBytes: half})
		if !isAPIError(err, jsErrStorageResourcesExceeded) {
			t.Fatalf("second 4.5 GiB stream under the default 8 GiB account quota: got %v, want insufficient storage resources", err)
		}
	})

	t.Setenv(accounts.MaxFileStoreEnv, "30G")
	t.Setenv(natsOperatorSeedEnv, "")

	if err := RunNatsAccountLimits(&CmdConfig{NATSOutputDir: credsDir, NATSPlatformAccount: defaultPlatformAccount}); err != nil {
		t.Fatalf("nats-account-limits: %v", err)
	}

	_, newClaims := platformAccountJWT(t, credsDir)
	if newClaims.Subject != oldClaims.Subject || newClaims.Name != oldClaims.Name {
		t.Fatalf("account identity changed: %s/%s -> %s/%s", oldClaims.Name, oldClaims.Subject, newClaims.Name, newClaims.Subject)
	}

	if got := newClaims.Limits.JetStreamLimits; got.DiskStorage != 30_000_000_000 || got.DiskMaxStreamBytes != 0 || !got.MaxBytesRequired {
		t.Fatalf("re-issued quota = %+v", got)
	}

	resized, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer

	seed, err := os.ReadFile(filepath.Join(credsDir, natsOperatorSeedFile))
	if err != nil {
		t.Fatal(err)
	}

	sizing := &accounts.JetStreamSizing{DiskStorage: 30_000_000_000}
	if changed, err := resizeAccountJetStream(credsDir, defaultPlatformAccount, string(seed), sizing, &out); err != nil || changed {
		t.Fatalf("second run: changed=%v err=%v", changed, err)
	}

	again, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Equal(resized, again) {
		t.Fatal("the second run rewrote an already-sized account JWT")
	}

	withPlatformJetStream(t, credsDir, storeDir, func(js nats.JetStreamContext) {
		// 4.5 GiB already placed plus these: 24 GiB of the 27.94 GiB quota.
		for _, cfg := range []*nats.StreamConfig{
			{Name: "second", Subjects: []string{"second.>"}, MaxBytes: half},
			{Name: "wide", Subjects: []string{"wide.>"}, MaxBytes: 6 * testGiB},
			{Name: "big", Subjects: []string{"big.>"}, MaxBytes: 9 * testGiB},
		} {
			if _, err := js.AddStream(cfg); err != nil {
				t.Fatalf("stream %s (%d bytes) under the re-issued quota: %v", cfg.Name, cfg.MaxBytes, err)
			}
		}

		_, err := js.AddStream(&nats.StreamConfig{Name: "unbounded", Subjects: []string{"unbounded.>"}})
		if !isAPIError(err, jsErrMaxBytesRequired) {
			t.Fatalf("stream without max_bytes: got %v, want max bytes required", err)
		}
	})
}

// JetStream API error codes the account quota checks return.
const (
	jsErrStorageResourcesExceeded nats.ErrorCode = 10047
	jsErrMaxBytesRequired         nats.ErrorCode = 10113
	jsErrMaxStreamBytesExceeded   nats.ErrorCode = 10122
)

func isAPIError(err error, code nats.ErrorCode) bool {
	var apiErr *nats.APIError

	return errors.As(err, &apiErr) && apiErr.ErrorCode == code
}

// withPlatformJetStream starts nats-server in operator mode with a full
// resolver whose directory is a fresh copy of credsDir/jwt, as Compose's
// nats-config-init prepares it, connects with platform.creds and runs fn.
func withPlatformJetStream(t *testing.T, credsDir, storeDir string, fn func(nats.JetStreamContext)) {
	t.Helper()
	withJetStreamAs(t, credsDir, storeDir, "platform.creds", fn)
}

// withJetStreamAs is withPlatformJetStream connecting with credsDir/credsFile.
func withJetStreamAs(t *testing.T, credsDir, storeDir, credsFile string, fn func(nats.JetStreamContext)) {
	t.Helper()

	resolverDir := t.TempDir()

	entries, err := os.ReadDir(filepath.Join(credsDir, natsAccountJWTSubdir))
	if err != nil {
		t.Fatal(err)
	}

	for _, e := range entries {
		data, err := os.ReadFile(filepath.Join(credsDir, natsAccountJWTSubdir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}

		if err := os.WriteFile(filepath.Join(resolverDir, e.Name()), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	systemAccount, err := os.ReadFile(filepath.Join(credsDir, "system_account.pub"))
	if err != nil {
		t.Fatal(err)
	}

	confPath := filepath.Join(t.TempDir(), "nats.conf")
	conf := fmt.Sprintf(`listen: 127.0.0.1:-1
operator: %q
system_account: %s
resolver: { type: full, dir: %q }
jetstream { store_dir: %q, max_memory_store: 1G, max_file_store: 30G }
`, filepath.Join(credsDir, "operator.jwt"), strings.TrimSpace(string(systemAccount)), resolverDir, storeDir)

	if err := os.WriteFile(confPath, []byte(conf), 0o600); err != nil {
		t.Fatal(err)
	}

	opts, err := server.ProcessConfigFile(confPath)
	if err != nil {
		t.Fatalf("process nats config: %v", err)
	}

	opts.NoLog, opts.NoSigs = true, true

	srv, err := server.NewServer(opts)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	go srv.Start()

	defer srv.Shutdown()

	if !srv.ReadyForConnections(10 * time.Second) {
		t.Fatal("embedded nats server not ready")
	}

	if !srv.JetStreamEnabled() {
		t.Fatal("embedded nats server started without JetStream")
	}

	connect := func(file string) nats.JetStreamContext {
		nc, err := nats.Connect(srv.ClientURL(), nats.UserCredentials(filepath.Join(credsDir, file)))
		if err != nil {
			t.Fatalf("connect with %s: %v", file, err)
		}
		t.Cleanup(nc.Close)

		js, err := nc.JetStream()
		if err != nil {
			t.Fatal(err)
		}

		return js
	}

	// The account's JetStream is enabled once the resolver has loaded it. Probe
	// with platform.creds: scoped identities may not call $JS.API.INFO.
	platform := connect("platform.creds")
	deadline := time.Now().Add(10 * time.Second)

	for {
		_, err := platform.AccountInfo()
		if err == nil {
			break
		}

		if time.Now().After(deadline) {
			t.Fatalf("platform account JetStream never became available: %v", err)
		}

		time.Sleep(50 * time.Millisecond)
	}

	js := platform
	if credsFile != "platform.creds" {
		js = connect(credsFile)
	}

	fn(js)
}

// The resolver's copy of the account holds revocations that creds/jwt never sees,
// so a quota change must reach it in place.
func TestAccountLimitsResizeResolverCopyKeepsRevocations(t *testing.T) {
	t.Setenv(accounts.MaxFileStoreEnv, "")
	credsDir := bootstrapLocalCreds(t)
	credsPath, _ := platformAccountJWT(t, credsDir)

	seed, err := os.ReadFile(filepath.Join(credsDir, natsOperatorSeedFile))
	if err != nil {
		t.Fatal(err)
	}
	op, err := accounts.NewOperator(&accounts.OperatorConfig{Name: "x", OperatorSeed: strings.TrimSpace(string(seed))})
	if err != nil {
		t.Fatal(err)
	}

	token, err := os.ReadFile(credsPath)
	if err != nil {
		t.Fatal(err)
	}
	kp, err := nkeys.CreateUser()
	if err != nil {
		t.Fatal(err)
	}
	userKey, err := kp.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	revoked, err := accounts.NewAccountSigner(op).RevokeUsers(string(token), []string{userKey})
	if err != nil {
		t.Fatal(err)
	}

	dataDir := t.TempDir()
	resolverDir := filepath.Join(dataDir, natsAccountJWTSubdir)
	if err := os.MkdirAll(resolverDir, 0o755); err != nil {
		t.Fatal(err)
	}
	resolverPath := filepath.Join(resolverDir, filepath.Base(credsPath))
	if err := os.WriteFile(resolverPath, []byte(revoked), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv(accounts.MaxFileStoreEnv, "30G")
	if err := RunNatsAccountLimits(&CmdConfig{
		NATSOutputDir:       credsDir,
		NATSPlatformAccount: defaultPlatformAccount,
		NATSResolverDataDir: dataDir,
	}); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(resolverPath)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := jwt.DecodeAccountClaims(string(data))
	if err != nil {
		t.Fatal(err)
	}
	if claims.Limits.DiskStorage != 30_000_000_000 {
		t.Errorf("resolver copy quota = %d, want the profile's", claims.Limits.DiskStorage)
	}
	if _, ok := claims.Revocations[userKey]; !ok {
		t.Error("resizing the resolver copy lost its revocation")
	}
}

// Each copy of the JWT is resized on its own, and a failure names the copy that
// kept its quota, because the two can now disagree.
func TestAccountLimitsReportsEachCopyOnItsOwn(t *testing.T) {
	brokenDir := func(t *testing.T) string {
		t.Helper()
		dir := t.TempDir()
		// A file where the jwt/ directory belongs, which fails whoever runs the test.
		if err := os.WriteFile(filepath.Join(dir, natsAccountJWTSubdir), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		return dir
	}
	diskStorage := func(t *testing.T, path string) int64 {
		t.Helper()
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		claims, err := jwt.DecodeAccountClaims(string(data))
		if err != nil {
			t.Fatal(err)
		}
		return claims.Limits.DiskStorage
	}
	const quota = 30_000_000_000

	t.Run("a broken resolver copy still resizes creds", func(t *testing.T) {
		t.Setenv(accounts.MaxFileStoreEnv, "")
		credsDir := bootstrapLocalCreds(t)
		credsPath, _ := platformAccountJWT(t, credsDir)

		t.Setenv(accounts.MaxFileStoreEnv, "30G")
		err := RunNatsAccountLimits(&CmdConfig{
			NATSOutputDir:       credsDir,
			NATSPlatformAccount: defaultPlatformAccount,
			NATSResolverDataDir: brokenDir(t),
		})
		if err == nil || !strings.Contains(err.Error(), "resolver copy") || strings.Contains(err.Error(), "creds copy") {
			t.Errorf("error = %v, want one naming only the resolver copy", err)
		}
		if got := diskStorage(t, credsPath); got != quota {
			t.Errorf("creds copy quota = %d, want %d", got, quota)
		}
	})

	t.Run("a broken creds copy still resizes the resolver", func(t *testing.T) {
		t.Setenv(accounts.MaxFileStoreEnv, "")
		goodCreds := bootstrapLocalCreds(t)
		goodPath, _ := platformAccountJWT(t, goodCreds)
		seed, err := os.ReadFile(filepath.Join(goodCreds, natsOperatorSeedFile))
		if err != nil {
			t.Fatal(err)
		}
		t.Setenv(natsOperatorSeedEnv, strings.TrimSpace(string(seed)))

		t.Setenv(accounts.MaxFileStoreEnv, "30G")
		err = RunNatsAccountLimits(&CmdConfig{
			NATSOutputDir:       brokenDir(t),
			NATSPlatformAccount: defaultPlatformAccount,
			NATSResolverDataDir: goodCreds,
		})
		if err == nil || !strings.Contains(err.Error(), "creds copy") || strings.Contains(err.Error(), "resolver copy") {
			t.Errorf("error = %v, want one naming only the creds copy", err)
		}
		if got := diskStorage(t, goodPath); got != quota {
			t.Errorf("resolver copy quota = %d, want %d", got, quota)
		}
	})
}
