package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultGobgpStatsTimeoutSeconds = 600
	defaultGobgpReadyWait           = 2 * time.Second
)

var (
	errGobgpShutdownTimeout = errors.New("timeout waiting for gobgpd shutdown")
	errBinaryPathEmpty      = errors.New("binary path is empty")
	errBinaryNotFound       = errors.New("binary not found in PATH")
)

type gobgpRunner struct {
	cfg        BGPSimulationConfig
	workDir    string
	configPath string
	apiHost    string
	apiPort    int

	mu  sync.Mutex
	cmd *exec.Cmd
}

func runBGPSimulator(cfg BGPSimulationConfig, dataDir string) {
	if !cfg.Enabled {
		return
	}

	if err := ensureGoBGPBinary(cfg.GobgpCLIBinary); err != nil {
		log.Printf("BGP simulation disabled: %v", err)
		return
	}
	if cfg.ManageDaemon {
		if err := ensureGoBGPBinary(cfg.GobgpBinary); err != nil {
			log.Printf("BGP simulation disabled: %v", err)
			return
		}
	}

	publishInterval, err := time.ParseDuration(cfg.PublishInterval)
	if err != nil {
		log.Printf("invalid BGP publish_interval %q, skipping simulator: %v", cfg.PublishInterval, err)
		return
	}
	outageInterval, err := time.ParseDuration(cfg.OutageInterval)
	if err != nil {
		log.Printf("invalid BGP outage_interval %q, skipping simulator: %v", cfg.OutageInterval, err)
		return
	}
	outageMin, err := time.ParseDuration(cfg.OutageDurationMin)
	if err != nil {
		log.Printf("invalid BGP outage_duration_min %q, skipping simulator: %v", cfg.OutageDurationMin, err)
		return
	}
	outageMax, err := time.ParseDuration(cfg.OutageDurationMax)
	if err != nil {
		log.Printf("invalid BGP outage_duration_max %q, skipping simulator: %v", cfg.OutageDurationMax, err)
		return
	}
	if outageMax < outageMin {
		outageMax = outageMin
	}
	apiHost, apiPort, err := splitHostPort(cfg.GobgpAPIAddress)
	if err != nil {
		log.Printf("invalid BGP gobgp_api_address %q, skipping simulator: %v", cfg.GobgpAPIAddress, err)
		return
	}

	rng := newDeterministicRNG(cfg.Seed)
	runner, err := newGoBGPRunner(cfg, dataDir)
	if err != nil {
		log.Printf("BGP simulation disabled: %v", err)
		return
	}
	runner.apiHost = apiHost
	runner.apiPort = apiPort

	if cfg.ManageDaemon {
		if err := runner.start(); err != nil {
			log.Printf("failed to start gobgpd for BGP simulation: %v", err)
			return
		}
		defer func() {
			if stopErr := runner.stop(); stopErr != nil {
				log.Printf("failed to stop gobgpd: %v", stopErr)
			}
		}()
	}

	announced := make(map[string]bool, len(cfg.AdvertisedPrefixes))

	publishTicker := time.NewTicker(publishInterval)
	outageTicker := time.NewTicker(outageInterval)
	defer publishTicker.Stop()
	defer outageTicker.Stop()

	log.Printf("BGP simulator active: local_asn=%d gobgp_api=%s manage_daemon=%t peers=%d prefixes=%d",
		cfg.LocalASN, cfg.GobgpAPIAddress, cfg.ManageDaemon, len(cfg.Peers), len(cfg.AdvertisedPrefixes))

	for {
		select {
		case <-publishTicker.C:
			publishCycle(rng, runner, cfg, announced)
		case <-outageTicker.C:
			d := randomDuration(rng, outageMin, outageMax)
			if cfg.ManageDaemon {
				log.Printf("BGP simulator outage window: stopping gobgpd for %s", d)
				if err := runner.stop(); err != nil {
					log.Printf("failed to stop gobgpd for outage simulation: %v", err)
					continue
				}
				time.Sleep(d)
				if err := runner.start(); err != nil {
					log.Printf("failed to restart gobgpd after outage: %v", err)
					continue
				}
				for prefix, isAnnounced := range announced {
					if !isAnnounced {
						continue
					}
					if err := runner.setPrefix(prefix, true); err != nil {
						log.Printf("failed to restore announced prefix %s after outage: %v", prefix, err)
					}
				}
			} else {
				log.Printf("BGP simulator outage window: withdrawing announced prefixes for %s", d)
				for prefix, isAnnounced := range announced {
					if !isAnnounced {
						continue
					}
					if err := runner.setPrefix(prefix, false); err != nil {
						log.Printf("failed to withdraw announced prefix %s for outage simulation: %v", prefix, err)
					}
				}
				time.Sleep(d)
				for prefix, isAnnounced := range announced {
					if !isAnnounced {
						continue
					}
					if err := runner.setPrefix(prefix, true); err != nil {
						log.Printf("failed to restore announced prefix %s after outage simulation: %v", prefix, err)
					}
				}
			}
		}
	}
}

func newGoBGPRunner(cfg BGPSimulationConfig, dataDir string) (*gobgpRunner, error) {
	storageDir := "/tmp"
	if strings.TrimSpace(dataDir) != "" {
		storageDir = dataDir
	}

	workDir := filepath.Join(storageDir, "bgp-sim")
	if err := os.MkdirAll(workDir, dataDirPerms); err != nil {
		return nil, fmt.Errorf("create BGP simulator work dir: %w", err)
	}

	r := &gobgpRunner{
		cfg:        cfg,
		workDir:    workDir,
		configPath: filepath.Join(workDir, "gobgp.toml"),
	}

	if cfg.ManageDaemon {
		if err := r.writeConfig(); err != nil {
			return nil, err
		}
	}

	return r, nil
}

func (r *gobgpRunner) writeConfig() error {
	host, port, err := splitHostPort(r.cfg.BMPCollectorAddress)
	if err != nil {
		return fmt.Errorf("invalid bmp_collector_address: %w", err)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "[global.config]\n")
	fmt.Fprintf(&b, "    as = %d\n", r.cfg.LocalASN)
	fmt.Fprintf(&b, "    router-id = \"%s\"\n\n", r.cfg.RouterID)

	fmt.Fprintf(&b, "[[bmp-servers]]\n")
	fmt.Fprintf(&b, "    [bmp-servers.config]\n")
	fmt.Fprintf(&b, "        address = \"%s\"\n", host)
	fmt.Fprintf(&b, "        port = %d\n", port)
	fmt.Fprintf(&b, "        route-monitoring-policy = \"all\"\n")
	fmt.Fprintf(&b, "        statistics-timeout = %d\n\n", defaultGobgpStatsTimeoutSeconds)

	for _, peer := range r.cfg.Peers {
		if strings.TrimSpace(peer.IP) == "" || peer.PeerASN == 0 {
			continue
		}
		fmt.Fprintf(&b, "[[neighbors]]\n")
		fmt.Fprintf(&b, "    [neighbors.config]\n")
		fmt.Fprintf(&b, "        neighbor-address = \"%s\"\n", peer.IP)
		fmt.Fprintf(&b, "        peer-as = %d\n", peer.PeerASN)
		if peer.Description != "" {
			fmt.Fprintf(&b, "        description = \"%s\"\n", peer.Description)
		}
		fmt.Fprintf(&b, "\n")
		if strings.Contains(peer.IP, ":") {
			fmt.Fprintf(&b, "    [[neighbors.afi-safis]]\n")
			fmt.Fprintf(&b, "        [neighbors.afi-safis.config]\n")
			fmt.Fprintf(&b, "        afi-safi-name = \"ipv6-unicast\"\n")
		} else {
			fmt.Fprintf(&b, "    [[neighbors.afi-safis]]\n")
			fmt.Fprintf(&b, "        [neighbors.afi-safis.config]\n")
			fmt.Fprintf(&b, "        afi-safi-name = \"ipv4-unicast\"\n")
		}
		fmt.Fprintf(&b, "\n")
	}

	if err := os.WriteFile(r.configPath, []byte(b.String()), deviceFilePermissions); err != nil {
		return fmt.Errorf("write gobgp config: %w", err)
	}
	return nil
}

func (r *gobgpRunner) start() error {
	if !r.cfg.ManageDaemon {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.cmd != nil && r.cmd.Process != nil {
		return nil
	}

	cmd := exec.CommandContext(context.Background(), r.cfg.GobgpBinary, "--config-file", r.configPath)
	cmd.Dir = r.workDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start gobgpd: %w", err)
	}

	r.cmd = cmd
	time.Sleep(defaultGobgpReadyWait)
	return nil
}

func (r *gobgpRunner) stop() error {
	if !r.cfg.ManageDaemon {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.cmd == nil || r.cmd.Process == nil {
		return nil
	}

	if err := r.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		_ = r.cmd.Process.Kill()
	}

	done := make(chan error, 1)
	go func(cmd *exec.Cmd) {
		done <- cmd.Wait()
	}(r.cmd)

	select {
	case err := <-done:
		r.cmd = nil
		if err != nil && !strings.Contains(err.Error(), "signal") {
			return err
		}
		return nil
	case <-time.After(5 * time.Second):
		_ = r.cmd.Process.Kill()
		r.cmd = nil
		return errGobgpShutdownTimeout
	}
}

func (r *gobgpRunner) setPrefix(prefix string, announced bool) error {
	afi := "ipv4"
	if strings.Contains(prefix, ":") {
		afi = "ipv6"
	}
	action := "add"
	if !announced {
		action = "del"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(
		ctx,
		r.cfg.GobgpCLIBinary,
		"-u",
		r.apiHost,
		"-p",
		fmt.Sprintf("%d", r.apiPort),
		"global",
		"rib",
		action,
		prefix,
		"-a",
		afi,
	)
	cmd.Dir = r.workDir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("gobgp %s %s (%s): %w (%s)", action, prefix, afi, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func publishCycle(rng *rand.Rand, runner *gobgpRunner, cfg BGPSimulationConfig, announced map[string]bool) {
	if len(cfg.AdvertisedPrefixes) == 0 {
		return
	}

	maxOps := cfg.MaxPrefixesPerTick
	if maxOps <= 0 {
		maxOps = 1
	}
	if maxOps > len(cfg.AdvertisedPrefixes) {
		maxOps = len(cfg.AdvertisedPrefixes)
	}

	perm := rng.Perm(len(cfg.AdvertisedPrefixes))
	ops := 1 + rng.IntN(maxOps)

	for i := 0; i < ops; i++ {
		prefix := cfg.AdvertisedPrefixes[perm[i]]
		next := !announced[prefix]
		if err := runner.setPrefix(prefix, next); err != nil {
			log.Printf("BGP simulator failed prefix update prefix=%s announced=%t err=%v", prefix, next, err)
			continue
		}
		announced[prefix] = next
		if next {
			log.Printf("BGP simulator announced prefix=%s", prefix)
		} else {
			log.Printf("BGP simulator withdrew prefix=%s", prefix)
		}
	}
}

func randomDuration(rng *rand.Rand, minD, maxD time.Duration) time.Duration {
	if maxD <= minD {
		return minD
	}
	delta := maxD - minD
	return minD + time.Duration(rng.Int64N(int64(delta)+1))
}

func splitHostPort(addr string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, err
	}
	port, err := (&net.Resolver{}).LookupPort(context.Background(), "tcp", portStr)
	if err != nil {
		return "", 0, err
	}
	return host, port, nil
}

func ensureGoBGPBinary(binary string) error {
	if strings.TrimSpace(binary) == "" {
		return errBinaryPathEmpty
	}
	_, err := exec.LookPath(binary)
	if err != nil {
		return fmt.Errorf("%w: %s", errBinaryNotFound, binary)
	}
	return nil
}

func defaultBGPPeers() []BGPSimulationPeer {
	return []BGPSimulationPeer{
		{Name: "ops-k8s-control", IP: "192.0.2.42", PeerASN: 65010, Description: "ops-k8s-control"},
		{Name: "dev-k8s-control", IP: "192.0.2.43", PeerASN: 65010, Description: "dev-k8s-control"},
		{Name: "lab-k8s-control", IP: "192.0.2.44", PeerASN: 65010, Description: "lab-k8s-control"},
		{Name: "ops-k8s-worker1", IP: "192.0.2.45", PeerASN: 65010, Description: "ops-k8s-worker1"},
		{Name: "ops-k8s-worker2", IP: "192.0.2.46", PeerASN: 65010, Description: "ops-k8s-worker2"},
		{Name: "ops-k8s-worker3", IP: "192.0.2.47", PeerASN: 65010, Description: "ops-k8s-worker3"},
		{Name: "dev-k8s-worker1", IP: "192.0.2.48", PeerASN: 65010, Description: "dev-k8s-worker1"},
		{Name: "dev-k8s-worker2", IP: "192.0.2.49", PeerASN: 65010, Description: "dev-k8s-worker2"},
		{Name: "dev-k8s-worker3", IP: "192.0.2.50", PeerASN: 65010, Description: "dev-k8s-worker3"},
		{Name: "lab-k8s-worker1", IP: "192.0.2.51", PeerASN: 65010, Description: "lab-k8s-worker1"},
		{Name: "lab-k8s-worker2", IP: "192.0.2.52", PeerASN: 65010, Description: "lab-k8s-worker2"},
		{Name: "lab-k8s-worker3", IP: "192.0.2.53", PeerASN: 65010, Description: "lab-k8s-worker3"},
		{Name: "isp-ipv4", IP: "192.0.2.9", PeerASN: 64500, Description: "ISP-IPv4"},
		{Name: "ops-k8s-control-ipv6", IP: "2001:db8:0:ff::2", PeerASN: 65010, Description: "ops-k8s-control-ipv6"},
		{Name: "dev-k8s-control-ipv6", IP: "2001:db8:0:ff::3", PeerASN: 65010, Description: "dev-k8s-control-ipv6"},
		{Name: "lab-k8s-control-ipv6", IP: "2001:db8:0:ff::4", PeerASN: 65010, Description: "lab-k8s-control-ipv6"},
		{Name: "ops-k8s-worker1-ipv6", IP: "2001:db8:0:ff::5", PeerASN: 65010, Description: "ops-k8s-worker1-ipv6"},
		{Name: "ops-k8s-worker2-ipv6", IP: "2001:db8:0:ff::6", PeerASN: 65010, Description: "ops-k8s-worker2-ipv6"},
		{Name: "ops-k8s-worker3-ipv6", IP: "2001:db8:0:ff::7", PeerASN: 65010, Description: "ops-k8s-worker3-ipv6"},
		{Name: "dev-k8s-worker1-ipv6", IP: "2001:db8:0:ff::8", PeerASN: 65010, Description: "dev-k8s-worker1-ipv6"},
		{Name: "dev-k8s-worker2-ipv6", IP: "2001:db8:0:ff::9", PeerASN: 65010, Description: "dev-k8s-worker2-ipv6"},
		{Name: "dev-k8s-worker3-ipv6", IP: "2001:db8:0:ff::10", PeerASN: 65010, Description: "dev-k8s-worker3-ipv6"},
		{Name: "lab-k8s-worker1-ipv6", IP: "2001:db8:0:ff::11", PeerASN: 65010, Description: "lab-k8s-worker1-ipv6"},
		{Name: "lab-k8s-worker2-ipv6", IP: "2001:db8:0:ff::12", PeerASN: 65010, Description: "lab-k8s-worker2-ipv6"},
		{Name: "lab-k8s-worker3-ipv6", IP: "2001:db8:0:ff::13", PeerASN: 65010, Description: "lab-k8s-worker3-ipv6"},
		{Name: "isp-ipv6", IP: "2001:db8:ff:9::", PeerASN: 64500, Description: "ISP-IPv6"},
	}
}
