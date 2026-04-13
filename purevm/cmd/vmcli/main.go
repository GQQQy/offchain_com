package main

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"purevm/core"
	"purevm/proof"
	"time"
)

func main() {
	var (
		cmd       = flag.String("cmd", "run", "Command: run|snapshot|prove|verify")
		codeHex   = flag.String("code", "", "Bytecode hex (e.g. 6005600301)")
		gas       = flag.Uint64("gas", 100000, "Gas limit")
		steps     = flag.Uint64("steps", 0, "Steps to execute (0=all)")
		snapFile  = flag.String("snap", "", "Snapshot file path")
		proofFile = flag.String("proof", "", "Proof file path")
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
	data, _ := json.MarshalIndent(snap, "", "  ")

	if filename == "" {
		filename = fmt.Sprintf("snapshot_step%d.json", snap.Header.StepNumber)
	}

	if err := ioutil.WriteFile(filename, data, 0644); err != nil {
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

	data, _ := json.MarshalIndent(p, "", "  ")

	if filename == "" {
		filename = fmt.Sprintf("proof_%d_steps.json", steps)
	}

	if err := ioutil.WriteFile(filename, data, 0644); err != nil {
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
	snapData, err := ioutil.ReadFile(snapFile)
	if err != nil {
		fmt.Printf("Failed to read snapshot: %v\n", err)
		os.Exit(1)
	}

	snap, err := core.DeserializeSnapshot(snapData)
	if err != nil {
		fmt.Printf("Failed to parse snapshot: %v\n", err)
		os.Exit(1)
	}

	// 加载证明
	proofData, err := ioutil.ReadFile(proofFile)
	if err != nil {
		fmt.Printf("Failed to read proof: %v\n", err)
		os.Exit(1)
	}

	var p proof.TransitionProof
	if err := json.Unmarshal(proofData, &p); err != nil {
		fmt.Printf("Failed to parse proof: %v\n", err)
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
