// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMVerifierAdapter} from "../src/PureVMVerifierAdapter.sol";

interface Vm {
    function expectRevert(bytes calldata) external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

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

contract MockRichSnapshotValidatorPrecompile {
    bytes32 internal immutable finalRoot;
    uint64 internal immutable verifiedSteps;
    bytes32 internal immutable traceRoot;
    bool internal immutable valid;

    constructor(bool valid_, bytes32 finalRoot_, uint64 verifiedSteps_, bytes32 traceRoot_) {
        valid = valid_;
        finalRoot = finalRoot_;
        verifiedSteps = verifiedSteps_;
        traceRoot = traceRoot_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(valid ? uint256(1) : uint256(0), finalRoot, uint256(verifiedSteps), traceRoot);
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

    // testAdapterEncodesPrecompilePayloadAndRejectsLegacyResponse 验证 adapter 会拼出
    // [stateLen][proofLen][state][proof] 这一真实 precompile 输入格式，同时拒绝旧的 bool-only 响应。
    function testAdapterEncodesPrecompilePayloadAndRejectsLegacyResponse() public {
        bytes memory stateBytes = bytes("{\"state\":\"start\"}");
        bytes memory proofBytes = bytes("{\"proof\":\"raw-json\"}");
        bytes32 expectedFinalStateRoot = keccak256("final-root");
        bytes32 expectedTraceRoot = keccak256("trace-root");

        vm.expectRevert(abi.encodeWithSelector(PureVMVerifierAdapter.InvalidVerifierResponse.selector));
        adapter.verifyTransition(stateBytes, proofBytes, expectedFinalStateRoot, 123, expectedTraceRoot);
    }

    function testAdapterUsesRichVerifierResult() public {
        bytes32 actualFinalRoot = keccak256("actual-final-root");
        bytes32 actualTraceRoot = keccak256("actual-trace-root");
        PureVMVerifierAdapter richAdapter = new PureVMVerifierAdapter(
            address(new MockRichSnapshotValidatorPrecompile(true, actualFinalRoot, 321, actualTraceRoot))
        );

        (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) =
            richAdapter.verifyTransition(bytes("state"), bytes("proof"), actualFinalRoot, 321, bytes32(0));

        require(valid, "rich verification should pass");
        require(finalStateRoot == actualFinalRoot, "actual final root mismatch");
        require(verifiedSteps == 321, "actual steps mismatch");
        require(traceRoot == actualTraceRoot, "actual trace root mismatch");
    }

    function testAdapterRejectsWrongRichFinalRoot() public {
        bytes32 actualFinalRoot = keccak256("actual-final-root");
        bytes32 expectedFinalRoot = keccak256("expected-final-root");
        PureVMVerifierAdapter richAdapter = new PureVMVerifierAdapter(
            address(new MockRichSnapshotValidatorPrecompile(true, actualFinalRoot, 321, keccak256("trace")))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PureVMVerifierAdapter.VerifierFinalRootMismatch.selector, actualFinalRoot, expectedFinalRoot
            )
        );
        richAdapter.verifyTransition(bytes("state"), bytes("proof"), expectedFinalRoot, 321, bytes32(0));
    }

    function testAdapterRejectsWrongRichSteps() public {
        bytes32 actualFinalRoot = keccak256("actual-final-root");
        PureVMVerifierAdapter richAdapter = new PureVMVerifierAdapter(
            address(new MockRichSnapshotValidatorPrecompile(true, actualFinalRoot, 321, keccak256("trace")))
        );

        vm.expectRevert(
            abi.encodeWithSelector(PureVMVerifierAdapter.VerifierStepMismatch.selector, uint64(321), uint64(123))
        );
        richAdapter.verifyTransition(bytes("state"), bytes("proof"), actualFinalRoot, 123, bytes32(0));
    }

    function testAdapterRejectsWrongRichTraceRoot() public {
        bytes32 actualFinalRoot = keccak256("actual-final-root");
        bytes32 actualTraceRoot = keccak256("actual-trace-root");
        bytes32 expectedTraceRoot = keccak256("expected-trace-root");
        PureVMVerifierAdapter richAdapter = new PureVMVerifierAdapter(
            address(new MockRichSnapshotValidatorPrecompile(true, actualFinalRoot, 321, actualTraceRoot))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PureVMVerifierAdapter.VerifierTraceRootMismatch.selector, actualTraceRoot, expectedTraceRoot
            )
        );
        richAdapter.verifyTransition(bytes("state"), bytes("proof"), actualFinalRoot, 321, expectedTraceRoot);
    }

    function testAdapterRejectsOversizedPayloads() public {
        bytes memory oversizedState = new bytes(262_145);
        vm.expectRevert(
            abi.encodeWithSelector(
                PureVMVerifierAdapter.VerifierPayloadTooLarge.selector,
                "startSnapshotBytes",
                uint256(262_145),
                uint256(262_144)
            )
        );
        adapter.verifyTransition(oversizedState, bytes("proof"), bytes32(0), 0, bytes32(0));

        bytes memory oversizedProof = new bytes(1_048_577);
        vm.expectRevert(
            abi.encodeWithSelector(
                PureVMVerifierAdapter.VerifierPayloadTooLarge.selector,
                "proofBytes",
                uint256(1_048_577),
                uint256(1_048_576)
            )
        );
        adapter.verifyTransition(bytes("state"), oversizedProof, bytes32(0), 0, bytes32(0));
    }
}
