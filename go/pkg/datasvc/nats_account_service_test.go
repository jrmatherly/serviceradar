/*
 * Copyright 2025 Carver Automation Corporation.
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

package datasvc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"strings"
	"testing"

	"github.com/nats-io/jwt/v2"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
	"github.com/carverauto/serviceradar/proto"
)

func newTestNATSAccountServer(t *testing.T) *NATSAccountServer {
	t.Helper()

	// Generate a test operator
	seed, _, err := accounts.GenerateOperatorKey()
	if err != nil {
		t.Fatalf("Failed to generate operator key: %v", err)
	}

	cfg := &accounts.OperatorConfig{
		Name:         "test-operator",
		OperatorSeed: seed,
	}

	operator, err := accounts.NewOperator(cfg)
	if err != nil {
		t.Fatalf("Failed to create operator: %v", err)
	}

	server := NewNATSAccountServer(operator)
	server.SetAllowedClientIdentities([]string{"CN=core.serviceradar,O=ServiceRadar"})
	return server
}

func authorizedContext() context.Context {
	cert := &x509.Certificate{
		Subject: pkix.Name{
			CommonName:   "core.serviceradar",
			Organization: []string{"ServiceRadar"},
		},
	}
	tlsInfo := credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}}
	p := &peer.Peer{AuthInfo: tlsInfo}
	return peer.NewContext(context.Background(), p)
}

func authorizedContextWithSubject(subject pkix.Name) context.Context {
	cert := &x509.Certificate{Subject: subject}
	tlsInfo := credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}}
	p := &peer.Peer{AuthInfo: tlsInfo}
	return peer.NewContext(context.Background(), p)
}

func TestNATSAccountServerAuthorizeRequestSubjectAliases(t *testing.T) {
	fullDN := "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
	compactDN := "CN=serviceradar-core,O=ServiceRadar"
	ctx := authorizedContextWithSubject(pkix.Name{
		CommonName:         "serviceradar-core",
		Organization:       []string{"ServiceRadar"},
		OrganizationalUnit: []string{"Kubernetes"},
		Locality:           []string{"San Francisco"},
		Province:           []string{"CA"},
		Country:            []string{"US"},
	})

	t.Run("matches full subject identity", func(t *testing.T) {
		server := newTestNATSAccountServer(t)
		server.SetAllowedClientIdentities([]string{fullDN})

		if err := server.authorizeRequest(ctx); err != nil {
			t.Fatalf("authorizeRequest failed for full DN identity: %v", err)
		}
	})

	t.Run("matches compact subject identity", func(t *testing.T) {
		server := newTestNATSAccountServer(t)
		server.SetAllowedClientIdentities([]string{compactDN})

		if err := server.authorizeRequest(ctx); err != nil {
			t.Fatalf("authorizeRequest failed for compact DN identity: %v", err)
		}
	})
}

func TestNATSAccountServer_CreateAccount(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	t.Run("success", func(t *testing.T) {
		req := &proto.CreateAccountRequest{
			AccountName: "acme-corp",
		}

		resp, err := server.CreateAccount(ctx, req)
		if err != nil {
			t.Fatalf("CreateAccount failed: %v", err)
		}

		if resp.AccountPublicKey == "" {
			t.Error("Expected non-empty account public key")
		}
		if !strings.HasPrefix(resp.AccountPublicKey, "A") {
			t.Errorf("Account public key should start with 'A', got: %s", resp.AccountPublicKey)
		}

		if resp.AccountSeed == "" {
			t.Error("Expected non-empty account seed")
		}
		if !strings.HasPrefix(resp.AccountSeed, "SA") {
			t.Errorf("Account seed should start with 'SA', got: %s", resp.AccountSeed[:2])
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("with limits", func(t *testing.T) {
		req := &proto.CreateAccountRequest{
			AccountName: "limited-account",
			Limits: &proto.AccountLimits{
				MaxConnections:   100,
				MaxSubscriptions: 1000,
			},
		}

		resp, err := server.CreateAccount(ctx, req)
		if err != nil {
			t.Fatalf("CreateAccount with limits failed: %v", err)
		}

		if resp.AccountPublicKey == "" {
			t.Error("Expected non-empty account public key")
		}
	})

	t.Run("with subject mappings", func(t *testing.T) {
		req := &proto.CreateAccountRequest{
			AccountName: "mapped-account",
			SubjectMappings: []*proto.SubjectMapping{
				{From: "events.>", To: "mapped-account.events.>"},
			},
		}

		resp, err := server.CreateAccount(ctx, req)
		if err != nil {
			t.Fatalf("CreateAccount with mappings failed: %v", err)
		}

		if resp.AccountPublicKey == "" {
			t.Error("Expected non-empty account public key")
		}
	})

	t.Run("rejects out of scope exports", func(t *testing.T) {
		req := &proto.CreateAccountRequest{
			AccountName: "tenant-a",
			Exports: []*proto.StreamExport{
				{Subject: "tenant-b.logs.>", Name: "foreign"},
			},
		}

		_, err := server.CreateAccount(ctx, req)
		if err == nil {
			t.Fatal("Expected error for out-of-scope export")
		}

		st, ok := status.FromError(err)
		if !ok {
			t.Fatalf("Expected gRPC status error, got: %v", err)
		}
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty account name", func(t *testing.T) {
		req := &proto.CreateAccountRequest{
			AccountName: "",
		}

		_, err := server.CreateAccount(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty account name")
		}

		st, ok := status.FromError(err)
		if !ok {
			t.Fatalf("Expected gRPC status error, got: %v", err)
		}
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})
}

func mintablePermissions() *proto.UserPermissions {
	return &proto.UserPermissions{PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{"_INBOX.>"}}
}

func TestNATSAccountServer_GenerateUserCredentials(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	// First create an account to get a valid seed
	createResp, err := server.CreateAccount(ctx, &proto.CreateAccountRequest{
		AccountName: "test-ns",
	})
	if err != nil {
		t.Fatalf("Failed to create test account: %v", err)
	}
	server.SetPlatformAccount("test-ns", createResp.AccountSeed)

	t.Run("success with collector type", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			AccountName:    "test-ns",
			UserName:       "collector-1",
			CredentialType: proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR,
			Permissions:    mintablePermissions(),
		}

		resp, err := server.GenerateUserCredentials(ctx, req)
		if err != nil {
			t.Fatalf("GenerateUserCredentials failed: %v", err)
		}

		if resp.UserPublicKey == "" {
			t.Error("Expected non-empty user public key")
		}
		if !strings.HasPrefix(resp.UserPublicKey, "U") {
			t.Errorf("User public key should start with 'U', got: %s", resp.UserPublicKey)
		}

		if resp.UserJwt == "" {
			t.Error("Expected non-empty user JWT")
		}

		if resp.CredsFileContent == "" {
			t.Error("Expected non-empty creds file content")
		}
		if !strings.Contains(resp.CredsFileContent, "BEGIN NATS USER JWT") {
			t.Error("Creds file should contain JWT header")
		}
	})

	t.Run("with expiration", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			AccountName:       "test-ns",
			UserName:          "expiring-user",
			CredentialType:    proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE,
			ExpirationSeconds: 3600, // 1 hour
			Permissions:       mintablePermissions(),
		}

		resp, err := server.GenerateUserCredentials(ctx, req)
		if err != nil {
			t.Fatalf("GenerateUserCredentials with expiration failed: %v", err)
		}

		if resp.ExpiresAtUnix == 0 {
			t.Error("Expected non-zero expiration timestamp")
		}
	})

	t.Run("rejects out of scope custom permissions", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			AccountName: "test-ns",
			UserName:    "bad-user",
			Permissions: &proto.UserPermissions{
				PublishAllow: []string{"$SYS.REQ.CLAIMS.UPDATE"},
			},
		}

		_, err := server.GenerateUserCredentials(ctx, req)
		if err == nil {
			t.Fatal("Expected error for out-of-scope permissions")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty account name", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			AccountName: "",
			UserName:    "test-user",
		}

		_, err := server.GenerateUserCredentials(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty account name")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("signs with the platform account seed", func(t *testing.T) {
		resp, err := server.GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
			AccountName: "test-ns",
			UserName:    "trapd-edge",
			Permissions: mintablePermissions(),
		})
		if err != nil {
			t.Fatalf("GenerateUserCredentials failed: %v", err)
		}

		claims, err := jwt.DecodeUserClaims(resp.UserJwt)
		if err != nil {
			t.Fatalf("decode user JWT: %v", err)
		}
		if claims.IssuerAccount != createResp.AccountPublicKey {
			t.Errorf("issuer account = %s, want %s", claims.IssuerAccount, createResp.AccountPublicKey)
		}
	})

	t.Run("refuses an account other than the platform account", func(t *testing.T) {
		_, err := server.GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
			AccountName: "other-account",
			UserName:    "test-user",
		})
		if got := status.Code(err); got != codes.InvalidArgument {
			t.Errorf("code = %v, want InvalidArgument (err %v)", got, err)
		}
	})

	t.Run("refuses when no seed is configured", func(t *testing.T) {
		_, err := newTestNATSAccountServer(t).GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
			AccountName: "test-ns",
			UserName:    "test-user",
		})
		if got := status.Code(err); got != codes.FailedPrecondition {
			t.Errorf("code = %v, want FailedPrecondition (err %v)", got, err)
		}
	})

	t.Run("empty user name", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			AccountName: "test-ns",
			UserName:    "",
		}

		_, err := server.GenerateUserCredentials(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty user name")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})
}

func TestNATSAccountServer_SignAccountJWT(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	// First create an account to get a valid seed
	createResp, err := server.CreateAccount(ctx, &proto.CreateAccountRequest{
		AccountName: "resign-account",
	})
	if err != nil {
		t.Fatalf("Failed to create test account: %v", err)
	}

	t.Run("success", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			AccountName: "resign-account",
			AccountSeed: createResp.AccountSeed,
		}

		resp, err := server.SignAccountJWT(ctx, req)
		if err != nil {
			t.Fatalf("SignAccountJWT failed: %v", err)
		}

		if resp.AccountPublicKey != createResp.AccountPublicKey {
			t.Errorf("Public key mismatch: got %s, want %s",
				resp.AccountPublicKey, createResp.AccountPublicKey)
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("with revocations", func(t *testing.T) {
		// First generate a user to revoke
		server.SetPlatformAccount("resign-account", createResp.AccountSeed)
		userResp, err := server.GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
			AccountName: "resign-account",
			UserName:    "revoke-me",
			Permissions: mintablePermissions(),
		})
		if err != nil {
			t.Fatalf("Failed to create user: %v", err)
		}

		req := &proto.SignAccountJWTRequest{
			AccountName:     "resign-account",
			AccountSeed:     createResp.AccountSeed,
			RevokedUserKeys: []string{userResp.UserPublicKey},
		}

		resp, err := server.SignAccountJWT(ctx, req)
		if err != nil {
			t.Fatalf("SignAccountJWT with revocations failed: %v", err)
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("with updated limits", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			AccountName: "resign-account",
			AccountSeed: createResp.AccountSeed,
			Limits: &proto.AccountLimits{
				MaxConnections: 200,
			},
		}

		resp, err := server.SignAccountJWT(ctx, req)
		if err != nil {
			t.Fatalf("SignAccountJWT with limits failed: %v", err)
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("rejects imports", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			AccountName: "resign-account",
			AccountSeed: createResp.AccountSeed,
			Imports: []*proto.StreamImport{
				{
					Subject:          "platform.provisioning.>",
					AccountPublicKey: "ACYXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
				},
			},
		}

		_, err := server.SignAccountJWT(ctx, req)
		if err == nil {
			t.Fatal("Expected error for imports")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty account name", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			AccountName: "",
			AccountSeed: createResp.AccountSeed,
		}

		_, err := server.SignAccountJWT(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty account name")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty account seed", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			AccountName: "resign-account",
			AccountSeed: "",
		}

		_, err := server.SignAccountJWT(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty account seed")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})
}

func TestProtoConversions(t *testing.T) {
	t.Run("protoToAccountLimits nil", func(t *testing.T) {
		result := protoToAccountLimits(nil)
		if result != nil {
			t.Error("Expected nil for nil input")
		}
	})

	t.Run("protoToAccountLimits with values", func(t *testing.T) {
		proto := &proto.AccountLimits{
			MaxConnections:       100,
			MaxSubscriptions:     1000,
			MaxPayloadBytes:      1048576,
			MaxDataBytes:         10485760,
			MaxExports:           10,
			MaxImports:           20,
			AllowWildcardExports: true,
		}

		result := protoToAccountLimits(proto)

		if result.MaxConnections != 100 {
			t.Errorf("MaxConnections: got %d, want 100", result.MaxConnections)
		}
		if result.MaxSubscriptions != 1000 {
			t.Errorf("MaxSubscriptions: got %d, want 1000", result.MaxSubscriptions)
		}
		if !result.AllowWildcardExports {
			t.Error("AllowWildcardExports should be true")
		}
	})

	t.Run("protoToCredentialType", func(t *testing.T) {
		tests := []struct {
			input proto.UserCredentialType
			want  accounts.UserCredentialType
		}{
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR, accounts.CredentialTypeCollector},
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE, accounts.CredentialTypeService},
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_ADMIN, accounts.CredentialTypeAdmin},
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_UNSPECIFIED, accounts.CredentialTypeCollector},
		}

		for _, tt := range tests {
			got := protoToCredentialType(tt.input)
			if got != tt.want {
				t.Errorf("protoToCredentialType(%v) = %v, want %v", tt.input, got, tt.want)
			}
		}
	})

	t.Run("protoToUserPermissions nil", func(t *testing.T) {
		result := protoToUserPermissions(nil)
		if result != nil {
			t.Error("Expected nil for nil input")
		}
	})

	t.Run("protoToUserPermissions with values", func(t *testing.T) {
		proto := &proto.UserPermissions{
			PublishAllow:   []string{"events.>"},
			PublishDeny:    []string{"admin.>"},
			SubscribeAllow: []string{"events.>"},
			SubscribeDeny:  []string{},
			AllowResponses: true,
			MaxResponses:   10,
		}

		result := protoToUserPermissions(proto)

		if len(result.PublishAllow) != 1 || result.PublishAllow[0] != "events.>" {
			t.Errorf("PublishAllow: got %v, want [events.>]", result.PublishAllow)
		}
		if !result.AllowResponses {
			t.Error("AllowResponses should be true")
		}
		if result.MaxResponses != 10 {
			t.Errorf("MaxResponses: got %d, want 10", result.MaxResponses)
		}
	})
}

// A compromised core reaches accounts only through this RPC, so it must not be
// able to mint a credential that reaches everything. The "real" cases are copies
// of what core sends (Elixir, so they cannot be shared): collector_permissions/1,
// AgentFlowCollectorPermissions and NatsLeafCredentials.
func TestGenerateUserCredentialsPermissionLimits(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	createResp, err := server.CreateAccount(ctx, &proto.CreateAccountRequest{AccountName: "test-ns"})
	if err != nil {
		t.Fatalf("Failed to create test account: %v", err)
	}
	server.SetPlatformAccount("test-ns", createResp.AccountSeed)

	const (
		collector = proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR
		service   = proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE
	)
	inbox := []string{"_INBOX.>"}
	publisher := func(subjects ...string) *proto.UserPermissions {
		return &proto.UserPermissions{PublishAllow: subjects, SubscribeAllow: inbox}
	}

	refused := []struct {
		name  string
		perms *proto.UserPermissions
	}{
		{"publish everything", publisher(">")},
		{"publish one token", publisher("*")},
		{"publish any first token", publisher("*.foo")},
		{"subscribe everything", &proto.UserPermissions{PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{">"}}},
		{"subscribe any first token", &proto.UserPermissions{PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{"*.>"}}},
		{"publish the whole JetStream API", publisher("$JS.API.>")},
		{"publish all stream admin", publisher("$JS.API.STREAM.>")},
		{"publish any stream delete", publisher("$JS.API.STREAM.DELETE.*")},
		{"subscribe the whole JetStream API", &proto.UserPermissions{PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{"$JS.API.>"}}},
		{"no publish list falls back to type defaults", &proto.UserPermissions{SubscribeAllow: inbox}},
		{"no subscribe list falls back to type defaults", &proto.UserPermissions{PublishAllow: []string{"logs.syslog"}}},
		{"no permissions fall back to type defaults", nil},
		{"delete a named stream", publisher("$JS.API.STREAM.DELETE.events")},
		{"purge a named stream", publisher("$JS.API.STREAM.PURGE.events")},
		{"delete a message from a named stream", publisher("$JS.API.STREAM.MSG.DELETE.events")},
		{"delete a stream through a domain prefix", publisher("$JS.hub.API.STREAM.DELETE.events")},
		{"publish a system request", publisher("$SYS.REQ.CLAIMS.UPDATE")},
		{"publish all system subjects", publisher("$SYS.>")},
		{"subscribe a system subject", &proto.UserPermissions{PublishAllow: []string{"logs.syslog"}, SubscribeAllow: []string{"$SYS.ACCOUNT.CONNECT"}}},
	}
	for _, credType := range []proto.UserCredentialType{collector, service} {
		for _, tc := range refused {
			t.Run(credType.String()+"/refuses "+tc.name, func(t *testing.T) {
				_, err := server.GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
					AccountName: "test-ns", UserName: "u", CredentialType: credType, Permissions: tc.perms,
				})
				if got := status.Code(err); got != codes.InvalidArgument {
					t.Errorf("code = %v, want InvalidArgument (err %v)", got, err)
				}
			})
		}
	}

	allowed := []struct {
		name     string
		credType proto.UserCredentialType
		perms    *proto.UserPermissions
	}{
		{"flowgger", collector, publisher("logs.syslog")},
		{"trapd", collector, publisher("logs.snmp")},
		{"otel", collector, publisher("otel.traces.>", "otel.metrics.>", "logs.otel")},
		{"netflow", collector, publisher("flows.raw.netflow")},
		{"sflow", collector, publisher("flows.raw.sflow")},
		{"falcosidekick", collector, publisher("falco.logs")},
		{"agent flow collector", service, &proto.UserPermissions{
			PublishAllow: []string{
				"flow.host-slice.agent-42",
				"$JS.API.STREAM.INFO.flows",
				"$JS.API.STREAM.CREATE.flows",
				"$JS.API.STREAM.UPDATE.flows",
				"$JS.API.STREAM.INFO.events",
				"$JS.API.STREAM.UPDATE.events",
			},
			PublishDeny:    []string{"$SYS.>", "flow.attributed.>"},
			SubscribeAllow: []string{"_INBOX.>", "config.flow-collector.agent-42.>"},
			SubscribeDeny:  []string{"$SYS.>", "flow.host-slice.>", "flow.attributed.>"},
			AllowResponses: true,
			MaxResponses:   16,
		}},
		{"leaf", service, &proto.UserPermissions{
			PublishAllow:   []string{"logs.>", "otel.>", "events.>", "netflow.>", "flows.raw.>", "falco.>", "$JS.ACK.>", "_INBOX.>"},
			SubscribeAllow: []string{"$JS.ACK.>", "_INBOX.>"},
		}},
		{"deny everything stays expressible", collector, &proto.UserPermissions{
			PublishAllow: []string{"logs.syslog"}, SubscribeAllow: inbox, PublishDeny: []string{">"}, SubscribeDeny: []string{">"},
		}},
	}
	for _, tc := range allowed {
		t.Run("allows "+tc.name, func(t *testing.T) {
			if _, err := server.GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
				AccountName: "test-ns", UserName: "u", CredentialType: tc.credType, Permissions: tc.perms,
			}); err != nil {
				t.Errorf("GenerateUserCredentials: %v", err)
			}
		})
	}
}
