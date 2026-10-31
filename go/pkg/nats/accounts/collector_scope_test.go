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

package accounts

import (
	"errors"
	"testing"
)

func TestCollectorCredentialsAcceptOnlyStreamInfo(t *testing.T) {
	for _, tc := range []struct {
		subject string
		ok      bool
	}{
		{"$JS.API.STREAM.INFO.events", true},
		{"$JS.API.STREAM.INFO.flows", true},
		{"$JS.API.STREAM.CREATE.events", false},
		{"$JS.API.STREAM.UPDATE.events", false},
		{"logs.snmp", true},
		{"$JS.API.>", false},
		{"$JS.API.STREAM.DELETE.events", false},
		{"$JS.API.STREAM.PURGE.events", false},
		{"$JS.API.STREAM.INFO.*", false},
		{"$JS.API.STREAM.INFO.>", false},
		{"$JS.API.STREAM.INFO.events.extra", false},
		{"$JS.API.STREAM.INFO.", false},
		{"$JS.API.CONSUMER.CREATE.events", false},
		{"$KV.serviceradar-datasvc.>", false},
	} {
		err := validateUserPermissions("platform", CredentialTypeCollector, &UserPermissions{
			PublishAllow: []string{tc.subject},
			PublishDeny:  []string{"$SYS.>"},
		})
		if got := err == nil; got != tc.ok {
			t.Errorf("collector publish %q: accepted=%v, want %v (err %v)", tc.subject, got, tc.ok, err)
		}
		if err != nil && !errors.Is(err, ErrSubjectOutOfScope) {
			t.Errorf("collector publish %q: err %v, want ErrSubjectOutOfScope", tc.subject, err)
		}
	}
}
