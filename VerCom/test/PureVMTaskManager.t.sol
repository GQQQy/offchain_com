// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMSnapshotStore} from "../src/PureVMSnapshotStore.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";
import {IPureVMVerifier} from "../src/interfaces/IPureVMVerifier.sol";

interface Vm {
    function expectRevert(bytes calldata) external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract MockPureVMVerifier is IPureVMVerifier {
    function verifyTransition(
        bytes calldata,
        bytes calldata proofBytes,
        bytes32,
        uint64,
        bytes32
    )
        external
        pure
        override
        returns (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot)
    {
        return abi.decode(proofBytes, (bool, bytes32, uint64, bytes32));
    }
}

// PureVMTaskManagerTest 覆盖任务创建、阈值检查、checkpoint 验证、最终收尾、
// 以及“上传快照到链上 -> 验证 -> 删除快照”的生命周期。
contract PureVMTaskManagerTest {
    PureVMTaskManager internal manager;
    MockPureVMVerifier internal verifier;
    PureVMSnapshotStore internal snapshotStore;

    bytes32 internal constant CODE_HASH = keccak256("purevm-code");
    bytes32 internal constant INITIAL_STATE_ROOT = keccak256("state-0");
    bytes32 internal constant STATE_ROOT_1 = keccak256("state-1");
    bytes32 internal constant STATE_ROOT_2 = keccak256("state-2");
    bytes32 internal constant TRACE_ROOT_1 = keccak256("trace-1");
    bytes32 internal constant TRACE_ROOT_2 = keccak256("trace-2");

    bytes internal constant SNAPSHOT_BYTES_0 = bytes("snapshot-bytes-0");
    bytes internal constant SNAPSHOT_BYTES_1 = bytes("snapshot-bytes-1");

    // setUp 部署一套最小依赖：mock verifier + task manager + snapshot store。
    function setUp() public {
        verifier = new MockPureVMVerifier();
        manager = new PureVMTaskManager();
        snapshotStore = new PureVMSnapshotStore();
    }

    // testCreateTaskRegistersInitialCheckpoint 验证创建任务时会同步登记 ordinal=0 的初始 checkpoint。
    function testCreateTaskRegistersInitialCheckpoint() public {
        bytes32 taskId = _createTask();

        PureVMTypes.TaskConfig memory task = manager.getTask(taskId);
        _assertEq(task.owner, address(this), "owner");
        _assertEq(task.verifier, address(verifier), "verifier");
        _assertEq(task.totalGas, 300_000_020, "totalGas");
        _assertEq(task.snapshotThresholdGas, 12_000_000, "threshold");
        _assertEq(task.latestVerifiedOrdinal, 0, "latest ordinal");
        _assertEq(task.checkpointCount, 1, "checkpoint count");
        _assertEq(task.initialStateRoot, INITIAL_STATE_ROOT, "initial root");

        PureVMTypes.CheckpointMeta memory initial = manager.getCheckpoint(taskId, 0);
        _assertEq(initial.ordinal, 0, "initial ordinal");
        _assertEq(initial.stepNumber, 0, "initial step");
        _assertEq(initial.gasUsed, 0, "initial gas used");
        _assertEq(initial.gasRemaining, 300_000_020, "initial gas remaining");
        _assertEq(initial.stateRoot, INITIAL_STATE_ROOT, "initial checkpoint root");
        _assertEq(initial.snapshotBlobHash, keccak256(SNAPSHOT_BYTES_0), "initial snapshot hash");
        _assertTrue(initial.verified, "initial verified");
    }

    // testVerifyAndAppendCheckpoint 验证正常的相邻 checkpoint 可以被链上追加并记录 proof 元数据。
    function testVerifyAndAppendCheckpoint() public {
        bytes32 taskId = _createTask();

        PureVMTypes.CheckpointInput memory next = PureVMTypes.CheckpointInput({
            stepNumber: 2_918_921,
            gasUsed: 11_999_998,
            gasRemaining: 288_000_022,
            stateRoot: STATE_ROOT_1,
            snapshotBlobHash: keccak256(SNAPSHOT_BYTES_1),
            snapshotURI: "ipfs://snapshot-1"
        });

        bytes memory proofBytes = abi.encode(true, STATE_ROOT_1, uint64(2_918_921), TRACE_ROOT_1);
        bool ok = manager.verifyAndAppendCheckpoint(
            taskId, 0, next, SNAPSHOT_BYTES_0, proofBytes, "ipfs://proof-0-1"
        );
        _assertTrue(ok, "append checkpoint");

        PureVMTypes.TaskConfig memory task = manager.getTask(taskId);
        _assertEq(task.latestVerifiedOrdinal, 1, "latest ordinal after append");
        _assertEq(task.checkpointCount, 2, "checkpoint count after append");
        _assertFalse(task.finalized, "should not finalize");

        PureVMTypes.CheckpointMeta memory checkpoint = manager.getCheckpoint(taskId, 1);
        _assertEq(checkpoint.stepNumber, next.stepNumber, "checkpoint step");
        _assertEq(checkpoint.gasUsed, next.gasUsed, "checkpoint gas");
        _assertEq(checkpoint.stateRoot, STATE_ROOT_1, "checkpoint root");
        _assertEq(checkpoint.snapshotBlobHash, keccak256(SNAPSHOT_BYTES_1), "checkpoint hash");

        PureVMTypes.AdjacentProofMeta memory proofMeta = manager.getAdjacentProof(taskId, 0);
        _assertEq(proofMeta.fromOrdinal, 0, "proof from");
        _assertEq(proofMeta.toOrdinal, 1, "proof to");
        _assertEq(proofMeta.proofSteps, 2_918_921, "proof steps");
        _assertEq(proofMeta.traceRoot, TRACE_ROOT_1, "trace root");
        _assertEq(proofMeta.proofBlobHash, keccak256(proofBytes), "proof blob hash");
        _assertTrue(proofMeta.fullProof, "proof full");
    }

    // testRejectCheckpointBelowThresholdBoundary 验证链上会拒绝没有跨过 snapshotThresholdGas 边界的 checkpoint。
    function testRejectCheckpointBelowThresholdBoundary() public {
        bytes32 taskId = _createTask();

        PureVMTypes.CheckpointInput memory invalid = PureVMTypes.CheckpointInput({
            stepNumber: 100,
            gasUsed: 12_000_001,
            gasRemaining: 288_000_019,
            stateRoot: STATE_ROOT_1,
            snapshotBlobHash: keccak256("bad-snapshot"),
            snapshotURI: "ipfs://bad"
        });

        bytes memory proofBytes = abi.encode(true, STATE_ROOT_1, uint64(100), TRACE_ROOT_1);
        vm.expectRevert(
            abi.encodeWithSelector(PureVMTaskManager.SegmentGasThresholdExceeded.selector, uint64(12_000_001), uint64(12_000_000))
        );
        manager.verifyAndAppendCheckpoint(taskId, 0, invalid, SNAPSHOT_BYTES_0, proofBytes, "ipfs://bad-proof");
    }

    // testFinalizeTaskOnTotalGasReached 验证当 gasUsed 到达 totalGas 时，任务会被 finalization。
    function testFinalizeTaskOnTotalGasReached() public {
        bytes32 taskId = _createTask();

        PureVMTypes.CheckpointInput memory cp1 = PureVMTypes.CheckpointInput({
            stepNumber: 2_918_921,
            gasUsed: 11_999_998,
            gasRemaining: 288_000_022,
            stateRoot: STATE_ROOT_1,
            snapshotBlobHash: keccak256(SNAPSHOT_BYTES_1),
            snapshotURI: "ipfs://snapshot-1"
        });
        bytes memory proof1 = abi.encode(true, STATE_ROOT_1, uint64(2_918_921), TRACE_ROOT_1);
        manager.verifyAndAppendCheckpoint(taskId, 0, cp1, SNAPSHOT_BYTES_0, proof1, "ipfs://proof-0-1");

        PureVMTypes.CheckpointInput memory cp2 = PureVMTypes.CheckpointInput({
            stepNumber: 72_972_980,
            gasUsed: 300_000_020,
            gasRemaining: 0,
            stateRoot: STATE_ROOT_2,
            snapshotBlobHash: keccak256("snapshot-final"),
            snapshotURI: "ipfs://snapshot-final"
        });
        bytes memory proof2 = abi.encode(true, STATE_ROOT_2, uint64(70_054_059), TRACE_ROOT_2);
        manager.verifyAndAppendCheckpoint(taskId, 1, cp2, SNAPSHOT_BYTES_1, proof2, "ipfs://proof-1-2");

        PureVMTypes.TaskConfig memory task = manager.getTask(taskId);
        _assertTrue(task.finalized, "task finalized");
        _assertEq(task.latestVerifiedOrdinal, 2, "final latest ordinal");
        _assertTrue(manager.isStateRootVerified(taskId, STATE_ROOT_2), "final root verified");
    }

    // testUploadVerifyAndDeleteSnapshotFromStore 验证“快照临时上链 -> 读取验证 -> 删除”的完整过程。
    function testUploadVerifyAndDeleteSnapshotFromStore() public {
        bytes32 taskId = _createTask();

        snapshotStore.uploadSnapshot(taskId, 0, SNAPSHOT_BYTES_0);
        _assertTrue(snapshotStore.hasSnapshot(taskId, 0), "snapshot uploaded");
        _assertEq(snapshotStore.getSnapshotHash(taskId, 0), keccak256(SNAPSHOT_BYTES_0), "snapshot hash");

        PureVMTypes.CheckpointInput memory next = PureVMTypes.CheckpointInput({
            stepNumber: 2_918_921,
            gasUsed: 11_999_998,
            gasRemaining: 288_000_022,
            stateRoot: STATE_ROOT_1,
            snapshotBlobHash: keccak256(SNAPSHOT_BYTES_1),
            snapshotURI: "ipfs://snapshot-1"
        });

        bytes memory proofBytes = abi.encode(true, STATE_ROOT_1, uint64(2_918_921), TRACE_ROOT_1);
        bool ok = manager.verifyAndAppendCheckpointFromStore(
            taskId, 0, address(snapshotStore), next, proofBytes, "ipfs://proof-0-1"
        );
        _assertTrue(ok, "verify from store");

        snapshotStore.deleteSnapshot(taskId, 0);
        _assertFalse(snapshotStore.hasSnapshot(taskId, 0), "snapshot deleted");
    }

    // _createTask 复用一套固定任务参数，避免每个测试手写同样的创建逻辑。
    function _createTask() internal returns (bytes32) {
        PureVMTypes.TaskCreation memory creation = PureVMTypes.TaskCreation({
            verifier: address(verifier),
            codeHash: CODE_HASH,
            totalGas: 300_000_020,
            snapshotThresholdGas: 12_000_000,
            pureVMChainId: 1337,
            initialStateRoot: INITIAL_STATE_ROOT,
            initialSnapshotHash: keccak256(SNAPSHOT_BYTES_0),
            initialSnapshotURI: "ipfs://snapshot-0"
        });

        return manager.createTask(creation);
    }

    function _assertTrue(bool condition, string memory label) internal pure {
        require(condition, label);
    }

    function _assertFalse(bool condition, string memory label) internal pure {
        require(!condition, label);
    }

    function _assertEq(uint256 a, uint256 b, string memory label) internal pure {
        require(a == b, label);
    }

    function _assertEq(address a, address b, string memory label) internal pure {
        require(a == b, label);
    }

    function _assertEq(bytes32 a, bytes32 b, string memory label) internal pure {
        require(a == b, label);
    }
}
