package mtr

import (
	"errors"
	"net"
	"testing"
)

// The connect flow is the only TCP flow every platform builds, and its port
// check runs before any socket is opened, so this needs no privileges.
func TestNewConnectTCPFlowRejectsPortOutsideWireWidth(t *testing.T) {
	for _, port := range []int{-1, 65536, 70000} {
		flow, err := newConnectTCPFlow(net.IPv4(192, 0, 2, 1), port, 0, false)
		if flow != nil {
			t.Fatalf("port %d: expected no flow, got %+v", port, flow)
		}
		if !errors.Is(err, errIntegerWidth) {
			t.Fatalf("port %d: expected errIntegerWidth, got %v", port, err)
		}
	}
}

func TestNewConnectTCPFlowAcceptsWirePort(t *testing.T) {
	flow, err := newConnectTCPFlow(net.IPv4(192, 0, 2, 1), 65535, 0, false)
	if err != nil {
		t.Fatalf("expected port 65535 to be accepted, got %v", err)
	}
	if flow.dstPort != 65535 {
		t.Fatalf("expected dstPort 65535, got %d", flow.dstPort)
	}
}
