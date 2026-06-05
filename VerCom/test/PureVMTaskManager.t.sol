// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMSnapshotStore} from "../src/PureVMSnapshotStore.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";
import {IPureVMVerifier} from "../src/interfaces/IPureVMVerifier.sol";

interface Vm {
    function expectRevert(bytes calldata) external;
    function prank(address) external;
    function deal(address who, uint256 newBalance) external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract MockPureVMVerifier is IPureVMVerifier {
    function verifyTransition(bytes calldata, bytes calldata proofBytes, bytes32, uint64, bytes32)
        external
        pure
        override
        returns (bool valid, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot)
    {
        return abi.decode(proofBytes, (bool, bytes32, uint64, bytes32));
    }

    function verifyTransitionDetailed(
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        bytes32,
        uint64,
        bytes32
    )
        external
        pure
        override
        returns (bool valid, bytes32 initialStateRoot, bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot)
    {
        if (proofBytes.length == 160) {
            (valid, initialStateRoot, finalStateRoot, verifiedSteps, traceRoot) =
                abi.decode(proofBytes, (bool, bytes32, bytes32, uint64, bytes32));
        } else {
            (valid, finalStateRoot, verifiedSteps, traceRoot) = abi.decode(proofBytes, (bool, bytes32, uint64, bytes32));
            initialStateRoot = keccak256(startSnapshotBytes);
        }
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
    bytes32 internal constant COMMON_ROOT_1 = keccak256("common-1");
    bytes32 internal constant EXECUTOR_ROOT_2 = keccak256("executor-2");
    bytes32 internal constant CHALLENGER_ROOT_2 = keccak256("challenger-2");
    bytes32 internal constant CHALLENGER_BAD_ROOT = keccak256("challenger-bad");
    bytes32 internal constant TRACE_ROOT_1 = keccak256("trace-1");
    bytes32 internal constant TRACE_ROOT_2 = keccak256("trace-2");

    bytes internal constant SNAPSHOT_BYTES_0 = bytes("snapshot-bytes-0");
    bytes internal constant SNAPSHOT_BYTES_1 = bytes("snapshot-bytes-1");
    bytes internal constant EXECUTOR_SNAPSHOT_2 = bytes("executor-snapshot-2");
    bytes internal constant CHALLENGER_SNAPSHOT_2 = bytes("challenger-snapshot-2");
    bytes internal constant WINNER_SNAPSHOT = bytes("winner-snapshot");
    bytes internal constant BAD_SNAPSHOT = bytes("bad-snapshot");

    address internal executor = address(0x2002);
    address internal challenger = address(0x3003);

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

        bytes32[] memory dataIds = manager.getTaskDataAvailabilityIds(taskId);
        _assertEq(dataIds.length, 1, "initial da count");
        PureVMTypes.DataAvailabilityMeta memory da = manager.getDataAvailability(dataIds[0]);
        _assertEq(uint256(da.kind), uint256(PureVMTypes.DataKind.Snapshot), "initial da kind");
        _assertEq(da.dataHash, keccak256(SNAPSHOT_BYTES_0), "initial da hash");
        _assertEq(da.semanticHash, INITIAL_STATE_ROOT, "initial da semantic");
        _assertTrue(da.available, "initial da available");
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
        bool ok = manager.verifyAndAppendCheckpoint(taskId, 0, next, SNAPSHOT_BYTES_0, proofBytes, "ipfs://proof-0-1");
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

        bytes32[] memory dataIds = manager.getTaskDataAvailabilityIds(taskId);
        _assertEq(dataIds.length, 3, "da count after append");
        bytes32 proofDataId =
            manager.dataAvailabilityId(taskId, PureVMTypes.DataKind.Proof, 0, keccak256(proofBytes), TRACE_ROOT_1);
        PureVMTypes.DataAvailabilityMeta memory proofDA = manager.getDataAvailability(proofDataId);
        _assertEq(proofDA.dataHash, keccak256(proofBytes), "proof da hash");
        _assertEq(proofDA.size, proofBytes.length, "proof da size");
        _assertTrue(proofDA.available, "proof da available");
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
            abi.encodeWithSelector(
                PureVMTaskManager.SegmentGasThresholdExceeded.selector, uint64(12_000_001), uint64(12_000_000)
            )
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

    function testRegisterDataAvailabilityAndUpdateStatus() public {
        bytes32 taskId = _createTask();
        bytes32 dataHash = keccak256("da-proof");
        bytes32 semanticHash = keccak256("semantic-proof");

        bytes32 dataId = manager.registerDataAvailability(
            taskId, PureVMTypes.DataKind.Proof, 7, dataHash, semanticHash, 123, "ipfs://proof-da", false
        );
        PureVMTypes.DataAvailabilityMeta memory meta = manager.getDataAvailability(dataId);
        _assertEq(meta.dataHash, dataHash, "registered da hash");
        _assertEq(meta.semanticHash, semanticHash, "registered semantic hash");
        _assertEq(meta.size, 123, "registered da size");
        _assertFalse(meta.available, "registered unavailable");

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(PureVMTaskManager.UnauthorizedDataAvailabilityUpdate.selector));
        manager.setDataAvailabilityStatus(dataId, true);

        manager.setDataAvailabilityStatus(dataId, true);
        meta = manager.getDataAvailability(dataId);
        _assertTrue(meta.available, "registered available");
    }

    function testRejectOversizedInterfaces() public {
        PureVMTypes.TaskCreation memory creation = PureVMTypes.TaskCreation({
            verifier: address(verifier),
            codeHash: CODE_HASH,
            totalGas: 300_000_020,
            snapshotThresholdGas: 12_000_000,
            pureVMChainId: 1337,
            initialStateRoot: INITIAL_STATE_ROOT,
            initialSnapshotHash: keccak256(SNAPSHOT_BYTES_0),
            initialSnapshotURI: string(new bytes(2_049))
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                PureVMTaskManager.InterfaceLimitExceeded.selector, "initialSnapshotURI", uint256(2_049), uint256(2_048)
            )
        );
        manager.createTask(creation);

        bytes memory oversizedSnapshot = new bytes(262_145);
        vm.expectRevert(
            abi.encodeWithSelector(PureVMSnapshotStore.SnapshotTooLarge.selector, uint256(262_145), uint256(262_144))
        );
        snapshotStore.uploadSnapshot(bytes32("task"), 0, oversizedSnapshot);
    }

    function testDisputeGameSubdividesStakesAndFinalizesWithMDUProof() public {
        bytes32 taskId = _createTask();
        _fundDisputeParties();

        bytes32 gameId = _createDisputeGame(taskId);
        _assertEq(manager.requiredStakeForRound(gameId), 1 ether, "round 0 stake");

        vm.prank(challenger);
        manager.depositDisputeStake{value: 1 ether}(gameId);
        PureVMTypes.DisputeGame memory game = manager.getDisputeGame(gameId);
        _assertEq(uint256(game.status), uint256(PureVMTypes.DisputeGameStatus.Open), "round 0 open");

        vm.prank(executor);
        manager.submitSubdivision(gameId, _roundZeroExecutorSubdivision(), "ipfs://exec-r0");
        vm.prank(challenger);
        manager.submitSubdivision(gameId, _roundZeroChallengerSubdivision(), "ipfs://chal-r0");
        vm.prank(challenger);
        manager.declareDivergence(gameId, 2);

        game = manager.getDisputeGame(gameId);
        _assertEq(uint256(game.status), uint256(PureVMTypes.DisputeGameStatus.Staking), "round 1 staking");
        _assertEq(game.currentRound, 1, "round index after split");
        _assertEq(manager.requiredStakeForRound(gameId), 2 ether, "round 1 cumulative stake");
        _assertEq(game.commonRoot, COMMON_ROOT_1, "round 1 common root");

        vm.prank(executor);
        manager.depositDisputeStake{value: 1 ether}(gameId);
        vm.prank(challenger);
        manager.depositDisputeStake{value: 1 ether}(gameId);
        game = manager.getDisputeGame(gameId);
        _assertEq(uint256(game.status), uint256(PureVMTypes.DisputeGameStatus.Open), "round 1 open");
        _assertEq(game.executorStake, 2 ether, "executor cumulative stake");
        _assertEq(game.challengerStake, 2 ether, "challenger cumulative stake");

        vm.prank(executor);
        manager.submitSubdivision(gameId, _roundOneExecutorSubdivision(), "ipfs://exec-r1");
        vm.prank(challenger);
        manager.submitSubdivision(gameId, _roundOneChallengerSubdivision(), "ipfs://chal-r1");
        vm.prank(challenger);
        manager.declareDivergence(gameId, 1);

        game = manager.getDisputeGame(gameId);
        _assertEq(uint256(game.status), uint256(PureVMTypes.DisputeGameStatus.ReadyForFinal), "ready final");
        _assertEq(game.commonRoot, COMMON_ROOT_1, "final common root");
        _assertEq(game.executorRoot, STATE_ROOT_1, "final executor root");
        _assertEq(game.challengerRoot, CHALLENGER_BAD_ROOT, "final challenger root");

        uint256 executorBalanceBefore = executor.balance;
        PureVMTypes.CheckpointInput memory actual = PureVMTypes.CheckpointInput({
            stepNumber: 150,
            gasUsed: 4_500_000,
            gasRemaining: 295_500_020,
            stateRoot: STATE_ROOT_1,
            snapshotBlobHash: keccak256(WINNER_SNAPSHOT),
            snapshotURI: "ipfs://winner-snapshot"
        });
        bytes memory proof = abi.encode(true, COMMON_ROOT_1, STATE_ROOT_1, uint64(50), TRACE_ROOT_1);
        (PureVMTypes.DisputeWinner winner,, bytes32 actualStateRoot) =
            manager.resolveDisputeGameWithProof(gameId, actual, SNAPSHOT_BYTES_1, proof);

        _assertEq(uint256(winner), uint256(PureVMTypes.DisputeWinner.Executor), "executor wins");
        _assertEq(actualStateRoot, STATE_ROOT_1, "actual mdu state");
        game = manager.getDisputeGame(gameId);
        _assertEq(uint256(game.status), uint256(PureVMTypes.DisputeGameStatus.Resolved), "game resolved");
        _assertEq(uint256(game.winner), uint256(PureVMTypes.DisputeWinner.Executor), "winner stored");
        _assertEq(game.executorStake, 0, "executor stake cleared");
        _assertTrue(executor.balance > executorBalanceBefore, "executor receives dispute pool");
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

    function _fundDisputeParties() internal {
        vm.deal(executor, 10 ether);
        vm.deal(challenger, 10 ether);
    }

    function _createDisputeGame(bytes32 taskId) internal returns (bytes32) {
        PureVMTypes.DisputeGameCreation memory creation = PureVMTypes.DisputeGameCreation({
            taskId: taskId,
            fromOrdinal: 0,
            toOrdinal: 1,
            executor: executor,
            challenger: challenger,
            claimedResultHash: keccak256("claimed-result"),
            claimedStateRoot: EXECUTOR_ROOT_2,
            claimedSnapshotBlobHash: keccak256(EXECUTOR_SNAPSHOT_2),
            challengerStateRoot: CHALLENGER_ROOT_2,
            challengerSnapshotBlobHash: keccak256(CHALLENGER_SNAPSHOT_2),
            claimedStepNumber: 300,
            claimedGasUsed: 9_000_000,
            adjudicationThresholdGas: 2_000_000,
            maxRounds: 3,
            roundDuration: 1 days,
            baseStake: 1 ether
        });
        vm.prank(executor);
        return manager.createDisputeGame{value: 1 ether}(creation);
    }

    function _roundZeroExecutorSubdivision()
        internal
        pure
        returns (PureVMTypes.SubdivisionCommitment[] memory commitments)
    {
        commitments = new PureVMTypes.SubdivisionCommitment[](4);
        commitments[0] = _commit(0, 0, 0, INITIAL_STATE_ROOT, keccak256(SNAPSHOT_BYTES_0));
        commitments[1] = _commit(1, 100, 3_000_000, COMMON_ROOT_1, keccak256(SNAPSHOT_BYTES_1));
        commitments[2] = _commit(2, 200, 6_000_000, EXECUTOR_ROOT_2, keccak256(EXECUTOR_SNAPSHOT_2));
        commitments[3] = _commit(3, 300, 9_000_000, EXECUTOR_ROOT_2, keccak256(EXECUTOR_SNAPSHOT_2));
    }

    function _roundZeroChallengerSubdivision()
        internal
        pure
        returns (PureVMTypes.SubdivisionCommitment[] memory commitments)
    {
        commitments = new PureVMTypes.SubdivisionCommitment[](4);
        commitments[0] = _commit(0, 0, 0, INITIAL_STATE_ROOT, keccak256(SNAPSHOT_BYTES_0));
        commitments[1] = _commit(1, 100, 3_000_000, COMMON_ROOT_1, keccak256(SNAPSHOT_BYTES_1));
        commitments[2] = _commit(2, 200, 6_000_000, CHALLENGER_ROOT_2, keccak256(CHALLENGER_SNAPSHOT_2));
        commitments[3] = _commit(3, 300, 9_000_000, CHALLENGER_ROOT_2, keccak256(CHALLENGER_SNAPSHOT_2));
    }

    function _roundOneExecutorSubdivision()
        internal
        pure
        returns (PureVMTypes.SubdivisionCommitment[] memory commitments)
    {
        commitments = new PureVMTypes.SubdivisionCommitment[](3);
        commitments[0] = _commit(0, 100, 3_000_000, COMMON_ROOT_1, keccak256(SNAPSHOT_BYTES_1));
        commitments[1] = _commit(1, 150, 4_500_000, STATE_ROOT_1, keccak256(WINNER_SNAPSHOT));
        commitments[2] = _commit(2, 200, 6_000_000, EXECUTOR_ROOT_2, keccak256(EXECUTOR_SNAPSHOT_2));
    }

    function _roundOneChallengerSubdivision()
        internal
        pure
        returns (PureVMTypes.SubdivisionCommitment[] memory commitments)
    {
        commitments = new PureVMTypes.SubdivisionCommitment[](3);
        commitments[0] = _commit(0, 100, 3_000_000, COMMON_ROOT_1, keccak256(SNAPSHOT_BYTES_1));
        commitments[1] = _commit(1, 150, 4_500_000, CHALLENGER_BAD_ROOT, keccak256(BAD_SNAPSHOT));
        commitments[2] = _commit(2, 200, 6_000_000, CHALLENGER_ROOT_2, keccak256(CHALLENGER_SNAPSHOT_2));
    }

    function _commit(uint32 index, uint64 step, uint64 gasUsed, bytes32 root, bytes32 snapshotHash)
        internal
        pure
        returns (PureVMTypes.SubdivisionCommitment memory)
    {
        return PureVMTypes.SubdivisionCommitment({
            index: index,
            stepNumber: step,
            gasUsed: gasUsed,
            stateRoot: root,
            snapshotBlobHash: snapshotHash
        });
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
