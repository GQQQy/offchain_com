// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOptimisticChallengeResolver} from "./interfaces/IOptimisticChallengeResolver.sol";
import {ValidatorManager} from "./ValidatorManager.sol";

contract OptimisticTaskCoordinator {
    uint16 internal constant BPS = 10_000;

    enum TaskStatus {
        Open,
        Claimed,
        ResultSubmitted,
        Challenged,
        Finalized,
        Cancelled
    }

    struct PayoutConfig {
        uint16 executorRewardBps;
        uint16 validatorRewardBps;
        uint16 challengerSlashRewardBps;
        uint16 requesterSlashBps;
        uint256 challengeBond;
    }

    struct TaskConfig {
        address requester;
        address executor;
        bytes32 summaryHash;
        string summaryURI;
        bytes32 resultHash;
        bytes32 claimedStateRoot;
        string resultURI;
        uint256 rewardPool;
        uint256 executorBondRequired;
        uint256 executorBondPosted;
        uint64 createdAt;
        uint64 executionDeadline;
        uint64 challengeDeadline;
        uint32 validatorCount;
        uint16 executorRewardBps;
        uint16 validatorRewardBps;
        uint16 challengerSlashRewardBps;
        uint16 requesterSlashBps;
        uint256 challengeBond;
        TaskStatus status;
        address challenger;
    }

    ValidatorManager public immutable validatorManager;
    IOptimisticChallengeResolver public immutable challengeResolver;
    uint64 public immutable defaultChallengeWindow;

    mapping(bytes32 => TaskConfig) public tasks;
    mapping(address => uint256) public requesterNonces;
    mapping(bytes32 => address[]) private selectedValidators;
    mapping(bytes32 => mapping(address => bool)) public isSelectedValidator;
    mapping(bytes32 => mapping(address => bool)) public hasAttested;
    mapping(bytes32 => address[]) private attesters;

    error InvalidTask();
    error TaskAlreadyExists();
    error RewardRequired();
    error InvalidWindow();
    error InvalidValidatorCount();
    error InvalidPayoutConfig();
    error ExecutorAlreadyAssigned();
    error ExecutorBondTooSmall();
    error OnlyExecutor();
    error ExecutionDeadlinePassed();
    error ResultNotSubmitted();
    error NotSelectedValidator();
    error AlreadyAttested();
    error ChallengeWindowClosed();
    error ChallengeWindowNotClosed();
    error ChallengeBondTooSmall();
    error ChallengeAlreadyResolved();
    error ChallengeFailed();
    error AlreadyResolved();

    event TaskPosted(
        bytes32 indexed taskId,
        address indexed requester,
        bytes32 indexed summaryHash,
        uint64 executionDeadline,
        uint32 validatorCount,
        uint256 rewardPool,
        uint256 executorBondRequired
    );
    event TaskClaimed(bytes32 indexed taskId, address indexed executor, uint256 bondPosted);
    event ResultSubmitted(bytes32 indexed taskId, bytes32 indexed resultHash, bytes32 claimedStateRoot, uint64 challengeDeadline);
    event ValidatorsSelected(bytes32 indexed taskId, address[] validators);
    event ResultAttested(bytes32 indexed taskId, address indexed validator);
    event ChallengeSucceeded(
        bytes32 indexed taskId,
        address indexed challenger,
        bytes32 actualResultHash,
        bytes32 actualStateRoot,
        uint256 challengerReward,
        uint256 requesterCompensation
    );
    event ChallengeRejected(bytes32 indexed taskId, address indexed challenger, uint256 forfeitedBond);
    event TaskFinalized(
        bytes32 indexed taskId,
        address indexed executor,
        uint256 executorPayout,
        uint256 validatorPayoutPerAttester,
        uint256 requesterRefund
    );

    constructor(
        address validatorManager_,
        address challengeResolver_,
        uint64 defaultChallengeWindow_
    ) {
        validatorManager = ValidatorManager(validatorManager_);
        challengeResolver = IOptimisticChallengeResolver(challengeResolver_);
        defaultChallengeWindow = defaultChallengeWindow_;
    }

    function postTask(
        string calldata summaryURI,
        bytes32 summaryHash,
        uint64 executionWindow,
        uint32 validatorCount,
        uint256 executorBondRequired,
        PayoutConfig calldata payoutConfig
    ) external payable returns (bytes32 taskId) {
        if (msg.value == 0) revert RewardRequired();
        if (executionWindow == 0) revert InvalidWindow();
        if (validatorCount == 0) revert InvalidValidatorCount();
        _validatePayoutConfig(payoutConfig);

        uint256 nonce = requesterNonces[msg.sender]++;
        taskId = keccak256(
            abi.encode(
                msg.sender,
                nonce,
                summaryHash,
                executionWindow,
                validatorCount,
                executorBondRequired,
                payoutConfig.executorRewardBps,
                payoutConfig.validatorRewardBps,
                payoutConfig.challengerSlashRewardBps,
                payoutConfig.requesterSlashBps,
                payoutConfig.challengeBond
            )
        );
        if (tasks[taskId].requester != address(0)) revert TaskAlreadyExists();

        tasks[taskId] = TaskConfig({
            requester: msg.sender,
            executor: address(0),
            summaryHash: summaryHash,
            summaryURI: summaryURI,
            resultHash: bytes32(0),
            claimedStateRoot: bytes32(0),
            resultURI: "",
            rewardPool: msg.value,
            executorBondRequired: executorBondRequired,
            executorBondPosted: 0,
            createdAt: uint64(block.timestamp),
            executionDeadline: uint64(block.timestamp + executionWindow),
            challengeDeadline: 0,
            validatorCount: validatorCount,
            executorRewardBps: payoutConfig.executorRewardBps,
            validatorRewardBps: payoutConfig.validatorRewardBps,
            challengerSlashRewardBps: payoutConfig.challengerSlashRewardBps,
            requesterSlashBps: payoutConfig.requesterSlashBps,
            challengeBond: payoutConfig.challengeBond,
            status: TaskStatus.Open,
            challenger: address(0)
        });

        emit TaskPosted(taskId, msg.sender, summaryHash, uint64(block.timestamp + executionWindow), validatorCount, msg.value, executorBondRequired);
    }

    function claimTask(bytes32 taskId) external payable {
        TaskConfig storage task = tasks[taskId];
        if (task.requester == address(0) || task.status != TaskStatus.Open) revert InvalidTask();
        if (task.executor != address(0)) revert ExecutorAlreadyAssigned();
        if (msg.value < task.executorBondRequired) revert ExecutorBondTooSmall();

        task.executor = msg.sender;
        task.executorBondPosted = msg.value;
        task.status = TaskStatus.Claimed;

        emit TaskClaimed(taskId, msg.sender, msg.value);
    }

    function submitResult(bytes32 taskId, string calldata resultURI, bytes32 resultHash, bytes32 claimedStateRoot) external {
        TaskConfig storage task = tasks[taskId];
        if (task.status != TaskStatus.Claimed) revert InvalidTask();
        if (msg.sender != task.executor) revert OnlyExecutor();
        if (block.timestamp > task.executionDeadline) revert ExecutionDeadlinePassed();

        task.resultURI = resultURI;
        task.resultHash = resultHash;
        task.claimedStateRoot = claimedStateRoot;
        task.challengeDeadline = uint64(block.timestamp + defaultChallengeWindow);
        task.status = TaskStatus.ResultSubmitted;

        emit ResultSubmitted(taskId, resultHash, claimedStateRoot, task.challengeDeadline);

        address[] memory validators = validatorManager.selectValidators(
            keccak256(abi.encode(taskId, resultHash, block.prevrandao)),
            task.validatorCount
        );
        for (uint256 i = 0; i < validators.length; i++) {
            selectedValidators[taskId].push(validators[i]);
            isSelectedValidator[taskId][validators[i]] = true;
        }
        emit ValidatorsSelected(taskId, validators);
    }

    function attestResult(bytes32 taskId) external {
        TaskConfig storage task = tasks[taskId];
        if (task.status != TaskStatus.ResultSubmitted) revert ResultNotSubmitted();
        if (block.timestamp > task.challengeDeadline) revert ChallengeWindowClosed();
        if (!isSelectedValidator[taskId][msg.sender]) revert NotSelectedValidator();
        if (hasAttested[taskId][msg.sender]) revert AlreadyAttested();

        hasAttested[taskId][msg.sender] = true;
        attesters[taskId].push(msg.sender);
        emit ResultAttested(taskId, msg.sender);
    }

    function challengeResult(bytes32 taskId, bytes calldata challengeData) external payable returns (bool) {
        TaskConfig storage task = tasks[taskId];
        if (task.status != TaskStatus.ResultSubmitted) revert ResultNotSubmitted();
        if (block.timestamp > task.challengeDeadline) revert ChallengeWindowClosed();
        if (!isSelectedValidator[taskId][msg.sender]) revert NotSelectedValidator();
        if (msg.value < task.challengeBond) revert ChallengeBondTooSmall();

        (bool success, bytes32 actualResultHash, bytes32 actualStateRoot) = challengeResolver.validateChallenge(
            taskId, task.summaryHash, task.resultHash, task.claimedStateRoot, challengeData
        );

        if (!success) {
            (bool okPenalty,) = payable(task.executor).call{value: msg.value}("");
            require(okPenalty, "challenge bond payout failed");
            emit ChallengeRejected(taskId, msg.sender, msg.value);
            return false;
        }

        task.status = TaskStatus.Challenged;
        task.challenger = msg.sender;

        uint256 challengerReward = (task.executorBondPosted * task.challengerSlashRewardBps) / BPS;
        uint256 requesterCompensation = task.executorBondPosted - challengerReward;
        uint256 challengerPayout = challengerReward + msg.value;
        uint256 requesterPayout = requesterCompensation + task.rewardPool;

        task.rewardPool = 0;
        task.executorBondPosted = 0;

        (bool okChallenger,) = payable(msg.sender).call{value: challengerPayout}("");
        require(okChallenger, "challenger payout failed");
        (bool okRequester,) = payable(task.requester).call{value: requesterPayout}("");
        require(okRequester, "requester payout failed");

        emit ChallengeSucceeded(
            taskId,
            msg.sender,
            actualResultHash,
            actualStateRoot,
            challengerReward,
            requesterCompensation
        );
        return true;
    }

    function finalizeTask(bytes32 taskId) external returns (bool) {
        TaskConfig storage task = tasks[taskId];
        if (task.status != TaskStatus.ResultSubmitted) revert InvalidTask();
        if (block.timestamp < task.challengeDeadline) revert ChallengeWindowNotClosed();
        if (task.status == TaskStatus.Challenged || task.status == TaskStatus.Finalized) revert AlreadyResolved();

        task.status = TaskStatus.Finalized;

        uint256 executorReward = (task.rewardPool * task.executorRewardBps) / BPS;
        uint256 validatorRewardPool = (task.rewardPool * task.validatorRewardBps) / BPS;
        uint256 requesterRefund = task.rewardPool - executorReward - validatorRewardPool;
        uint256 executorPayout = task.executorBondPosted + executorReward;

        task.rewardPool = 0;
        task.executorBondPosted = 0;

        (bool okExecutor,) = payable(task.executor).call{value: executorPayout}("");
        require(okExecutor, "executor payout failed");

        uint256 validatorPayoutPerAttester = 0;
        address[] storage signedAttesters = attesters[taskId];
        if (signedAttesters.length > 0) {
            validatorPayoutPerAttester = validatorRewardPool / signedAttesters.length;
            uint256 distributed = validatorPayoutPerAttester * signedAttesters.length;
            requesterRefund += validatorRewardPool - distributed;

            for (uint256 i = 0; i < signedAttesters.length; i++) {
                (bool okValidator,) = payable(signedAttesters[i]).call{value: validatorPayoutPerAttester}("");
                require(okValidator, "validator payout failed");
            }
        } else {
            requesterRefund += validatorRewardPool;
        }

        if (requesterRefund > 0) {
            (bool okRequester,) = payable(task.requester).call{value: requesterRefund}("");
            require(okRequester, "requester refund failed");
        }

        emit TaskFinalized(taskId, task.executor, executorPayout, validatorPayoutPerAttester, requesterRefund);
        return true;
    }

    function getSelectedValidators(bytes32 taskId) external view returns (address[] memory) {
        return selectedValidators[taskId];
    }

    function getAttesters(bytes32 taskId) external view returns (address[] memory) {
        return attesters[taskId];
    }

    function _validatePayoutConfig(PayoutConfig memory config) internal pure {
        if (config.executorRewardBps + config.validatorRewardBps > BPS) revert InvalidPayoutConfig();
        if (config.challengerSlashRewardBps + config.requesterSlashBps != BPS) revert InvalidPayoutConfig();
    }
}
