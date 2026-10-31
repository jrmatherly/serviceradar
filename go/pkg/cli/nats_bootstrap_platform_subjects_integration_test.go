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
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

const (
	datasvcBucket = "serviceradar-datasvc"
	datasvcKey    = "$KV." + datasvcBucket + ".agents/default-agent/config.json"
)

// Account subject mappings rewrite a subject before the publish ACL check, so
// only a server running the bootstrap's real account JWT exposes a mismatch.
func TestBootstrapCredsReachTheirOwnSubjects(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	credsDir := bootstrapLocalCreds(t)

	withJetStreamAs(t, credsDir, t.TempDir(), "platform.creds", func(js nats.JetStreamContext) {
		if _, err := js.AddStream(&nats.StreamConfig{
			Name:     "CORE_SUBJECTS",
			Subjects: []string{"logs.internal.>", "events.internal.>", "metrics.>"},
			MaxBytes: 1 << 20,
		}); err != nil {
			t.Fatalf("add stream: %v", err)
		}

		for _, subject := range []string{
			"logs.internal.audit",
			"events.internal.jobs",
			"metrics.ingestion_lanes",
		} {
			if _, err := js.Publish(subject, []byte(`{}`), nats.AckWait(2*time.Second)); err != nil {
				t.Errorf("platform publish %s: %v", subject, err)
			}
		}

		if _, err := js.CreateKeyValue(&nats.KeyValueConfig{Bucket: datasvcBucket, MaxBytes: 1 << 20}); err != nil {
			t.Fatalf("create datasvc bucket: %v", err)
		}
		if _, err := js.Publish(datasvcKey, []byte(`{}`), nats.AckWait(500*time.Millisecond)); err == nil {
			t.Error("platform.creds wrote the datasvc KV bucket; only datasvc.creds may")
		}
	})

	withJetStreamAs(t, credsDir, t.TempDir(), "datasvc.creds", func(js nats.JetStreamContext) {
		kv, err := js.CreateKeyValue(&nats.KeyValueConfig{Bucket: datasvcBucket, MaxBytes: 1 << 20})
		if err != nil {
			t.Fatalf("datasvc create bucket: %v", err)
		}
		if _, err := kv.Put("agents/default-agent/config.json", []byte(`{}`)); err != nil {
			t.Errorf("datasvc kv put: %v", err)
		}
	})
}
