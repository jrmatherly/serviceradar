package datasvc

import (
	"crypto/x509/pkix"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nats-io/jwt/v2"
	natsserver "github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
	"github.com/carverauto/serviceradar/proto"
)

const (
	revokeTestAccount  = "platform"
	revokeTestIdentity = "CN=core.serviceradar,O=ServiceRadar"
	revokeTestHost     = "127.0.0.1"
	revokeTestInbox    = "_INBOX.>"
)

// revokeFixture is a real nats-server with the full resolver Compose runs, and a
// NATSAccountServer wired to it the way data-services wires it.
type revokeFixture struct {
	srv         *natsserver.Server
	service     *NATSAccountServer
	accountKey  string
	accountSeed string
	systemSeed  string
	dir         string
}

func newRevokeFixture(t *testing.T) *revokeFixture {
	t.Helper()

	operator, boot, err := accounts.BootstrapOperator("revoke-test", "", true)
	require.NoError(t, err)

	signer := accounts.NewAccountSigner(operator).WithJetStreamSizing(&accounts.JetStreamSizing{DiskStorage: 1 << 30})
	account, err := signer.CreateAccount(revokeTestAccount, nil, nil, nil)
	require.NoError(t, err)

	dir := t.TempDir()
	for key, token := range map[string]string{
		boot.SystemAccountPublicKey: boot.SystemAccountJWT,
		account.AccountPublicKey:    account.AccountJWT,
	} {
		require.NoError(t, os.WriteFile(filepath.Join(dir, key+".jwt"), []byte(token), 0o600))
	}

	resolver, err := natsserver.NewDirAccResolver(dir, 0, time.Minute, natsserver.NoDelete)
	require.NoError(t, err)

	operatorClaims, err := jwt.DecodeOperatorClaims(boot.OperatorJWT)
	require.NoError(t, err)

	srv, err := natsserver.NewServer(&natsserver.Options{
		Host:             revokeTestHost,
		Port:             -1,
		JetStream:        true,
		StoreDir:         t.TempDir(),
		TrustedOperators: []*jwt.OperatorClaims{operatorClaims},
		AccountResolver:  resolver,
		SystemAccount:    boot.SystemAccountPublicKey,
		NoLog:            true,
		NoSigs:           true,
	})
	require.NoError(t, err)
	go srv.Start()
	t.Cleanup(srv.Shutdown)
	require.True(t, srv.ReadyForConnections(10*time.Second))

	service := NewNATSAccountServer(operator)
	service.SetAllowedClientIdentities([]string{revokeTestIdentity})
	service.SetPlatformAccount(revokeTestAccount, account.AccountSeed)

	f := &revokeFixture{
		srv:         srv,
		service:     service,
		accountKey:  account.AccountPublicKey,
		accountSeed: account.AccountSeed,
		systemSeed:  boot.SystemAccountSeed,
		dir:         dir,
	}
	service.SetResolverClient(srv.ClientURL(), nil, f.systemCredsFile(t, accounts.SystemResolverPermissions()))

	return f
}

func (f *revokeFixture) systemCredsFile(t *testing.T, permissions *accounts.UserPermissions) string {
	t.Helper()

	creds, err := accounts.GenerateUserCredentials("SYS", f.systemSeed, "system-resolver",
		accounts.CredentialTypeService, permissions, 0)
	require.NoError(t, err)
	file := filepath.Join(t.TempDir(), "system.creds")
	require.NoError(t, os.WriteFile(file, []byte(creds.CredsFileContent), 0o600))

	return file
}

// assertHubRefused keeps a broken fixture, which also fails to connect, from
// passing as a refusal.
func assertHubRefused(t *testing.T, err error) {
	t.Helper()

	require.Error(t, err, "the hub accepted a revoked credential")
	assert.True(t, errors.Is(err, nats.ErrAuthorization) || errors.Is(err, nats.ErrAuthRevoked),
		"expected an authorization refusal, got: %v", err)
}

func (f *revokeFixture) mint(t *testing.T, user string) (publicKey, credsFile string) {
	t.Helper()

	resp, err := f.service.GenerateUserCredentials(authorizedContext(), &proto.GenerateUserCredentialsRequest{
		AccountName:    revokeTestAccount,
		UserName:       user,
		CredentialType: proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR,
		Permissions:    mintablePermissions(),
	})
	require.NoError(t, err)

	credsFile = filepath.Join(t.TempDir(), user+".creds")
	require.NoError(t, os.WriteFile(credsFile, []byte(resp.GetCredsFileContent()), 0o600))

	return resp.GetUserPublicKey(), credsFile
}

func (f *revokeFixture) connect(creds string, opts ...nats.Option) (*nats.Conn, error) {
	return nats.Connect(f.srv.ClientURL(), append(opts, nats.UserCredentials(creds), nats.NoReconnect())...)
}

func (f *revokeFixture) revoke(t *testing.T, keys ...string) {
	t.Helper()

	resp, err := f.service.RevokeUsers(authorizedContext(), &proto.RevokeUsersRequest{
		AccountName:    revokeTestAccount,
		UserPublicKeys: keys,
	})
	require.NoError(t, err)
	assert.Equal(t, f.accountKey, resp.GetAccountPublicKey())
}

func (f *revokeFixture) accountClaims(t *testing.T) *jwt.AccountClaims {
	t.Helper()

	token, err := f.service.lookupAccountJWT(f.accountKey)
	require.NoError(t, err)
	claims, err := jwt.DecodeAccountClaims(token)
	require.NoError(t, err)

	return claims
}

// pushesSeen counts the account JWTs reaching the hub, so a test can tell "nothing
// was pushed" from "the same claims were pushed again".
func (f *revokeFixture) pushesSeen(t *testing.T) *atomic.Int32 {
	t.Helper()

	conn, err := nats.Connect(f.srv.ClientURL(), nats.UserCredentials(f.systemCredsFile(t, &accounts.UserPermissions{
		SubscribeAllow: []string{"$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE"},
	})))
	require.NoError(t, err)
	t.Cleanup(conn.Close)

	var pushes atomic.Int32
	_, err = conn.Subscribe("$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE", func(*nats.Msg) { pushes.Add(1) })
	require.NoError(t, err)
	require.NoError(t, conn.Flush())

	return &pushes
}

// setRevocations replaces what the hub holds, standing in for a lost nats-data
// volume or for revocations made long ago.
func (f *revokeFixture) setRevocations(t *testing.T, revocations jwt.RevocationList) {
	t.Helper()

	claims := f.accountClaims(t)
	claims.Revocations = revocations
	token, err := f.service.operator.SignAccountClaims(claims)
	require.NoError(t, err)
	_, err = f.service.pushAccountJWT(f.accountKey, token)
	require.NoError(t, err)
}

func TestRevokeUsersRefusesTheUserAndNoOtherOnTheHub(t *testing.T) {
	f := newRevokeFixture(t)

	revokedKey, revokedCreds := f.mint(t, "edge-trapd-a")
	_, otherCreds := f.mint(t, "edge-trapd-b")

	closed := make(chan struct{})
	open, err := f.connect(revokedCreds, nats.ClosedHandler(func(*nats.Conn) { close(closed) }))
	require.NoError(t, err, "a credential must connect before it is revoked")
	t.Cleanup(open.Close)

	f.revoke(t, revokedKey)

	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the revoked user's open connection was not closed")
	}

	_, err = f.connect(revokedCreds)
	assertHubRefused(t, err)

	other, err := f.connect(otherCreds)
	require.NoError(t, err, "revoking one user refused another")
	other.Close()
}

// A re-issue built from defaults instead of the live claims would drop the quota
// nats-account-limits set and un-revoke every earlier user.
func TestRevokeUsersKeepsTheOtherClaims(t *testing.T) {
	f := newRevokeFixture(t)

	firstKey, firstCreds := f.mint(t, "edge-trapd-a")
	secondKey, _ := f.mint(t, "edge-trapd-b")

	before := f.accountClaims(t)
	require.Equal(t, int64(1<<30), before.Limits.DiskStorage, "fixture needs a non-default quota")

	f.revoke(t, firstKey)
	f.revoke(t, secondKey)

	after := f.accountClaims(t)
	assert.Equal(t, before.Limits, after.Limits)
	assert.Contains(t, after.Revocations, firstKey)
	assert.Contains(t, after.Revocations, secondKey)

	_, err := f.connect(firstCreds)
	assertHubRefused(t, err)
}

// The replay job asks every five minutes, so an answer that changes nothing must
// not re-sign the JWT or disturb the hub.
func TestRevokeUsersSkipsThePushWhenEveryKeyIsAlreadyRevoked(t *testing.T) {
	f := newRevokeFixture(t)
	revokedAt := time.Now().Add(-time.Hour)
	firstKey, _ := f.mint(t, "edge-trapd-a")
	secondKey, _ := f.mint(t, "edge-trapd-b")
	f.setRevocations(t, jwt.RevocationList{firstKey: revokedAt.Unix(), secondKey: revokedAt.Unix()})

	before, err := f.service.lookupAccountJWT(f.accountKey)
	require.NoError(t, err)
	pushes := f.pushesSeen(t)

	resp, err := f.service.RevokeUsers(authorizedContext(), &proto.RevokeUsersRequest{
		AccountName:    revokeTestAccount,
		UserPublicKeys: []string{firstKey, secondKey},
	})
	require.NoError(t, err)

	assert.Equal(t, f.accountKey, resp.GetAccountPublicKey())
	assert.Zero(t, resp.GetNewlyRevoked())

	after, err := f.service.lookupAccountJWT(f.accountKey)
	require.NoError(t, err)
	assert.Equal(t, before, after, "the resolver's JWT changed")

	// The hub orders pushes, so a skipped push cannot arrive after this one.
	thirdKey, _ := f.mint(t, "edge-trapd-c")
	f.revoke(t, thirdKey)
	require.Eventually(t, func() bool { return pushes.Load() >= 1 }, 5*time.Second, 10*time.Millisecond)
	assert.Equal(t, int32(1), pushes.Load(), "an all-known request pushed a JWT")
}

func TestRevokeUsersAddsOnlyTheNewKeyAndKeepsOlderTimestamps(t *testing.T) {
	f := newRevokeFixture(t)
	revokedAt := time.Now().Add(-time.Hour).Unix()
	oldKey, _ := f.mint(t, "edge-trapd-a")
	newKey, newCreds := f.mint(t, "edge-trapd-b")
	f.setRevocations(t, jwt.RevocationList{oldKey: revokedAt})
	pushes := f.pushesSeen(t)

	resp, err := f.service.RevokeUsers(authorizedContext(), &proto.RevokeUsersRequest{
		AccountName:    revokeTestAccount,
		UserPublicKeys: []string{oldKey, newKey, newKey},
	})
	require.NoError(t, err)

	assert.Equal(t, uint32(1), resp.GetNewlyRevoked())
	require.Eventually(t, func() bool { return pushes.Load() == 1 }, 5*time.Second, 10*time.Millisecond)

	claims := f.accountClaims(t)
	assert.Equal(t, revokedAt, claims.Revocations[oldKey], "an existing revocation moved")
	assert.Contains(t, claims.Revocations, newKey)

	_, err = f.connect(newCreds)
	assertHubRefused(t, err)
}

// A replacement credential is a new key, so it survives every replay of the old one.
func TestRevokeUsersReappliesWhatTheHubLostAndSparesOtherKeys(t *testing.T) {
	f := newRevokeFixture(t)
	revokedKey, revokedCreds := f.mint(t, "edge-trapd-a")
	_, otherCreds := f.mint(t, "edge-trapd-b")

	f.revoke(t, revokedKey)
	f.setRevocations(t, nil)

	revived, err := f.connect(revokedCreds)
	require.NoError(t, err, "the fixture must reproduce the lost revocation")
	closed := make(chan struct{})
	revived.SetClosedHandler(func(*nats.Conn) { close(closed) })
	t.Cleanup(revived.Close)

	resp, err := f.service.RevokeUsers(authorizedContext(), &proto.RevokeUsersRequest{
		AccountName:    revokeTestAccount,
		UserPublicKeys: []string{revokedKey},
	})
	require.NoError(t, err)
	assert.Equal(t, uint32(1), resp.GetNewlyRevoked())

	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the replay left the revoked user's connection open")
	}
	_, err = f.connect(revokedCreds)
	assertHubRefused(t, err)

	other, err := f.connect(otherCreds)
	require.NoError(t, err, "the replay refused another user")
	other.Close()
}

func TestRevokeUsersRefusals(t *testing.T) {
	f := newRevokeFixture(t)
	key, _ := f.mint(t, "edge-trapd-a")
	ctx := authorizedContext()

	cases := []struct {
		name    string
		service *NATSAccountServer
		req     *proto.RevokeUsersRequest
		code    codes.Code
	}{
		{"no keys", f.service, &proto.RevokeUsersRequest{AccountName: revokeTestAccount}, codes.InvalidArgument},
		{"other account", f.service, &proto.RevokeUsersRequest{AccountName: "other", UserPublicKeys: []string{key}}, codes.InvalidArgument},
		{"not a user key", f.service, &proto.RevokeUsersRequest{AccountName: revokeTestAccount, UserPublicKeys: []string{f.accountKey}}, codes.InvalidArgument},
		{"no operator", func() *NATSAccountServer {
			s := NewNATSAccountServer(nil)
			s.SetAllowedClientIdentities([]string{revokeTestIdentity})
			s.SetPlatformAccount(revokeTestAccount, f.accountSeed)
			return s
		}(), &proto.RevokeUsersRequest{AccountName: revokeTestAccount, UserPublicKeys: []string{key}}, codes.FailedPrecondition},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := tc.service.RevokeUsers(ctx, tc.req)
			assert.Equal(t, tc.code, status.Code(err), "%v", err)
		})
	}

	t.Run("resolver unreachable", func(t *testing.T) {
		s := NewNATSAccountServer(f.service.operator)
		s.SetAllowedClientIdentities([]string{revokeTestIdentity})
		s.SetPlatformAccount(revokeTestAccount, f.accountSeed)
		_, err := s.RevokeUsers(ctx, &proto.RevokeUsersRequest{AccountName: revokeTestAccount, UserPublicKeys: []string{key}})
		assert.Equal(t, codes.Unavailable, status.Code(err), "%v", err)
	})
}

func TestRevokeUsersRefusesAnUnlistedCaller(t *testing.T) {
	f := newRevokeFixture(t)
	key, _ := f.mint(t, "edge-trapd-a")
	before := f.accountClaims(t)

	_, err := f.service.RevokeUsers(authorizedContextWithSubject(pkix.Name{
		CommonName:   "agent.serviceradar",
		Organization: []string{"ServiceRadar"},
	}), &proto.RevokeUsersRequest{AccountName: revokeTestAccount, UserPublicKeys: []string{key}})

	assert.Equal(t, codes.PermissionDenied, status.Code(err), "%v", err)
	assert.Equal(t, before.Revocations, f.accountClaims(t).Revocations)
}

// A system.creds issued before the LOOKUP grant must not read as a slow hub.
func TestRevokeUsersNamesAMissingResolverGrant(t *testing.T) {
	f := newRevokeFixture(t)
	key, _ := f.mint(t, "edge-trapd-a")

	s := NewNATSAccountServer(f.service.operator)
	s.SetAllowedClientIdentities([]string{revokeTestIdentity})
	s.SetPlatformAccount(revokeTestAccount, f.accountSeed)
	s.SetResolverClient(f.srv.ClientURL(), nil, f.systemCredsFile(t, &accounts.UserPermissions{
		PublishAllow:   []string{"$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE"},
		SubscribeAllow: []string{revokeTestInbox},
		AllowResponses: true,
		MaxResponses:   10,
	}))

	_, err := s.RevokeUsers(authorizedContext(), &proto.RevokeUsersRequest{
		AccountName: revokeTestAccount, UserPublicKeys: []string{key},
	})

	assert.Equal(t, codes.Unavailable, status.Code(err), "%v", err)
	assert.Contains(t, err.Error(), "permission")
	assert.Contains(t, err.Error(), "CLAIMS.LOOKUP")
	assert.NotContains(t, err.Error(), "timeout")
}

// A live resolver only rejects a JWT it cannot store, so a stand-in answers here.
func TestRevokeUsersReportsAResolverRejection(t *testing.T) {
	f := newRevokeFixture(t)
	key, _ := f.mint(t, "edge-trapd-a")
	accountJWT, err := f.service.lookupAccountJWT(f.accountKey)
	require.NoError(t, err)

	standIn, err := natsserver.NewServer(&natsserver.Options{Host: revokeTestHost, Port: -1, NoLog: true, NoSigs: true})
	require.NoError(t, err)
	go standIn.Start()
	t.Cleanup(standIn.Shutdown)
	require.True(t, standIn.ReadyForConnections(10*time.Second))

	responder, err := nats.Connect(standIn.ClientURL())
	require.NoError(t, err)
	t.Cleanup(responder.Close)
	_, err = responder.Subscribe("$SYS.REQ.ACCOUNT.*.CLAIMS.LOOKUP", func(m *nats.Msg) {
		_ = m.Respond([]byte(accountJWT))
	})
	require.NoError(t, err)
	_, err = responder.Subscribe("$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE", func(m *nats.Msg) {
		_ = m.Respond([]byte(`{"error":{"code":500,"description":"invented rejection"}}`))
	})
	require.NoError(t, err)
	require.NoError(t, responder.Flush())

	s := NewNATSAccountServer(f.service.operator)
	s.SetAllowedClientIdentities([]string{revokeTestIdentity})
	s.SetPlatformAccount(revokeTestAccount, f.accountSeed)
	s.SetResolverClient(standIn.ClientURL(), nil, "")

	_, err = s.RevokeUsers(authorizedContext(), &proto.RevokeUsersRequest{
		AccountName: revokeTestAccount, UserPublicKeys: []string{key},
	})

	assert.Equal(t, codes.Unavailable, status.Code(err), "%v", err)
	assert.Contains(t, err.Error(), "invented rejection")
}
