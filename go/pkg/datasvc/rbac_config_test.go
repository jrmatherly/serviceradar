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

package datasvc

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

func TestComposeAgentIdentityIsReadOnly(t *testing.T) {
	for _, runfile := range []string{
		"_main/docker/compose/datasvc.docker.json",
		"_main/docker/compose/datasvc.mtls.json",
	} {
		t.Run(runfile, func(t *testing.T) {
			path, err := runfiles.Rlocation(runfile)
			require.NoError(t, err)

			contents, err := os.ReadFile(path)
			require.NoError(t, err)

			var config Config
			require.NoError(t, json.Unmarshal(contents, &config))

			var agentRole Role
			for _, rule := range config.RBAC.Roles {
				if rule.Identity == "CN=agent.serviceradar,O=ServiceRadar" {
					agentRole = rule.Role
					break
				}
			}

			assert.Equal(t, RoleReader, agentRole)
		})
	}
}

// composeCredsMounts sorts services by how they mount the nats-creds volume.
func composeCredsMounts(t *testing.T, compose []byte) (seedReaders, wholeVolume []string) {
	t.Helper()

	var file struct {
		Services map[string]struct {
			Volumes []yaml.Node `yaml:"volumes"`
		} `yaml:"services"`
	}
	require.NoError(t, yaml.Unmarshal(compose, &file))

	for name, service := range file.Services {
		for _, node := range service.Volumes {
			var short string
			if node.Decode(&short) == nil {
				if strings.HasPrefix(short, "${NATS_CREDS_DIR:-nats-creds}:") || strings.HasPrefix(short, "nats-creds:") {
					wholeVolume = append(wholeVolume, name)
				}
				continue
			}

			var long struct {
				Source string `yaml:"source"`
				Volume struct {
					Subpath string `yaml:"subpath"`
				} `yaml:"volume"`
			}
			require.NoError(t, node.Decode(&long))
			switch {
			case long.Source != "nats-creds":
			case long.Volume.Subpath == "":
				wholeVolume = append(wholeVolume, name)
			case long.Volume.Subpath == "platform_account.seed":
				seedReaders = append(seedReaders, name)
			}
		}
	}
	slices.Sort(seedReaders)
	slices.Sort(wholeVolume)

	return seedReaders, wholeVolume
}

// platform_account.seed signs any user in the platform account. Only datasvc is
// given it by name, and every service that mounts the whole volume can also read
// it, so adding a whole-volume mount must be a deliberate change here.
func TestComposePlatformSeedReaders(t *testing.T) {
	path, err := runfiles.Rlocation("_main/docker-compose.yml")
	require.NoError(t, err)
	compose, err := os.ReadFile(path)
	require.NoError(t, err)

	seedReaders, wholeVolume := composeCredsMounts(t, compose)

	assert.Equal(t, []string{"datasvc"}, seedReaders)
	assert.Equal(t, []string{"nats", "nats-account-limits", "nats-config-init", "nats-creds-init"}, wholeVolume)
}

func TestComposeCredsMountsSeesEveryMountForm(t *testing.T) {
	seedReaders, wholeVolume := composeCredsMounts(t, []byte(`
services:
  short-default:
    volumes:
      - ${NATS_CREDS_DIR:-nats-creds}:/etc/serviceradar/creds:ro
  short-named:
    volumes:
      - nats-creds:/creds
  long-whole:
    volumes:
      - type: volume
        source: nats-creds
        target: /creds
  seed-subpath:
    volumes:
      - type: volume
        source: nats-creds
        target: /creds/platform_account.seed
        volume:
          subpath: platform_account.seed
  own-creds-only:
    volumes:
      - type: volume
        source: nats-creds
        target: /creds/trapd.creds
        volume:
          subpath: trapd.creds
  unrelated:
    volumes:
      - cert-data:/etc/serviceradar/certs:ro
`))

	assert.Equal(t, []string{"seed-subpath"}, seedReaders)
	assert.Equal(t, []string{"long-whole", "short-default", "short-named"}, wholeVolume)
}
