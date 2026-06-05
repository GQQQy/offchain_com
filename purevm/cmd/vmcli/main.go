package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"purevm/core"
	"purevm/precompile"
	"purevm/proof"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
)

func main() {
	var (
		cmd           = flag.String("cmd", "run", "Command: run|snapshot|check-snapshot|prove|prove-snapshot|verify|verify-precompile|verify-index|locate-dispute|generate-artifacts")
		codeHex       = flag.String("code", "", "Bytecode hex (e.g. 6005600301)")
		gas           = flag.Uint64("gas", 100000, "Gas limit")
		steps         = flag.Uint64("steps", 0, "Steps to execute (0=all)")
		snapFile      = flag.String("snap", "", "Snapshot file path")
		proofFile     = flag.String("proof", "", "Proof file path")
		indexFile     = flag.String("index", "", "Snapshot index file path")
		outDir        = flag.String("out", "", "Artifact output directory for generate-artifacts")
		claimedIndex  = flag.String("claimed-index", "", "Executor-claimed snapshot index file path")
		verifiedIndex = flag.String("verified-index", "", "Validator-replayed snapshot index file path")
		ordinal       = flag.Int("ordinal", 0, "Snapshot ordinal in index")
		full          = flag.Bool("full", false, "Verify the full adjacent interval when using verify-index")
		chainID       = flag.Uint64("chainid", 1337, "Chain ID for snapshot")
		thresholdGas  = flag.Uint64("threshold", 500, "Snapshot threshold gas for generate-artifacts")
		writeProofs   = flag.Bool("proofs", true, "Write full adjacent proof files for generate-artifacts")
	)
	flag.Parse()

	switch *cmd {
	case "run":
		runVM(*codeHex, *gas, *steps)
	case "snapshot":
		createSnapshot(*codeHex, *gas, *steps, *snapFile, *chainID)
	case "check-snapshot":
		checkSnapshot(*snapFile)
	case "prove":
		generateProof(*codeHex, *gas, *steps, *proofFile)
	case "prove-snapshot":
		generateProofFromSnapshot(*snapFile, *steps, *proofFile)
	case "verify":
		verifyProof(*snapFile, *proofFile)
	case "verify-precompile":
		verifyPrecompile(*snapFile, *proofFile)
	case "verify-index":
		verifyIndex(*indexFile, *ordinal, *steps, *full)
	case "locate-dispute":
		locateDispute(*claimedIndex, *verifiedIndex)
	case "generate-artifacts":
		generateArtifacts(*outDir, *chainID, *gas, *thresholdGas, *writeProofs)
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

func checkSnapshot(filename string) {
	snap, err := core.ReadSnapshotFile(filename)
	if err != nil {
		fmt.Printf("Failed to load snapshot: %v\n", err)
		os.Exit(1)
	}
	if err := snap.VerifyIntegrity(); err != nil {
		fmt.Printf("Snapshot integrity FAILED: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Snapshot integrity PASSED\n")
	fmt.Printf("State root:    %s\n", snap.Header.StateRoot.Hex())
	fmt.Printf("Code hash:     %s\n", snap.Header.CodeHash.Hex())
	fmt.Printf("Step:          %d\n", snap.Header.StepNumber)
	fmt.Printf("Gas remaining: %d\n", snap.Header.GasRemaining)
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

func generateProofFromSnapshot(snapFile string, steps uint64, filename string) {
	snap, err := core.ReadSnapshotFile(snapFile)
	if err != nil {
		fmt.Printf("Failed to load snapshot: %v\n", err)
		os.Exit(1)
	}
	if err := snap.VerifyIntegrity(); err != nil {
		fmt.Printf("Snapshot integrity FAILED: %v\n", err)
		os.Exit(1)
	}

	vm := core.NewVM(snap.State.Code, snap.State.Gas)
	vm.State = snap.State.Clone()
	vm.ChainID = snap.Header.ChainID

	p, err := proof.GenerateTransitionProof(vm, steps)
	if err != nil {
		fmt.Printf("Proof generation error: %v\n", err)
		os.Exit(1)
	}

	if filename == "" {
		filename = fmt.Sprintf("proof_from_%d_steps_%d.json", p.StartStep, p.EndStep-p.StartStep)
	}
	if err := p.WriteFile(filename); err != nil {
		fmt.Printf("Failed to write proof: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Proof saved to %s\n", filename)
	fmt.Printf("Initial: %s\n", p.InitialHash.Hex())
	fmt.Printf("Final:   %s\n", p.FinalHash.Hex())
	fmt.Printf("Steps:   %d\n", p.EndStep-p.StartStep)
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
	if err := snap.VerifyIntegrity(); err != nil {
		fmt.Printf("Snapshot integrity FAILED: %v\n", err)
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
	fmt.Printf("Final root: %s\n", p.FinalHash.Hex())
	fmt.Printf("Trace root: %s\n", p.TraceRoot.Hex())
}

func verifyPrecompile(snapFile, proofFile string) {
	snapshotBytes, err := os.ReadFile(snapFile)
	if err != nil {
		fmt.Printf("Failed to read snapshot bytes: %v\n", err)
		os.Exit(1)
	}
	proofBytes, err := os.ReadFile(proofFile)
	if err != nil {
		fmt.Printf("Failed to read proof bytes: %v\n", err)
		os.Exit(1)
	}
	if len(snapshotBytes) > int(^uint32(0)) || len(proofBytes) > int(^uint32(0)) {
		fmt.Printf("Precompile payload too large\n")
		os.Exit(1)
	}

	input := make([]byte, 8, 8+len(snapshotBytes)+len(proofBytes))
	binary.BigEndian.PutUint32(input[:4], uint32(len(snapshotBytes)))
	binary.BigEndian.PutUint32(input[4:8], uint32(len(proofBytes)))
	input = append(input, snapshotBytes...)
	input = append(input, proofBytes...)

	validator := precompile.SnapshotValidatorPrecompile{}
	out, err := validator.Run(input)
	if err != nil {
		fmt.Printf("Precompile verification errored: %v\n", err)
		os.Exit(1)
	}
	if len(out) != 128 {
		fmt.Printf("Unexpected precompile response length: %d\n", len(out))
		os.Exit(1)
	}

	valid := out[31] == 1
	finalRoot := "0x" + hex.EncodeToString(out[32:64])
	verifiedSteps := binary.BigEndian.Uint64(out[88:96])
	traceRoot := "0x" + hex.EncodeToString(out[96:128])
	if !valid {
		fmt.Printf("Precompile verification FAILED\n")
		os.Exit(1)
	}

	fmt.Printf("Precompile verification PASSED\n")
	fmt.Printf("Final root: %s\n", finalRoot)
	fmt.Printf("Verified steps: %d\n", verifiedSteps)
	fmt.Printf("Trace root: %s\n", traceRoot)
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

func locateDispute(claimedIndexFile, verifiedIndexFile string) {
	if claimedIndexFile == "" || verifiedIndexFile == "" {
		fmt.Printf("locate-dispute requires -claimed-index and -verified-index\n")
		os.Exit(1)
	}

	claimed, err := core.ReadSnapshotIndexFile(claimedIndexFile)
	if err != nil {
		fmt.Printf("Failed to load claimed snapshot index: %v\n", err)
		os.Exit(1)
	}
	verified, err := core.ReadSnapshotIndexFile(verifiedIndexFile)
	if err != nil {
		fmt.Printf("Failed to load verified snapshot index: %v\n", err)
		os.Exit(1)
	}

	result, err := proof.FindFirstDivergentSegment(claimed, verified)
	if err != nil {
		fmt.Printf("Dispute localization FAILED: %v\n", err)
		os.Exit(1)
	}
	if !result.Found {
		fmt.Printf("No divergent checkpoint segment found\n")
		return
	}

	fmt.Printf("Divergent checkpoint segment found\n")
	fmt.Printf("From ordinal:       %d\n", result.FromOrdinal)
	fmt.Printf("To ordinal:         %d\n", result.ToOrdinal)
	fmt.Printf("Shared start root:  %s\n", result.SharedStartRoot.Hex())
	if result.ClaimedNextMissing {
		fmt.Printf("Claimed next root:  <missing>\n")
	} else {
		fmt.Printf("Claimed next root:  %s\n", result.ClaimedNextRoot.Hex())
	}
	if result.VerifiedNextMissing {
		fmt.Printf("Verified next root: <missing>\n")
	} else {
		fmt.Printf("Verified next root: %s\n", result.VerifiedNextRoot.Hex())
	}
	fmt.Printf("Reason:             %s\n", result.Reason)
}

type artifactTaskManifest struct {
	BytecodeHex               string `json:"bytecode_hex"`
	CodeHash                  string `json:"code_hash"`
	LoopIterations            uint32 `json:"loop_iterations"`
	TotalGas                  uint64 `json:"total_gas"`
	SnapshotThresholdGas      uint64 `json:"snapshot_threshold_gas"`
	ChainID                   uint64 `json:"chain_id"`
	GasFormula                string `json:"gas_formula"`
	ArtifactKind              string `json:"artifact_kind"`
	ProofsGenerated           bool   `json:"proofs_generated"`
	MaxSnapshotBytes          uint64 `json:"max_snapshot_bytes"`
	MaxProofBytes             uint64 `json:"max_proof_bytes"`
	RecommendedFromOrdinal    uint32 `json:"recommended_from_ordinal"`
	RecommendedProofFile      string `json:"recommended_proof_file,omitempty"`
	RecommendedProofBytes     uint64 `json:"recommended_proof_bytes,omitempty"`
	RecommendedSnapshotFile   string `json:"recommended_snapshot_file,omitempty"`
	RecommendedNextCheckpoint string `json:"recommended_next_checkpoint,omitempty"`
}

const (
	countdownSetupAndExitGas uint64 = 24
	countdownLoopGas         uint64 = 37
)

func generateArtifacts(outDir string, chainID, gasFloor, thresholdGas uint64, writeProofs bool) {
	if outDir == "" {
		outDir = filepath.Join("testdata", "e2e_artifacts", time.Now().Format("20060102_150405"))
	}
	if thresholdGas == 0 {
		fmt.Printf("Artifact generation requires -threshold > 0\n")
		os.Exit(1)
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fmt.Printf("Failed to create artifact directory: %v\n", err)
		os.Exit(1)
	}

	iterations := countdownIterationsForGasFloor(gasFloor)
	code := buildCountdownLoop(iterations)
	totalGas := countdownGasForIterations(iterations)
	codeHex := "0x" + hex.EncodeToString(code)

	index := core.NewSnapshotIndex(chainID, totalGas, thresholdGas)
	index.BytecodeHex = codeHex
	index.Meta = map[string]string{
		"artifact_kind": "e2e",
		"gas_formula":   "totalGas = 24 + 37 * iterations",
	}

	vm := core.NewVM(code, totalGas)
	vm.ChainID = chainID

	initialPath := filepath.Join(outDir, "snapshot_000_initial.json")
	initialSnap := core.NewStandardSnapshot(vm.State, vm.ChainID)
	initialSnap.Meta = map[string]string{
		"gas_used":      "0",
		"gas_threshold": fmt.Sprintf("%d", thresholdGas),
	}
	if err := initialSnap.WriteFile(initialPath); err != nil {
		fmt.Printf("Failed to write initial snapshot: %v\n", err)
		os.Exit(1)
	}
	index.AddSnapshot(filepath.Base(initialPath), initialSnap, 0)

	snapshotPaths := []string{initialPath}
	windowGasUsed := uint64(0)
	for !vm.Halted {
		nextGas, err := vm.PeekNextGasCost()
		if err != nil {
			fmt.Printf("Gas peek failed: %v\n", err)
			os.Exit(1)
		}

		gasUsed := totalGas - vm.State.Gas
		if windowGasUsed > 0 && windowGasUsed+nextGas > thresholdGas {
			path := filepath.Join(
				outDir,
				fmt.Sprintf("snapshot_%03d_step_%d_gas_%d.json", len(snapshotPaths), vm.State.StepCount, gasUsed),
			)
			snap := core.NewStandardSnapshot(vm.State, vm.ChainID)
			snap.Meta = map[string]string{
				"gas_used":      fmt.Sprintf("%d", gasUsed),
				"gas_threshold": fmt.Sprintf("%d", thresholdGas),
			}
			if err := snap.WriteFile(path); err != nil {
				fmt.Printf("Failed to write snapshot: %v\n", err)
				os.Exit(1)
			}
			snapshotPaths = append(snapshotPaths, path)
			index.AddSnapshot(filepath.Base(path), snap, gasUsed)
			windowGasUsed = 0
		}

		if err := vm.Step(); err != nil {
			fmt.Printf("Execution failed: %v\n", err)
			os.Exit(1)
		}
		windowGasUsed += nextGas
	}

	finalGasUsed := totalGas - vm.State.Gas
	finalPath := filepath.Join(
		outDir,
		fmt.Sprintf("snapshot_%03d_final_step_%d_gas_%d.json", len(snapshotPaths), vm.State.StepCount, finalGasUsed),
	)
	finalSnap := core.NewStandardSnapshot(vm.State, vm.ChainID)
	finalSnap.Meta = map[string]string{
		"gas_used": fmt.Sprintf("%d", finalGasUsed),
	}
	if err := finalSnap.WriteFile(finalPath); err != nil {
		fmt.Printf("Failed to write final snapshot: %v\n", err)
		os.Exit(1)
	}
	snapshotPaths = append(snapshotPaths, finalPath)
	index.AddSnapshot(filepath.Base(finalPath), finalSnap, finalGasUsed)

	var recommendedProof string
	var recommendedProofBytes uint64
	if writeProofs {
		for ordinal := 0; ordinal < len(index.Snapshots)-1; ordinal++ {
			startSnap, err := core.ReadSnapshotFile(snapshotPaths[ordinal])
			if err != nil {
				fmt.Printf("Failed to read start snapshot: %v\n", err)
				os.Exit(1)
			}
			endSnap, err := core.ReadSnapshotFile(snapshotPaths[ordinal+1])
			if err != nil {
				fmt.Printf("Failed to read end snapshot: %v\n", err)
				os.Exit(1)
			}
			deltaSteps := endSnap.Header.StepNumber - startSnap.Header.StepNumber
			segmentVM := core.NewVM(startSnap.State.Code, startSnap.State.Gas)
			segmentVM.State = startSnap.State.Clone()
			transitionProof, err := proof.GenerateTransitionProof(segmentVM, deltaSteps)
			if err != nil {
				fmt.Printf("Proof generation failed at ordinal %d: %v\n", ordinal, err)
				os.Exit(1)
			}
			proofFile := fmt.Sprintf("proof_%03d_from_%d_steps_%d.json", ordinal+1, startSnap.Header.StepNumber, deltaSteps)
			proofPath := filepath.Join(outDir, proofFile)
			proofData, err := json.MarshalIndent(transitionProof, "", "  ")
			if err != nil {
				fmt.Printf("Proof marshal failed at ordinal %d: %v\n", ordinal, err)
				os.Exit(1)
			}
			if len(proofData) > precompile.MaxProofBytes {
				fmt.Printf(
					"Proof %s is %d bytes, exceeding the %d byte verifier limit; lower -gas/-threshold or use -proofs=false\n",
					proofFile,
					len(proofData),
					precompile.MaxProofBytes,
				)
				os.Exit(1)
			}
			if err := os.WriteFile(proofPath, proofData, 0o644); err != nil {
				fmt.Printf("Failed to write proof: %v\n", err)
				os.Exit(1)
			}
			if err := index.SetAdjacentProof(ordinal, proofFile, deltaSteps, true); err != nil {
				fmt.Printf("Failed to record proof metadata: %v\n", err)
				os.Exit(1)
			}
			if ordinal == 0 {
				recommendedProof = proofFile
				recommendedProofBytes = uint64(len(proofData))
			}
		}
	}

	indexPath := filepath.Join(outDir, "snapshot_index.json")
	if err := index.WriteFile(indexPath); err != nil {
		fmt.Printf("Failed to write snapshot index: %v\n", err)
		os.Exit(1)
	}

	nextSummary := ""
	if len(index.Snapshots) > 1 {
		next := index.Snapshots[1]
		nextSummary = fmt.Sprintf(
			"ordinal=%d step=%d gasUsed=%d gasRemaining=%d stateRoot=%s",
			next.Ordinal,
			next.StepNumber,
			next.GasUsed,
			next.GasRemaining,
			next.StateRoot.Hex(),
		)
	}
	manifest := artifactTaskManifest{
		BytecodeHex:               codeHex,
		CodeHash:                  crypto.Keccak256Hash(code).Hex(),
		LoopIterations:            iterations,
		TotalGas:                  totalGas,
		SnapshotThresholdGas:      thresholdGas,
		ChainID:                   chainID,
		GasFormula:                "totalGas = 24 + 37 * iterations",
		ArtifactKind:              "e2e",
		ProofsGenerated:           writeProofs,
		MaxSnapshotBytes:          precompile.MaxSnapshotBytes,
		MaxProofBytes:             precompile.MaxProofBytes,
		RecommendedFromOrdinal:    0,
		RecommendedProofFile:      recommendedProof,
		RecommendedProofBytes:     recommendedProofBytes,
		RecommendedSnapshotFile:   filepath.Base(initialPath),
		RecommendedNextCheckpoint: nextSummary,
	}
	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		fmt.Printf("Failed to marshal manifest: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(filepath.Join(outDir, "task_manifest.json"), manifestData, 0o644); err != nil {
		fmt.Printf("Failed to write manifest: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(filepath.Join(outDir, "task_bytecode.hex"), []byte(codeHex+"\n"), 0o644); err != nil {
		fmt.Printf("Failed to write bytecode: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Artifacts written to %s\n", outDir)
	fmt.Printf("Bytecode: %s\n", codeHex)
	fmt.Printf("Code hash: %s\n", manifest.CodeHash)
	fmt.Printf("Total gas: %d\n", totalGas)
	fmt.Printf("Snapshot threshold gas: %d\n", thresholdGas)
	fmt.Printf("Snapshots: %d\n", len(index.Snapshots))
	if recommendedProof != "" {
		fmt.Printf("Recommended proof: %s (%d bytes)\n", recommendedProof, recommendedProofBytes)
	}
	fmt.Printf("Recommended from ordinal: 0\n")
	if nextSummary != "" {
		fmt.Printf("Recommended next checkpoint: %s\n", nextSummary)
	}
}

func countdownIterationsForGasFloor(gasFloor uint64) uint32 {
	if gasFloor <= countdownSetupAndExitGas {
		return 0
	}

	remaining := gasFloor - countdownSetupAndExitGas
	iterations := remaining / countdownLoopGas
	if remaining%countdownLoopGas != 0 {
		iterations++
	}
	return uint32(iterations)
}

func countdownGasForIterations(iterations uint32) uint64 {
	return countdownSetupAndExitGas + uint64(iterations)*countdownLoopGas
}

func buildCountdownLoop(iterations uint32) []byte {
	code := []byte{
		0x63, 0, 0, 0, 0,
		0x5b,
		0x80,
		0x15,
		0x60, 0x11,
		0x57,
		0x60, 0x01,
		0x03,
		0x60, 0x05,
		0x56,
		0x5b,
		0x00,
	}
	binary.BigEndian.PutUint32(code[1:5], iterations)
	return code
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
