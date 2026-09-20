package mtpx

import "testing"

func TestVisitWalkNodeGuardsCyclesAndDepth(t *testing.T) {
	visited := map[uint32]struct{}{}
	shouldVisit, err := visitWalkNode(visited, 42, 0)
	if err != nil || !shouldVisit {
		t.Fatalf("expected first object to be visited: %v", err)
	}
	shouldVisit, err = visitWalkNode(visited, 42, 1)
	if err != nil || shouldVisit {
		t.Fatalf("expected repeated object to be skipped: visit=%v err=%v", shouldVisit, err)
	}
	if _, err := visitWalkNode(visited, 43, maxWalkDepth+1); err == nil {
		t.Fatal("expected excessive depth to fail")
	}
}
