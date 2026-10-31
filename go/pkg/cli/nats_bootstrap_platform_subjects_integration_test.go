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
	"context"
	"errors"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

const (
	agentConfigSubject = "config.agents.default"
	datasvcBucket      = "serviceradar-datasvc"
	datasvcKey         = "$KV." + datasvcBucket + ".agents/default-agent/config.json"
)

// Account subject mappings rewrite a subject before the publish ACL check, so
// only a server running the bootstrap's real account JWT exposes a mismatch.
// The three passes share one store, so each identity acts on the streams the
// one before it created.
func TestBootstrapCredsReachTheirOwnSubjects(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	credsDir := bootstrapLocalCreds(t)
	storeDir := t.TempDir()

	coreSubjects := []string{
		"logs.internal.audit",
		"events.internal.jobs",
		"metrics.ingestion_lanes",
		"mtr.results.ingest",
		"scans.results.synthetic-run",
		"notifications.deliveries",
		"signals.analytics.synthetic",
		"vulnerability.assessment.transitions.synthetic",
		"exposure.dimensions.cve",
	}

	withJetStreamAs(t, credsDir, storeDir, "platform.creds", func(js nats.JetStreamContext) {
		if _, err := js.AddStream(&nats.StreamConfig{
			Name:     "events",
			Subjects: []string{"logs.>", "events.>", "metrics.>", "mtr.>", "scans.>", "notifications.>", "signals.>", "vulnerability.>", "exposure.>"},
			MaxBytes: 1 << 20,
		}); err != nil {
			t.Fatalf("add stream: %v", err)
		}

		for _, subject := range coreSubjects {
			if _, err := js.Publish(subject, []byte(`{}`), nats.AckWait(2*time.Second)); err != nil {
				t.Errorf("platform publish %s: %v", subject, err)
			}
		}
	})

	withJetStreamAs(t, credsDir, storeDir, "datasvc.creds", func(js nats.JetStreamContext) {
		kv, err := js.CreateKeyValue(&nats.KeyValueConfig{Bucket: datasvcBucket, MaxBytes: 1 << 20})
		if err != nil {
			t.Fatalf("datasvc create bucket: %v", err)
		}
		if _, err := kv.Put("agents/default-agent/config.json", []byte(`{}`)); err != nil {
			t.Errorf("datasvc kv put: %v", err)
		}
		if entry, err := kv.Get("agents/default-agent/config.json"); err != nil || string(entry.Value()) != `{}` {
			t.Errorf("datasvc kv get: %v", err)
		}

		obj, err := js.CreateObjectStore(&nats.ObjectStoreConfig{Bucket: "serviceradar-objects", MaxBytes: 1 << 20})
		if err != nil {
			t.Fatalf("datasvc create object store: %v", err)
		}
		if _, err := obj.PutBytes("plugins/synthetic.wasm", []byte("synthetic")); err != nil {
			t.Errorf("datasvc object put: %v", err)
		}
		if data, err := obj.GetBytes("plugins/synthetic.wasm"); err != nil || string(data) != "synthetic" {
			t.Errorf("datasvc object get: %v", err)
		}

		if err := js.DeleteStream("events", shortJSContext(t)); !deniedJS(err) {
			t.Errorf("datasvc delete events: got %v, want a denied (timed out) request", err)
		}
	})

	withJetStreamAs(t, credsDir, storeDir, "platform.creds", func(js nats.JetStreamContext) {
		if _, err := js.Publish(datasvcKey, []byte(`{}`), nats.AckWait(500*time.Millisecond)); !deniedJS(err) {
			t.Errorf("platform write datasvc KV: got %v, want a denied (timed out) request", err)
		}
		if err := js.PurgeStream("KV_"+datasvcBucket, shortJSContext(t)); !deniedJS(err) {
			t.Errorf("platform purge datasvc KV: got %v, want a denied (timed out) request", err)
		}
		if err := js.DeleteStream("KV_"+datasvcBucket, shortJSContext(t)); !deniedJS(err) {
			t.Errorf("platform delete datasvc KV: got %v, want a denied (timed out) request", err)
		}
	})
}

// A denied JetStream request gets no reply, so it times out; a permitted one
// succeeds or fails fast with an API error.
func deniedJS(err error) bool {
	return errors.Is(err, context.DeadlineExceeded) || errors.Is(err, nats.ErrTimeout)
}

func shortJSContext(t *testing.T) nats.ContextOpt {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	t.Cleanup(cancel)

	return nats.Context(ctx)
}

// Each collector gets its own subjects and its one stream, and nothing that
// would let it damage another service's data.
func TestCollectorCredsAreScopedToTheirStream(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	credsDir := bootstrapLocalCreds(t)

	for _, tc := range []struct {
		creds    string
		stream   string
		owner    bool
		subjects []string
	}{
		{"log-collector.creds", "events", true, []string{"logs.syslog", "logs.otel", "otel.traces", "otel.metrics"}},
		{"trapd.creds", "events", false, []string{"logs.snmp"}},
		{"bmp-collector.creds", "ARANCINI_CAUSAL", true, []string{"arancini.updates", "arancini.updates.peer"}},
	} {
		t.Run(tc.creds, func(t *testing.T) {
			storeDir := t.TempDir()
			// The config subject is captured too, so a permitted publish would be acked.
			stream := &nats.StreamConfig{
				Name:     tc.stream,
				Subjects: append([]string{agentConfigSubject}, tc.subjects...),
				MaxBytes: 1 << 20,
			}
			if !tc.owner {
				// An appender's stream is created by its owner; storeDir keeps it.
				withJetStreamAs(t, credsDir, storeDir, "platform.creds", func(js nats.JetStreamContext) {
					owned := &nats.StreamConfig{Name: tc.stream, Subjects: []string{agentConfigSubject}, MaxBytes: 1 << 20}
					if _, err := js.AddStream(owned); err != nil {
						t.Fatalf("owner create %s: %v", tc.stream, err)
					}
				})
			}

			withJetStreamAs(t, credsDir, storeDir, tc.creds, func(js nats.JetStreamContext) {
				if tc.owner {
					if _, err := js.AddStream(stream); err != nil {
						t.Fatalf("create own stream %s: %v", tc.stream, err)
					}
				} else {
					rogue := &nats.StreamConfig{Name: tc.stream, Subjects: []string{"rogue.>"}, MaxBytes: 1 << 20}
					if _, err := js.AddStream(rogue, shortJSContext(t)); !deniedJS(err) {
						t.Errorf("%s create %s: got %v, want a denied (timed out) request", tc.creds, tc.stream, err)
					}
					if _, err := js.UpdateStream(stream); err != nil {
						t.Fatalf("add subjects to %s: %v", tc.stream, err)
					}
				}

				for _, subject := range tc.subjects {
					if _, err := js.Publish(subject, []byte(`{}`), nats.AckWait(2*time.Second)); err != nil {
						t.Errorf("publish %s: %v", subject, err)
					}
				}

				if err := js.DeleteStream(tc.stream, shortJSContext(t)); !deniedJS(err) {
					t.Errorf("%s delete %s: got %v, want a denied (timed out) request", tc.creds, tc.stream, err)
				}

				if _, err := js.Publish(agentConfigSubject, []byte(`{}`), nats.AckWait(500*time.Millisecond)); err == nil {
					t.Errorf("%s published agent config", tc.creds)
				}
			})
		})
	}
}
