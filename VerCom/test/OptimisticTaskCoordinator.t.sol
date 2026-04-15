// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ValidatorManager} from "../src/ValidatorManager.sol";
import {OptimisticTaskCoordinator} from "../src/OptimisticTaskCoordinator.sol";
import {PureVMChallengeResolver} from "../src/PureVMChallengeResolver.sol";
import {PureVMTaskManager} from "../src/PureVMTaskManager.sol";
import {PureVMTypes} from "../src/PureVMTypes.sol";
import {IOptimisticChallengeResolver} from "../src/interfaces/IOptimisticChallengeResolver.sol";
import {IPureVMVerifier} from "../src/interfaces/IPureVMVerifier.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function deal(address who, uint256 newBalance) external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(HEVM_ADDRESS);

contract MockChallengeResolver is IOptimisticChallengeResolver {
    function validateChallenge(
        bytes32,
        bytes32,
        bytes32,
        bytes32,
        bytes calldata challengeData
    ) external pure override returns (bool success, bytes32 actualResultHash, bytes32 actualStateRoot) {
        return abi.decode(challengeData, (bool, bytes32, bytes32));
    }
}

// OptimisticTaskCoordinatorTest 覆盖用户发任务、执行方认领、验证者背书、
// 验证者挑战、以及 PureVM challenge resolver 联动的经济流程。
contract OptimisticTaskCoordinatorTest {
    ValidatorManager internal validatorManager;
    MockChallengeResolver internal mockChallengeResolver;
    OptimisticTaskCoordinator internal coordinator;
    PureVMTaskManager internal pureVMTaskManager;
    PureVMChallengeResolver internal pureVMChallengeResolver;
    MockPureVMVerifier internal pureVMVerifier;

    address internal requester = address(0x1001);
    address internal executor = address(0x2002);
    address internal validatorA = address(0x3003);
    address internal validatorB = address(0x4004);
    address internal validatorC = address(0x5005);

    bytes32 internal constant PUREVM_CODE_HASH = keccak256("purevm-code");
    bytes32 internal constant INITIAL_STATE_ROOT = keccak256("state-0");
    bytes32 internal constant STATE_ROOT_1 = keccak256("state-1");
    bytes32 internal constant TRACE_ROOT_1 = keccak256("trace-1");

    bytes internal constant SNAPSHOT_BYTES_0 = bytes("snapshot-bytes-0");
    bytes internal constant SNAPSHOT_BYTES_1 = bytes("snapshot-bytes-1");

    // setUp 初始化验证者质押池、挑战解析器和协调合约，并给测试账户预充余额。
    function setUp() public {
        validatorManager = new ValidatorManager(1 ether, 1 days);
        mockChallengeResolver = new MockChallengeResolver();
        coordinator = new OptimisticTaskCoordinator(address(validatorManager), address(mockChallengeResolver), 1 days);
        pureVMVerifier = new MockPureVMVerifier();
        pureVMTaskManager = new PureVMTaskManager();
        pureVMChallengeResolver = new PureVMChallengeResolver(address(pureVMTaskManager));

        vm.deal(requester, 100 ether);
        vm.deal(executor, 100 ether);
        vm.deal(validatorA, 100 ether);
        vm.deal(validatorB, 100 ether);
        vm.deal(validatorC, 100 ether);

        vm.prank(validatorA);
        validatorManager.stake{value: 5 ether}();
        vm.prank(validatorB);
        validatorManager.stake{value: 7 ether}();
        vm.prank(validatorC);
        validatorManager.stake{value: 9 ether}();
    }

    // testPostClaimSubmitAttestAndFinalize 验证“正确执行”的正常路径：
    // 执行方提交结果、验证者背书、窗口期结束后按比例分润。
    function testPostClaimSubmitAttestAndFinalize() public {
        bytes32 taskId = _postTask();

        vm.prank(executor);
        coordinator.claimTask{value: 2 ether}(taskId);

        vm.prank(executor);
        coordinator.submitResult(taskId, "ipfs://result", keccak256("result"), keccak256("state-root"));

        address[] memory selected = coordinator.getSelectedValidators(taskId);
        require(selected.length == 2, "two validators expected");

        uint256[] memory validatorBalancesBefore = new uint256[](selected.length);
        for (uint256 i = 0; i < selected.length; i++) {
            validatorBalancesBefore[i] = selected[i].balance;
            vm.prank(selected[i]);
            coordinator.attestResult(taskId);
        }

        uint256 executorBalanceBefore = executor.balance;
        uint256 requesterBalanceBefore = requester.balance;

        vm.warp(block.timestamp + 1 days + 1);
        coordinator.finalizeTask(taskId);

        require(executor.balance > executorBalanceBefore, "executor should receive bond and reward");
        for (uint256 i = 0; i < selected.length; i++) {
            require(selected[i].balance > validatorBalancesBefore[i], "attester should receive validator reward");
        }
        require(requester.balance >= requesterBalanceBefore, "requester should receive remainder refund");
    }

    // testSelectedValidatorCanChallengeAndSplitExecutorBond 验证被选中的验证者挑战成功后，
    // 能和用户一起分执行方 bond。
    function testSelectedValidatorCanChallengeAndSplitExecutorBond() public {
        bytes32 taskId = _postTask();

        vm.prank(executor);
        coordinator.claimTask{value: 2 ether}(taskId);

        vm.prank(executor);
        coordinator.submitResult(taskId, "ipfs://result", keccak256("bad-result"), keccak256("bad-state"));

        address[] memory selected = coordinator.getSelectedValidators(taskId);
        require(selected.length > 0, "validators should be selected");

        address challenger = selected[0];
        uint256 challengerBalanceBefore = challenger.balance;
        uint256 requesterBalanceBefore = requester.balance;

        bytes memory challengeData = abi.encode(true, keccak256("actual-result"), keccak256("actual-state"));
        vm.prank(challenger);
        coordinator.challengeResult{value: 0.5 ether}(taskId, challengeData);

        require(challenger.balance > challengerBalanceBefore, "challenger should receive reward");
        require(requester.balance > requesterBalanceBefore, "requester should receive compensation");
    }

    // testUnselectedValidatorCannotChallenge 验证只有被随机选中的验证者才能发起挑战。
    function testUnselectedValidatorCannotChallenge() public {
        bytes32 taskId = _postTask();

        vm.prank(executor);
        coordinator.claimTask{value: 2 ether}(taskId);

        vm.prank(executor);
        coordinator.submitResult(taskId, "ipfs://result", keccak256("bad-result"), keccak256("bad-state"));

        address[] memory selected = coordinator.getSelectedValidators(taskId);
        address attacker = selected[0] == validatorA ? validatorB : validatorA;

        bytes memory challengeData = abi.encode(true, keccak256("actual-result"), keccak256("actual-state"));
        vm.prank(attacker);
        (bool ok,) = address(coordinator).call{value: 0.5 ether}(
            abi.encodeWithSelector(coordinator.challengeResult.selector, taskId, challengeData)
        );
        require(!ok, "unselected validator should not challenge");
    }

    // testChallengeViaPureVMResolver 验证协调合约在挑战时会真正进入 PureVM checkpoint 验证路径。
    function testChallengeViaPureVMResolver() public {
        _preparePureVMChallengePath();

        coordinator = new OptimisticTaskCoordinator(address(validatorManager), address(pureVMChallengeResolver), 1 days);
        bytes32 taskId = _postTaskWithCoordinator(coordinator, keccak256("claimed-checkpoint"), INITIAL_STATE_ROOT);

        vm.prank(executor);
        coordinator.claimTask{value: 2 ether}(taskId);

        bytes32 claimedResultHash = keccak256("bad-checkpoint");
        vm.prank(executor);
        coordinator.submitResult(taskId, "ipfs://result", claimedResultHash, bytes32(uint256(0xdead)));

        address[] memory selected = coordinator.getSelectedValidators(taskId);
        bytes memory challengeData = abi.encode(
            PureVMChallengeResolver.ChallengePayload({
                pureVMTaskId: _pureVMTaskId(),
                fromOrdinal: 0,
                nextCheckpoint: PureVMTypes.CheckpointInput({
                    stepNumber: 2_918_921,
                    gasUsed: 11_999_998,
                    gasRemaining: 288_000_022,
                    stateRoot: STATE_ROOT_1,
                    snapshotBlobHash: keccak256(SNAPSHOT_BYTES_1),
                    snapshotURI: "ipfs://snapshot-1"
                }),
                startSnapshotBytes: SNAPSHOT_BYTES_0,
                proofBytes: abi.encode(true, STATE_ROOT_1, uint64(2_918_921), TRACE_ROOT_1)
            })
        );

        uint256 requesterBalanceBefore = requester.balance;
        vm.prank(selected[0]);
        coordinator.challengeResult{value: 0.5 ether}(taskId, challengeData);
        require(requester.balance > requesterBalanceBefore, "requester should be compensated after challenge");
    }

    // _postTask 用统一参数发布一个 optimistic 任务。
    function _postTask() internal returns (bytes32) {
        return _postTaskWithCoordinator(coordinator, keccak256("summary"), keccak256("state-root"));
    }

    // _postTaskWithCoordinator 允许测试在不同 coordinator 实例上复用同一套任务发布逻辑。
    function _postTaskWithCoordinator(OptimisticTaskCoordinator target, bytes32 summaryHash, bytes32)
        internal
        returns (bytes32)
    {
        vm.prank(requester);
        return target.postTask{value: 10 ether}(
            "ipfs://summary",
            summaryHash,
            1 days,
            2,
            2 ether,
            OptimisticTaskCoordinator.PayoutConfig({
                executorRewardBps: 7000,
                validatorRewardBps: 3000,
                challengerSlashRewardBps: 4000,
                requesterSlashBps: 6000,
                challengeBond: 0.5 ether
            })
        );
    }

    // _preparePureVMChallengePath 提前准备一条可供 challenge resolver 使用的 PureVM task。
    function _preparePureVMChallengePath() internal {
        PureVMTypes.TaskCreation memory creation = PureVMTypes.TaskCreation({
            verifier: address(pureVMVerifier),
            codeHash: PUREVM_CODE_HASH,
            totalGas: 300_000_020,
            snapshotThresholdGas: 12_000_000,
            pureVMChainId: 1337,
            initialStateRoot: INITIAL_STATE_ROOT,
            initialSnapshotHash: keccak256(SNAPSHOT_BYTES_0),
            initialSnapshotURI: "ipfs://snapshot-0"
        });
        pureVMTaskManager.createTask(creation);
    }

    // _pureVMTaskId 用和 createTask 相同的规则计算测试里那条 PureVM task 的 taskId。
    function _pureVMTaskId() internal view returns (bytes32) {
        return pureVMTaskManager.computeTaskId(
            address(this),
            0,
            PUREVM_CODE_HASH,
            300_000_020,
            12_000_000,
            INITIAL_STATE_ROOT
        );
    }
}

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
