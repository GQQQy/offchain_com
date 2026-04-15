// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMVerifierAdapter} from "../src/PureVMVerifierAdapter.sol";

contract MockSnapshotValidatorPrecompile {
    error PayloadMismatch();

    fallback(bytes calldata input) external returns (bytes memory) {
        if (input.length < 8) revert PayloadMismatch();

        uint32 stateLen = uint32(bytes4(input[0:4]));
        uint32 proofLen = uint32(bytes4(input[4:8]));
        bytes memory stateBytes = input[8:8 + stateLen];
        bytes memory proofBytes = input[8 + stateLen:8 + stateLen + proofLen];
        if (stateBytes.length != stateLen || proofBytes.length != proofLen) revert PayloadMismatch();
        if (keccak256(stateBytes) != keccak256(bytes("{\"state\":\"start\"}"))) revert PayloadMismatch();
        if (keccak256(proofBytes) != keccak256(bytes("{\"proof\":\"raw-json\"}"))) revert PayloadMismatch();
        return abi.encode(uint256(1));
    }
}

// PureVMVerifierAdapterTest 只验证 adapter 是否按 Go 预编译要求的 payload 格式发包。
contract PureVMVerifierAdapterTest {
    PureVMVerifierAdapter internal adapter;
    MockSnapshotValidatorPrecompile internal target;

    // setUp 部署一个静态、无状态的 mock precompile target。
    function setUp() public {
        target = new MockSnapshotValidatorPrecompile();
        adapter = new PureVMVerifierAdapter(address(target));
    }

    // testAdapterEncodesPrecompilePayload 验证 adapter 会拼出
    // [stateLen][proofLen][state][proof] 这一真实 precompile 输入格式。
    function testAdapterEncodesPrecompilePayload() public view {
        bytes memory stateBytes = bytes("{\"state\":\"start\"}");
        bytes memory proofBytes = bytes("{\"proof\":\"raw-json\"}");
        bytes32 expectedFinalStateRoot = keccak256("final-root");
        bytes32 expectedTraceRoot = keccak256("trace-root");

        (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) =
            adapter.verifyTransition(stateBytes, proofBytes, expectedFinalStateRoot, 123, expectedTraceRoot);

        require(valid, "verification should pass");
        require(finalStateRoot == expectedFinalStateRoot, "final root mismatch");
        require(verifiedSteps == 123, "steps mismatch");
        require(traceRoot == expectedTraceRoot, "trace root mismatch");
    }
}
