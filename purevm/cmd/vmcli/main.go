package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"purevm/core"
	"purevm/proof"
	"time"
)

func main() {
	var (
		cmd       = flag.String("cmd", "run", "Command: run|snapshot|prove|verify|verify-index")
		codeHex   = flag.String("code", "", "Bytecode hex (e.g. 6005600301)")
		gas       = flag.Uint64("gas", 100000, "Gas limit")
		steps     = flag.Uint64("steps", 0, "Steps to execute (0=all)")
		snapFile  = flag.String("snap", "", "Snapshot file path")
		proofFile = flag.String("proof", "", "Proof file path")
		indexFile = flag.String("index", "", "Snapshot index file path")
		ordinal   = flag.Int("ordinal", 0, "Snapshot ordinal in index")
		full      = flag.Bool("full", false, "Verify the full adjacent interval when using verify-index")
		chainID   = flag.Uint64("chainid", 1337, "Chain ID for snapshot")
	)
	flag.Parse()

	switch *cmd {
	case "run":
		runVM(*codeHex, *gas, *steps)
	case "snapshot":
		createSnapshot(*codeHex, *gas, *steps, *snapFile, *chainID)
	case "prove":
		generateProof(*codeHex, *gas, *steps, *proofFile)
	case "verify":
		verifyProof(*snapFile, *proofFile)
	case "verify-index":
		verifyIndex(*indexFile, *ordinal, *steps, *full)
	default:
		fmt.Printf("Unknown command: %s\n", *cmd)
		os.Exit(1)
	}
}

func runVM(codeHex string, gasLimit, steps uint64) {
	code := parseHex(codeHex)
	vm := core.NewVM(code, gasLimit)

	start := time.Now()
	var err error
	if steps == 0 {
		err = vm.Run()
	} else {
		err = vm.RunSteps(steps)
	}
	elapsed := time.Since(start)

	if err != nil {
		fmt.Printf("Execution error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Execution completed in %v\n", elapsed)
	fmt.Printf("Steps: %d\n", vm.State.StepCount)
	fmt.Printf("Gas remaining: %d\n", vm.State.Gas)
	fmt.Printf("Stack depth: %d\n", vm.State.GetStackDepth())
	if vm.State.GetStackDepth() > 0 {
		fmt.Printf("Stack top: %s\n", vm.State.Stack[vm.State.GetStackDepth()-1].Hex())
	}
	fmt.Printf("State hash: %s\n", vm.State.Hash().Hex())
}

func createSnapshot(codeHex string, gasLimit, steps uint64, filename string, chainID uint64) {
	code := parseHex(codeHex)
	vm := core.NewVM(code, gasLimit)

	if steps > 0 {
		if err := vm.RunSteps(steps); err != nil {
			fmt.Printf("Execution error: %v\n", err)
			os.Exit(1)
		}
	} else {
		if err := vm.Run(); err != nil {
			fmt.Printf("Execution error: %v\n", err)
			os.Exit(1)
		}
	}

	snap := core.NewStandardSnapshot(vm.State, chainID)

	if filename == "" {
		filename = fmt.Sprintf("snapshot_step%d.json", snap.Header.StepNumber)
	}

	if err := snap.WriteFile(filename); err != nil {
		fmt.Printf("Failed to write snapshot: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Snapshot saved to %s\n", filename)
	fmt.Printf("State root: %s\n", snap.Header.StateRoot.Hex())
	fmt.Printf("Step: %d\n", snap.Header.StepNumber)
}

func generateProof(codeHex string, gasLimit, steps uint64, filename string) {
	code := parseHex(codeHex)
	vm := core.NewVM(code, gasLimit)

	p, err := proof.GenerateTransitionProof(vm, steps)
	if err != nil {
		fmt.Printf("Proof generation error: %v\n", err)
		os.Exit(1)
	}

	if filename == "" {
		if steps == 0 {
			filename = fmt.Sprintf("proof_%d_steps.json", len(p.Steps))
		} else {
			filename = fmt.Sprintf("proof_%d_steps.json", steps)
		}
	}

	if err := p.WriteFile(filename); err != nil {
		fmt.Printf("Failed to write proof: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Proof saved to %s\n", filename)
	fmt.Printf("Initial: %s\n", p.InitialHash.Hex())
	fmt.Printf("Final:   %s\n", p.FinalHash.Hex())
	fmt.Printf("Gas used: %d\n", p.GasUsed)
	fmt.Printf("Trace root: %s\n", p.TraceRoot.Hex())
}

func verifyProof(snapFile, proofFile string) {
	// 加载快照
	snap, err := core.ReadSnapshotFile(snapFile)
	if err != nil {
		fmt.Printf("Failed to load snapshot: %v\n", err)
		os.Exit(1)
	}

	// 加载证明
	p, err := proof.ReadTransitionProofFile(proofFile)
	if err != nil {
		fmt.Printf("Failed to load proof: %v\n", err)
		os.Exit(1)
	}

	// 验证
	start := time.Now()
	if err := p.Verify(&snap.State); err != nil {
		fmt.Printf("Verification FAILED: %v\n", err)
		os.Exit(1)
	}
	elapsed := time.Since(start)

	fmt.Printf("Verification PASSED in %v\n", elapsed)
	fmt.Printf("Replayed %d steps successfully\n", len(p.Steps))
}

func verifyIndex(indexFile string, ordinal int, proofSteps uint64, full bool) {
	idx, err := core.ReadSnapshotIndexFile(indexFile)
	if err != nil {
		fmt.Printf("Failed to load snapshot index: %v\n", err)
		os.Exit(1)
	}

	startEntry, endEntry, err := idx.AdjacentEntries(ordinal)
	if err != nil {
		fmt.Printf("Failed to resolve adjacent snapshots: %v\n", err)
		os.Exit(1)
	}
	if err := idx.ValidateAdjacentThreshold(startEntry, endEntry); err != nil {
		fmt.Printf("Snapshot threshold validation FAILED: %v\n", err)
		os.Exit(1)
	}

	startSnap, err := core.ReadSnapshotFile(idx.ResolvePath(indexFile, startEntry.SnapshotFile))
	if err != nil {
		fmt.Printf("Failed to load start snapshot: %v\n", err)
		os.Exit(1)
	}
	endSnap, err := core.ReadSnapshotFile(idx.ResolvePath(indexFile, endEntry.SnapshotFile))
	if err != nil {
		fmt.Printf("Failed to load end snapshot: %v\n", err)
		os.Exit(1)
	}

	if !full && proofSteps == 0 && startEntry.AdjacentProofSteps > 0 {
		proofSteps = startEntry.AdjacentProofSteps
	}
	if full {
		proofSteps = 0
	}

	start := time.Now()
	result, err := proof.VerifyNextSnapshotHash(startSnap, endSnap, idx.SnapshotThresholdGas)
	if err != nil {
		fmt.Printf("Index verification FAILED: %v\n", err)
		os.Exit(1)
	}
	elapsed := time.Since(start)

	vm := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
	vm.State = startSnap.State.Clone()
	p, err := proof.GenerateTransitionProof(vm, result.Steps)
	if err != nil {
		fmt.Printf("Index proof synthesis FAILED: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Index verification PASSED in %v\n", elapsed)
	fmt.Printf("Start ordinal: %d\n", startEntry.Ordinal)
	fmt.Printf("End ordinal:   %d\n", endEntry.Ordinal)
	fmt.Printf("Start step:    %d\n", startEntry.StepNumber)
	fmt.Printf("End step:      %d\n", endEntry.StepNumber)
	fmt.Printf("Verified steps:%d\n", len(p.Steps))
	fmt.Printf("Initial root:  %s\n", p.InitialHash.Hex())
	fmt.Printf("Final root:    %s\n", p.FinalHash.Hex())
	fmt.Printf("Committed next root: %s\n", endSnap.Header.StateRoot.Hex())
	fmt.Printf("Mode:          next snapshot hash verification\n")
}

func parseHex(s string) []byte {
	s = strip0x(s)
	b, err := hex.DecodeString(s)
	if err != nil {
		fmt.Printf("Invalid hex: %v\n", err)
		os.Exit(1)
	}
	return b
}

func strip0x(s string) string {
	if len(s) > 1 && (s[:2] == "0x" || s[:2] == "0X") {
		return s[2:]
	}
	return s
}
