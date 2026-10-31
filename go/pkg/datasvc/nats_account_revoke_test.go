package datasvc

import (
	"errors"
	"os"
	"path/filepath"
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

	// The same grant nats-bootstrap writes to system.creds.
	systemCreds, err := accounts.GenerateUserCredentials("SYS", boot.SystemAccountSeed, "system-resolver",
		accounts.CredentialTypeService, &accounts.UserPermissions{
			PublishAllow:   []string{"$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE", "$SYS.REQ.ACCOUNT.*.CLAIMS.LOOKUP"},
			SubscribeAllow: []string{revokeTestInbox},
			AllowResponses: true,
			MaxResponses:   10,
		}, 0)
	require.NoError(t, err)
	systemCredsFile := filepath.Join(t.TempDir(), "system.creds")
	require.NoError(t, os.WriteFile(systemCredsFile, []byte(systemCreds.CredsFileContent), 0o600))

	service := NewNATSAccountServer(operator)
	service.SetAllowedClientIdentities([]string{revokeTestIdentity})
	service.SetPlatformAccount(revokeTestAccount, account.AccountSeed)
	service.SetResolverClient(srv.ClientURL(), nil, systemCredsFile)

	return &revokeFixture{
		srv:         srv,
		service:     service,
		accountKey:  account.AccountPublicKey,
		accountSeed: account.AccountSeed,
		dir:         dir,
	}
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
	require.Error(t, err, "the hub accepted a revoked credential")
	assert.True(t, errors.Is(err, nats.ErrAuthorization) || errors.Is(err, nats.ErrAuthRevoked),
		"expected an authorization refusal, got: %v", err)

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
	assert.Error(t, err, "a second revocation un-revoked the first")
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
