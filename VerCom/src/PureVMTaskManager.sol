// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPureVMVerifier} from "./interfaces/IPureVMVerifier.sol";
import {IPureVMSnapshotStore} from "./interfaces/IPureVMSnapshotStore.sol";
import {PureVMTypes} from "./PureVMTypes.sol";

contract PureVMTaskManager {
    uint256 public constant MAX_URI_BYTES = 2_048;
    uint256 public constant MAX_DIRECT_SNAPSHOT_BYTES = 262_144;
    uint256 public constant MAX_PROOF_BYTES = 1_048_576;
    uint256 public constant MAX_SUBDIVISION_COMMITMENTS = 128;
    uint8 public constant MAX_DISPUTE_ROUNDS = 16;
    uint64 public constant MAX_ROUND_DURATION = 30 days;
    uint64 public constant DATA_AVAILABILITY_CHALLENGE_WINDOW = 1 days;

    mapping(bytes32 => PureVMTypes.TaskConfig) private tasks;
    mapping(bytes32 => mapping(uint32 => PureVMTypes.CheckpointMeta)) private checkpoints;
    mapping(bytes32 => mapping(uint32 => PureVMTypes.AdjacentProofMeta)) private adjacentProofs;
    mapping(bytes32 => mapping(bytes32 => bool)) private verifiedRoots;
    mapping(bytes32 => PureVMTypes.DisputeMeta) private disputes;
    mapping(bytes32 => mapping(uint32 => bytes32)) private latestDisputeForCheckpoint;
    mapping(bytes32 => PureVMTypes.DataAvailabilityMeta) private dataAvailability;
    mapping(bytes32 => bytes32[]) private taskDataAvailabilityIds;
    mapping(bytes32 => PureVMTypes.DataAvailabilityChallengeMeta) private dataAvailabilityChallenges;
    mapping(bytes32 => bytes32) private latestDataAvailabilityChallengeForData;
    mapping(bytes32 => PureVMTypes.ArtifactManifestMeta) private artifactManifests;
    mapping(bytes32 => mapping(uint32 => bytes32)) private checkpointArtifactManifestIds;
    mapping(bytes32 => PureVMTypes.DisputeGame) private disputeGames;
    mapping(bytes32 => PureVMTypes.SubdivisionCommitment[]) private executorSubdivisions;
    mapping(bytes32 => PureVMTypes.SubdivisionCommitment[]) private challengerSubdivisions;
    mapping(address => bool) public authorizedChallengeResolvers;
    mapping(address => bool) public approvedVerifiers;
    mapping(address => uint32) public verifierVersions;
    mapping(address => uint256) public taskNonces;
    address public immutable owner;
    uint256 public disputeGameNonce;

    error EmptyVerifier();
    error InvalidTask();
    error TaskAlreadyExists();
    error VerifierNotApproved(address verifier);
    error InvalidVerifierVersion();
    error InvalidThreshold();
    error InvalidTotalGas();
    error CheckpointAlreadyExists();
    error InvalidOrdinal();
    error UnverifiedCheckpoint();
    error InvalidCheckpointProgression();
    error InvalidGasAccounting();
    error SegmentGasThresholdExceeded(uint64 segmentGasUsed, uint64 threshold);
    error StartSnapshotHashMismatch();
    error VerificationFailed();
    error FinalRootMismatch(bytes32 got, bytes32 want);
    error VerifiedStepsMismatch(uint64 got, uint64 want);
    error StartRootMismatch(bytes32 got, bytes32 want);
    error InvalidDispute();
    error DisputeAlreadyRecorded();
    error OnlyOwner();
    error UnauthorizedChallengeResolver();
    error InterfaceLimitExceeded(string field, uint256 size, uint256 limit);
    error InvalidDataAvailability();
    error DataAvailabilityAlreadyRegistered();
    error DataAvailabilityNotFound();
    error DataAvailabilityChallengeAlreadyOpen();
    error InvalidDataAvailabilityChallenge();
    error DataAvailabilityChallengeExpired();
    error DataAvailabilityChallengeStillOpen();
    error UnauthorizedDataAvailabilityUpdate();
    error InvalidDisputeGame();
    error DisputeGameAlreadyResolved();
    error InvalidDisputeStake();
    error UnauthorizedDisputeParty();
    error DisputeRoundNotFunded(uint8 round, uint256 executorStake, uint256 challengerStake, uint256 requiredStake);
    error InvalidSubdivision();
    error SubdivisionScheduleMismatch();
    error NoDivergence();
    error DisputeNotReadyForFinal();
    error DisputeTimeoutUnavailable();

    event TaskCreated(
        bytes32 indexed taskId,
        address indexed owner,
        address indexed verifier,
        uint32 verifierVersion,
        bytes32 codeHash,
        uint64 totalGas,
        uint64 snapshotThresholdGas
    );
    event CheckpointRegistered(
        bytes32 indexed taskId,
        uint32 indexed ordinal,
        uint64 stepNumber,
        uint64 gasUsed,
        bytes32 stateRoot,
        bytes32 snapshotBlobHash
    );
    event AdjacentCheckpointVerified(
        bytes32 indexed taskId,
        uint32 indexed fromOrdinal,
        uint32 indexed toOrdinal,
        uint64 proofSteps,
        bytes32 finalStateRoot,
        bytes32 traceRoot
    );
    event DisputeResolved(
        bytes32 indexed disputeId,
        bytes32 indexed taskId,
        uint32 indexed fromOrdinal,
        uint32 toOrdinal,
        address challenger,
        bool challengerWon,
        bytes32 claimedResultHash,
        bytes32 actualResultHash,
        bytes32 claimedStateRoot,
        bytes32 actualStateRoot,
        bytes32 traceRoot
    );
    event DataAvailabilityRegistered(
        bytes32 indexed dataId,
        bytes32 indexed taskId,
        PureVMTypes.DataKind kind,
        uint32 ordinal,
        bytes32 dataHash,
        bytes32 semanticHash,
        uint64 size,
        string uri,
        address publisher
    );
    event ArtifactManifestRegistered(
        bytes32 indexed manifestId,
        bytes32 indexed taskId,
        uint32 indexed checkpointOrdinal,
        bytes32 manifestHash,
        string manifestURI,
        address publisher
    );
    event DataAvailabilityStatusUpdated(bytes32 indexed dataId, bool available);
    event DataAvailabilityChallenged(
        bytes32 indexed challengeId, bytes32 indexed dataId, address indexed challenger, uint64 deadline
    );
    event DataAvailabilityChallengeResolved(
        bytes32 indexed challengeId,
        bytes32 indexed dataId,
        bool challengerWon,
        address resolver,
        string uri
    );
    event ChallengeResolverAuthorizationUpdated(address indexed resolver, bool authorized);
    event VerifierApprovalUpdated(address indexed verifier, bool approved, uint32 version);
    event DisputeGameCreated(
        bytes32 indexed gameId,
        bytes32 indexed taskId,
        uint32 indexed fromOrdinal,
        uint32 toOrdinal,
        address executor,
        address challenger,
        uint256 baseStake,
        uint64 adjudicationThresholdGas
    );
    event DisputeStakeDeposited(
        bytes32 indexed gameId, address indexed party, uint8 round, uint256 amount, uint256 totalStake
    );
    event DisputeRoundFunded(bytes32 indexed gameId, uint8 round, uint256 requiredStake);
    event SubdivisionSubmitted(
        bytes32 indexed gameId,
        address indexed party,
        uint8 round,
        bytes32 subdivisionRoot,
        bytes32 dataId,
        uint256 commitmentCount
    );
    event DivergenceDeclared(
        bytes32 indexed gameId,
        uint8 round,
        uint32 divergenceIndex,
        bytes32 commonRoot,
        bytes32 executorRoot,
        bytes32 challengerRoot,
        bool readyForFinal
    );
    event DisputeRoundAdvanced(bytes32 indexed gameId, uint8 round, uint64 commonGasUsed, uint64 targetGasUsed);
    event DisputeGameResolved(
        bytes32 indexed gameId,
        bytes32 indexed taskId,
        PureVMTypes.DisputeWinner winner,
        bytes32 actualStateRoot,
        bytes32 traceRoot,
        uint256 payout
    );
    event TaskFinalized(bytes32 indexed taskId, uint32 indexed finalOrdinal, bytes32 finalStateRoot);

    constructor() {
        owner = msg.sender;
    }

    function createTask(PureVMTypes.TaskCreation calldata creation) external returns (bytes32 taskId) {
        if (creation.verifier == address(0)) revert EmptyVerifier();
        if (!approvedVerifiers[creation.verifier]) revert VerifierNotApproved(creation.verifier);
        if (creation.snapshotThresholdGas == 0) revert InvalidThreshold();
        if (creation.totalGas == 0) revert InvalidTotalGas();
        _validateUri("initialSnapshotURI", creation.initialSnapshotURI);
        uint32 verifierVersion = verifierVersions[creation.verifier];
        if (verifierVersion == 0) revert InvalidVerifierVersion();

        uint256 nonce = taskNonces[msg.sender]++;
        taskId = computeTaskId(
            msg.sender,
            nonce,
            creation.codeHash,
            creation.totalGas,
            creation.snapshotThresholdGas,
            creation.initialStateRoot
        );
        if (tasks[taskId].exists) revert TaskAlreadyExists();

        tasks[taskId] = PureVMTypes.TaskConfig({
            owner: msg.sender,
            verifier: creation.verifier,
            verifierVersion: verifierVersion,
            codeHash: creation.codeHash,
            totalGas: creation.totalGas,
            snapshotThresholdGas: creation.snapshotThresholdGas,
            pureVMChainId: creation.pureVMChainId,
            initialStateRoot: creation.initialStateRoot,
            latestVerifiedOrdinal: 0,
            checkpointCount: 1,
            finalized: false,
            exists: true
        });

        checkpoints[taskId][0] = PureVMTypes.CheckpointMeta({
            ordinal: 0,
            stepNumber: 0,
            gasUsed: 0,
            gasRemaining: creation.totalGas,
            stateRoot: creation.initialStateRoot,
            snapshotBlobHash: creation.initialSnapshotHash,
            snapshotURI: creation.initialSnapshotURI,
            exists: true,
            verified: true
        });
        verifiedRoots[taskId][creation.initialStateRoot] = true;

        emit TaskCreated(
            taskId,
            msg.sender,
            creation.verifier,
            verifierVersion,
            creation.codeHash,
            creation.totalGas,
            creation.snapshotThresholdGas
        );
        emit CheckpointRegistered(taskId, 0, 0, 0, creation.initialStateRoot, creation.initialSnapshotHash);
        _registerDataAvailability(
            taskId,
            PureVMTypes.DataKind.Snapshot,
            0,
            creation.initialSnapshotHash,
            creation.initialStateRoot,
            0,
            creation.initialSnapshotURI,
            msg.sender,
            true
        );
        _registerArtifactManifest(
            taskId,
            0,
            checkpointArtifactManifestHash(
                taskId,
                0,
                0,
                bytes32(0),
                creation.initialSnapshotHash,
                bytes32(0),
                creation.initialStateRoot,
                creation.initialSnapshotURI,
                ""
            ),
            "",
            msg.sender
        );
    }

    function verifyAndAppendCheckpoint(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        string calldata proofURI
    ) external returns (bool) {
        return _verifyAndAppendCheckpoint(
            taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes, proofURI, bytes32(0), ""
        );
    }

    function verifyAndAppendCheckpointWithManifest(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        string calldata proofURI,
        bytes32 artifactManifestHash,
        string calldata artifactManifestURI
    ) external returns (bool) {
        if (artifactManifestHash == bytes32(0)) revert InvalidDataAvailability();
        return _verifyAndAppendCheckpoint(
            taskId,
            fromOrdinal,
            nextCheckpoint,
            startSnapshotBytes,
            proofBytes,
            proofURI,
            artifactManifestHash,
            artifactManifestURI
        );
    }

    function previewCheckpointVerification(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes
    ) external view returns (bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) {
        return _previewCheckpointVerification(taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes);
    }

    function verifyAndAppendCheckpointFromStore(
        bytes32 taskId,
        uint32 fromOrdinal,
        address snapshotStore,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata proofBytes,
        string calldata proofURI
    ) external returns (bool) {
        bytes memory startSnapshotBytes = IPureVMSnapshotStore(snapshotStore).getSnapshot(taskId, fromOrdinal);
        return _verifyAndAppendCheckpoint(
            taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes, proofURI, bytes32(0), ""
        );
    }

    function verifyAndAppendCheckpointFromStoreWithManifest(
        bytes32 taskId,
        uint32 fromOrdinal,
        address snapshotStore,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes calldata proofBytes,
        string calldata proofURI,
        bytes32 artifactManifestHash,
        string calldata artifactManifestURI
    ) external returns (bool) {
        if (artifactManifestHash == bytes32(0)) revert InvalidDataAvailability();
        bytes memory startSnapshotBytes = IPureVMSnapshotStore(snapshotStore).getSnapshot(taskId, fromOrdinal);
        return _verifyAndAppendCheckpoint(
            taskId,
            fromOrdinal,
            nextCheckpoint,
            startSnapshotBytes,
            proofBytes,
            proofURI,
            artifactManifestHash,
            artifactManifestURI
        );
    }

    function _verifyAndAppendCheckpoint(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes memory startSnapshotBytes,
        bytes calldata proofBytes,
        string memory proofURI,
        bytes32 artifactManifestHash,
        string memory artifactManifestURI
    ) internal returns (bool) {
        _validatePayloadLimits(startSnapshotBytes.length, proofBytes.length);
        _validateUri("snapshotURI", nextCheckpoint.snapshotURI);
        _validateUri("proofURI", proofURI);
        _validateUri("artifactManifestURI", artifactManifestURI);

        PureVMTypes.TaskConfig storage task = tasks[taskId];
        if (!task.exists || task.finalized) revert InvalidTask();
        if (fromOrdinal != task.latestVerifiedOrdinal) revert InvalidOrdinal();

        PureVMTypes.CheckpointMeta storage start = checkpoints[taskId][fromOrdinal];
        if (!start.verified) revert UnverifiedCheckpoint();

        uint32 nextOrdinal = fromOrdinal + 1;
        if (checkpoints[taskId][nextOrdinal].exists) revert CheckpointAlreadyExists();

        _validateCheckpointProgression(task, start, nextOrdinal, nextCheckpoint);

        if (keccak256(startSnapshotBytes) != start.snapshotBlobHash) revert StartSnapshotHashMismatch();

        (, uint64 verifiedSteps, bytes32 traceRoot) =
            _previewCheckpointVerification(taskId, fromOrdinal, nextCheckpoint, startSnapshotBytes, proofBytes);

        checkpoints[taskId][nextOrdinal] = PureVMTypes.CheckpointMeta({
            ordinal: nextOrdinal,
            stepNumber: nextCheckpoint.stepNumber,
            gasUsed: nextCheckpoint.gasUsed,
            gasRemaining: nextCheckpoint.gasRemaining,
            stateRoot: nextCheckpoint.stateRoot,
            snapshotBlobHash: nextCheckpoint.snapshotBlobHash,
            snapshotURI: nextCheckpoint.snapshotURI,
            exists: true,
            verified: true
        });

        adjacentProofs[taskId][fromOrdinal] = PureVMTypes.AdjacentProofMeta({
            fromOrdinal: fromOrdinal,
            toOrdinal: nextOrdinal,
            proofSteps: verifiedSteps,
            fullProof: true,
            proofBlobHash: keccak256(proofBytes),
            traceRoot: traceRoot,
            proofURI: proofURI,
            verifiedAtBlock: uint64(block.number)
        });

        verifiedRoots[taskId][nextCheckpoint.stateRoot] = true;
        task.latestVerifiedOrdinal = nextOrdinal;
        task.checkpointCount = nextOrdinal + 1;

        emit CheckpointRegistered(
            taskId,
            nextOrdinal,
            nextCheckpoint.stepNumber,
            nextCheckpoint.gasUsed,
            nextCheckpoint.stateRoot,
            nextCheckpoint.snapshotBlobHash
        );
        emit AdjacentCheckpointVerified(
            taskId, fromOrdinal, nextOrdinal, verifiedSteps, nextCheckpoint.stateRoot, traceRoot
        );
        _registerDataAvailability(
            taskId,
            PureVMTypes.DataKind.Snapshot,
            nextOrdinal,
            nextCheckpoint.snapshotBlobHash,
            nextCheckpoint.stateRoot,
            0,
            nextCheckpoint.snapshotURI,
            msg.sender,
            true
        );
        _registerDataAvailability(
            taskId,
            PureVMTypes.DataKind.Proof,
            fromOrdinal,
            keccak256(proofBytes),
            traceRoot,
            uint64(proofBytes.length),
            proofURI,
            msg.sender,
            true
        );
        bytes32 manifestHash = artifactManifestHash;
        if (manifestHash == bytes32(0)) {
            manifestHash = checkpointArtifactManifestHash(
                taskId,
                fromOrdinal,
                nextOrdinal,
                start.snapshotBlobHash,
                nextCheckpoint.snapshotBlobHash,
                keccak256(proofBytes),
                traceRoot,
                nextCheckpoint.snapshotURI,
                proofURI
            );
        }
        _registerArtifactManifest(taskId, nextOrdinal, manifestHash, artifactManifestURI, msg.sender);

        if (nextCheckpoint.gasUsed == task.totalGas) {
            task.finalized = true;
            emit TaskFinalized(taskId, nextOrdinal, nextCheckpoint.stateRoot);
        }

        return true;
    }

    function _previewCheckpointVerification(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint,
        bytes memory startSnapshotBytes,
        bytes calldata proofBytes
    ) internal view returns (bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) {
        _validatePayloadLimits(startSnapshotBytes.length, proofBytes.length);
        _validateUri("snapshotURI", nextCheckpoint.snapshotURI);

        PureVMTypes.TaskConfig storage task = tasks[taskId];
        if (!task.exists) revert InvalidTask();
        if (fromOrdinal > task.latestVerifiedOrdinal) revert InvalidOrdinal();

        PureVMTypes.CheckpointMeta storage start = checkpoints[taskId][fromOrdinal];
        if (!start.verified) revert UnverifiedCheckpoint();

        uint32 nextOrdinal = fromOrdinal + 1;
        _validateCheckpointProgression(task, start, nextOrdinal, nextCheckpoint);

        if (keccak256(startSnapshotBytes) != start.snapshotBlobHash) revert StartSnapshotHashMismatch();

        uint64 expectedSteps = nextCheckpoint.stepNumber - start.stepNumber;
        (bool valid, bytes32 verifiedFinalRoot, uint64 steps, bytes32 verifiedTraceRoot) = IPureVMVerifier(
            task.verifier
        ).verifyTransition(startSnapshotBytes, proofBytes, nextCheckpoint.stateRoot, expectedSteps, bytes32(0));
        if (!valid) revert VerificationFailed();
        if (steps != expectedSteps) revert VerifiedStepsMismatch(steps, expectedSteps);
        if (verifiedFinalRoot != nextCheckpoint.stateRoot) {
            revert FinalRootMismatch(verifiedFinalRoot, nextCheckpoint.stateRoot);
        }

        return (verifiedFinalRoot, steps, verifiedTraceRoot);
    }

    function resolveDispute(
        bytes32 disputeId,
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata actualCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes,
        bytes32 claimedResultHash,
        bytes32 claimedStateRoot,
        address challenger
    ) external returns (bool challengerWon, bytes32 actualResultHash, bytes32 actualStateRoot) {
        if (!authorizedChallengeResolvers[msg.sender]) revert UnauthorizedChallengeResolver();
        if (disputeId == bytes32(0) || challenger == address(0)) revert InvalidDispute();
        if (disputes[disputeId].status != PureVMTypes.DisputeStatus.None) revert DisputeAlreadyRecorded();

        (bytes32 finalStateRoot, uint64 verifiedSteps, bytes32 traceRoot) =
            _previewCheckpointVerification(taskId, fromOrdinal, actualCheckpoint, startSnapshotBytes, proofBytes);

        uint32 toOrdinal = fromOrdinal + 1;
        actualResultHash = checkpointClaimHash(taskId, toOrdinal, actualCheckpoint);
        actualStateRoot = finalStateRoot;
        challengerWon = actualResultHash != claimedResultHash || actualStateRoot != claimedStateRoot;

        disputes[disputeId] = PureVMTypes.DisputeMeta({
            taskId: taskId,
            fromOrdinal: fromOrdinal,
            toOrdinal: toOrdinal,
            claimedResultHash: claimedResultHash,
            actualResultHash: actualResultHash,
            claimedStateRoot: claimedStateRoot,
            actualStateRoot: actualStateRoot,
            traceRoot: traceRoot,
            verifiedSteps: verifiedSteps,
            challenger: challenger,
            challengerWon: challengerWon,
            status: PureVMTypes.DisputeStatus.Resolved,
            resolvedAtBlock: uint64(block.number)
        });
        latestDisputeForCheckpoint[taskId][fromOrdinal] = disputeId;
        _registerDataAvailability(
            taskId,
            PureVMTypes.DataKind.Snapshot,
            toOrdinal,
            actualCheckpoint.snapshotBlobHash,
            actualCheckpoint.stateRoot,
            0,
            actualCheckpoint.snapshotURI,
            challenger,
            true
        );
        _registerDataAvailability(
            taskId,
            PureVMTypes.DataKind.Proof,
            fromOrdinal,
            keccak256(proofBytes),
            traceRoot,
            uint64(proofBytes.length),
            "",
            challenger,
            true
        );

        emit DisputeResolved(
            disputeId,
            taskId,
            fromOrdinal,
            toOrdinal,
            challenger,
            challengerWon,
            claimedResultHash,
            actualResultHash,
            claimedStateRoot,
            actualStateRoot,
            traceRoot
        );
    }

    function registerDataAvailability(
        bytes32 taskId,
        PureVMTypes.DataKind kind,
        uint32 ordinal,
        bytes32 dataHash,
        bytes32 semanticHash,
        uint64 size,
        string calldata uri,
        bool available
    ) external returns (bytes32 dataId) {
        if (!tasks[taskId].exists) revert InvalidTask();
        dataId =
            _registerDataAvailability(taskId, kind, ordinal, dataHash, semanticHash, size, uri, msg.sender, available);
    }

    function registerArtifactManifest(
        bytes32 taskId,
        uint32 checkpointOrdinal,
        bytes32 manifestHash,
        string calldata manifestURI
    ) external returns (bytes32 manifestId) {
        if (!tasks[taskId].exists) revert InvalidTask();
        manifestId = _registerArtifactManifest(taskId, checkpointOrdinal, manifestHash, manifestURI, msg.sender);
    }

    function setDataAvailabilityStatus(bytes32 dataId, bool available) external {
        PureVMTypes.DataAvailabilityMeta storage meta = dataAvailability[dataId];
        if (!meta.available && meta.publisher == address(0)) revert DataAvailabilityNotFound();
        PureVMTypes.TaskConfig storage task = tasks[meta.taskId];
        if (msg.sender != meta.publisher && msg.sender != task.owner) revert UnauthorizedDataAvailabilityUpdate();
        meta.available = available;
        emit DataAvailabilityStatusUpdated(dataId, available);
    }

    function challengeDataAvailability(bytes32 dataId) external returns (bytes32 challengeId) {
        PureVMTypes.DataAvailabilityMeta storage meta = dataAvailability[dataId];
        if (meta.publisher == address(0)) revert DataAvailabilityNotFound();

        bytes32 latestChallengeId = latestDataAvailabilityChallengeForData[dataId];
        if (latestChallengeId != bytes32(0)) {
            PureVMTypes.DataAvailabilityChallengeMeta storage latest = dataAvailabilityChallenges[latestChallengeId];
            if (latest.status == PureVMTypes.DataAvailabilityChallengeStatus.Open) {
                revert DataAvailabilityChallengeAlreadyOpen();
            }
        }

        challengeId = keccak256(
            abi.encode("PUREVM_DA_CHALLENGE", dataId, msg.sender, meta.publisher, block.number, latestChallengeId)
        );
        dataAvailabilityChallenges[challengeId] = PureVMTypes.DataAvailabilityChallengeMeta({
            dataId: dataId,
            taskId: meta.taskId,
            challenger: msg.sender,
            publisher: meta.publisher,
            openedAt: uint64(block.timestamp),
            deadline: uint64(block.timestamp + DATA_AVAILABILITY_CHALLENGE_WINDOW),
            challengerWon: false,
            status: PureVMTypes.DataAvailabilityChallengeStatus.Open
        });
        latestDataAvailabilityChallengeForData[dataId] = challengeId;
        meta.available = false;

        emit DataAvailabilityStatusUpdated(dataId, false);
        emit DataAvailabilityChallenged(
            challengeId, dataId, msg.sender, uint64(block.timestamp + DATA_AVAILABILITY_CHALLENGE_WINDOW)
        );
    }

    function resolveDataAvailabilityChallenge(bytes32 challengeId, string calldata uri) external {
        _validateUri("uri", uri);
        if (bytes(uri).length == 0) revert InvalidDataAvailability();

        PureVMTypes.DataAvailabilityChallengeMeta storage challenge = dataAvailabilityChallenges[challengeId];
        if (challenge.status != PureVMTypes.DataAvailabilityChallengeStatus.Open) {
            revert InvalidDataAvailabilityChallenge();
        }
        if (block.timestamp > challenge.deadline) revert DataAvailabilityChallengeExpired();

        PureVMTypes.TaskConfig storage task = tasks[challenge.taskId];
        if (msg.sender != challenge.publisher && msg.sender != task.owner) revert UnauthorizedDataAvailabilityUpdate();

        PureVMTypes.DataAvailabilityMeta storage meta = dataAvailability[challenge.dataId];
        meta.uri = uri;
        meta.available = true;
        challenge.status = PureVMTypes.DataAvailabilityChallengeStatus.ResolvedAvailable;

        emit DataAvailabilityStatusUpdated(challenge.dataId, true);
        emit DataAvailabilityChallengeResolved(challengeId, challenge.dataId, false, msg.sender, uri);
    }

    function resolveDataAvailabilityChallengeTimeout(bytes32 challengeId) external {
        PureVMTypes.DataAvailabilityChallengeMeta storage challenge = dataAvailabilityChallenges[challengeId];
        if (challenge.status != PureVMTypes.DataAvailabilityChallengeStatus.Open) {
            revert InvalidDataAvailabilityChallenge();
        }
        if (block.timestamp <= challenge.deadline) revert DataAvailabilityChallengeStillOpen();

        PureVMTypes.DataAvailabilityMeta storage meta = dataAvailability[challenge.dataId];
        meta.available = false;
        challenge.challengerWon = true;
        challenge.status = PureVMTypes.DataAvailabilityChallengeStatus.ResolvedUnavailable;

        emit DataAvailabilityStatusUpdated(challenge.dataId, false);
        emit DataAvailabilityChallengeResolved(challengeId, challenge.dataId, true, msg.sender, meta.uri);
    }

    function setChallengeResolverAuthorization(address resolver, bool authorized) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (resolver == address(0)) revert UnauthorizedChallengeResolver();
        authorizedChallengeResolvers[resolver] = authorized;
        emit ChallengeResolverAuthorizationUpdated(resolver, authorized);
    }

    function setVerifierApproval(address verifier, uint32 version, bool approved) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (verifier == address(0)) revert EmptyVerifier();
        if (approved && version == 0) revert InvalidVerifierVersion();
        if (version != 0) {
            verifierVersions[verifier] = version;
        }
        approvedVerifiers[verifier] = approved;
        emit VerifierApprovalUpdated(verifier, approved, verifierVersions[verifier]);
    }

    function createDisputeGame(PureVMTypes.DisputeGameCreation calldata creation)
        external
        payable
        returns (bytes32 gameId)
    {
        PureVMTypes.TaskConfig storage task = tasks[creation.taskId];
        if (!task.exists) revert InvalidTask();
        if (creation.executor == address(0) || creation.challenger == address(0)) revert InvalidDisputeGame();
        if (creation.executor == creation.challenger) revert InvalidDisputeGame();
        if (msg.sender != creation.executor && msg.sender != creation.challenger) revert UnauthorizedDisputeParty();
        if (creation.claimedStateRoot == bytes32(0) || creation.challengerStateRoot == bytes32(0)) {
            revert InvalidDisputeGame();
        }
        if (creation.claimedSnapshotBlobHash == bytes32(0) || creation.challengerSnapshotBlobHash == bytes32(0)) {
            revert InvalidDisputeGame();
        }
        if (creation.toOrdinal != creation.fromOrdinal + 1) revert InvalidOrdinal();
        if (creation.adjudicationThresholdGas == 0 || creation.adjudicationThresholdGas > task.snapshotThresholdGas) {
            revert InvalidThreshold();
        }
        if (creation.maxRounds == 0 || creation.maxRounds > MAX_DISPUTE_ROUNDS) revert InvalidDisputeGame();
        if (creation.roundDuration == 0 || creation.roundDuration > MAX_ROUND_DURATION) revert InvalidDisputeGame();
        if (creation.baseStake == 0) revert InvalidDisputeStake();
        if (creation.baseStake > (type(uint256).max >> (creation.maxRounds - 1))) revert InvalidDisputeStake();

        PureVMTypes.CheckpointMeta storage start = checkpoints[creation.taskId][creation.fromOrdinal];
        if (!start.exists || !start.verified) revert UnverifiedCheckpoint();
        if (creation.claimedStepNumber <= start.stepNumber || creation.claimedGasUsed <= start.gasUsed) {
            revert InvalidCheckpointProgression();
        }
        if (creation.claimedGasUsed > task.totalGas) revert InvalidGasAccounting();
        bool isFinal = creation.claimedGasUsed == task.totalGas;
        _validateThreshold(task, start, creation.claimedGasUsed, creation.claimedStepNumber, isFinal);

        gameId = keccak256(
            abi.encode(
                "PUREVM_DISPUTE_GAME",
                disputeGameNonce++,
                creation.taskId,
                creation.fromOrdinal,
                creation.toOrdinal,
                creation.executor,
                creation.challenger,
                creation.claimedResultHash,
                creation.claimedStateRoot,
                block.number
            )
        );

        disputeGames[gameId] = PureVMTypes.DisputeGame({
            taskId: creation.taskId,
            fromOrdinal: creation.fromOrdinal,
            toOrdinal: creation.toOrdinal,
            executor: creation.executor,
            challenger: creation.challenger,
            claimedResultHash: creation.claimedResultHash,
            claimedStateRoot: creation.claimedStateRoot,
            claimedSnapshotBlobHash: creation.claimedSnapshotBlobHash,
            claimedStepNumber: creation.claimedStepNumber,
            claimedGasUsed: creation.claimedGasUsed,
            adjudicationThresholdGas: creation.adjudicationThresholdGas,
            maxRounds: creation.maxRounds,
            currentRound: 0,
            roundDeadline: uint64(block.timestamp + creation.roundDuration),
            roundDuration: creation.roundDuration,
            baseStake: creation.baseStake,
            executorStake: 0,
            challengerStake: 0,
            executorSubdivisionRoot: bytes32(0),
            challengerSubdivisionRoot: bytes32(0),
            divergenceIndex: 0,
            commonRoot: start.stateRoot,
            executorRoot: creation.claimedStateRoot,
            challengerRoot: creation.challengerStateRoot,
            commonSnapshotBlobHash: start.snapshotBlobHash,
            executorSnapshotBlobHash: creation.claimedSnapshotBlobHash,
            challengerSnapshotBlobHash: creation.challengerSnapshotBlobHash,
            commonStep: start.stepNumber,
            targetStep: creation.claimedStepNumber,
            commonGasUsed: start.gasUsed,
            targetGasUsed: creation.claimedGasUsed,
            status: PureVMTypes.DisputeGameStatus.Staking,
            winner: PureVMTypes.DisputeWinner.None,
            resolvedAtBlock: 0
        });

        emit DisputeGameCreated(
            gameId,
            creation.taskId,
            creation.fromOrdinal,
            creation.toOrdinal,
            creation.executor,
            creation.challenger,
            creation.baseStake,
            creation.adjudicationThresholdGas
        );

        if (msg.value > 0) {
            _depositDisputeStake(gameId, msg.sender, msg.value);
        }
    }

    function depositDisputeStake(bytes32 gameId) external payable {
        _depositDisputeStake(gameId, msg.sender, msg.value);
    }

    function submitSubdivision(
        bytes32 gameId,
        PureVMTypes.SubdivisionCommitment[] calldata commitments,
        string calldata subdivisionURI
    ) external returns (bytes32 subdivisionRoot, bytes32 dataId) {
        _validateUri("subdivisionURI", subdivisionURI);

        PureVMTypes.DisputeGame storage game = disputeGames[gameId];
        if (game.status != PureVMTypes.DisputeGameStatus.Open) revert InvalidDisputeGame();
        _requireFundedRound(game);

        bool executorSide = msg.sender == game.executor;
        if (!executorSide && msg.sender != game.challenger) revert UnauthorizedDisputeParty();
        bytes32 expectedEndRoot = executorSide ? game.executorRoot : game.challengerRoot;
        bytes32 expectedEndBlob = executorSide ? game.executorSnapshotBlobHash : game.challengerSnapshotBlobHash;
        if (expectedEndRoot == bytes32(0) || expectedEndBlob == bytes32(0)) revert InvalidSubdivision();

        _validateSubdivisionSchedule(game, commitments, expectedEndRoot, expectedEndBlob);
        subdivisionRoot = subdivisionRootHash(commitments);

        bytes32 existingRoot = executorSide ? game.executorSubdivisionRoot : game.challengerSubdivisionRoot;
        if (existingRoot != bytes32(0)) revert InvalidSubdivision();

        if (executorSide) {
            delete executorSubdivisions[gameId];
            for (uint256 i = 0; i < commitments.length; i++) {
                executorSubdivisions[gameId].push(commitments[i]);
            }
            game.executorSubdivisionRoot = subdivisionRoot;
        } else {
            delete challengerSubdivisions[gameId];
            for (uint256 i = 0; i < commitments.length; i++) {
                challengerSubdivisions[gameId].push(commitments[i]);
            }
            game.challengerSubdivisionRoot = subdivisionRoot;
        }

        dataId = _registerDataAvailability(
            game.taskId,
            PureVMTypes.DataKind.Subdivision,
            uint32(game.currentRound),
            subdivisionRoot,
            keccak256(abi.encode(gameId, msg.sender, game.currentRound)),
            uint64(commitments.length),
            subdivisionURI,
            msg.sender,
            true
        );
        emit SubdivisionSubmitted(gameId, msg.sender, game.currentRound, subdivisionRoot, dataId, commitments.length);
    }

    function declareDivergence(bytes32 gameId, uint32 divergenceIndex) external {
        PureVMTypes.DisputeGame storage game = disputeGames[gameId];
        if (game.status != PureVMTypes.DisputeGameStatus.Open) revert InvalidDisputeGame();
        if (msg.sender != game.executor && msg.sender != game.challenger) revert UnauthorizedDisputeParty();
        if (game.executorSubdivisionRoot == bytes32(0) || game.challengerSubdivisionRoot == bytes32(0)) {
            revert InvalidSubdivision();
        }

        PureVMTypes.SubdivisionCommitment[] storage exec = executorSubdivisions[gameId];
        PureVMTypes.SubdivisionCommitment[] storage chal = challengerSubdivisions[gameId];
        if (exec.length != chal.length || divergenceIndex == 0 || divergenceIndex >= exec.length) {
            revert SubdivisionScheduleMismatch();
        }

        for (uint256 i = 0; i < exec.length; i++) {
            if (
                exec[i].index != chal[i].index || exec[i].stepNumber != chal[i].stepNumber
                    || exec[i].gasUsed != chal[i].gasUsed
            ) {
                revert SubdivisionScheduleMismatch();
            }
            if (i < divergenceIndex) {
                if (exec[i].stateRoot != chal[i].stateRoot) revert NoDivergence();
                if (exec[i].snapshotBlobHash != chal[i].snapshotBlobHash) revert NoDivergence();
            }
        }
        if (exec[divergenceIndex].stateRoot == chal[divergenceIndex].stateRoot) revert NoDivergence();

        uint256 prevIndex = uint256(divergenceIndex) - 1;
        game.divergenceIndex = divergenceIndex;
        game.commonRoot = exec[prevIndex].stateRoot;
        game.executorRoot = exec[divergenceIndex].stateRoot;
        game.challengerRoot = chal[divergenceIndex].stateRoot;
        game.commonSnapshotBlobHash = exec[prevIndex].snapshotBlobHash;
        game.executorSnapshotBlobHash = exec[divergenceIndex].snapshotBlobHash;
        game.challengerSnapshotBlobHash = chal[divergenceIndex].snapshotBlobHash;
        game.commonStep = exec[prevIndex].stepNumber;
        game.targetStep = exec[divergenceIndex].stepNumber;
        game.commonGasUsed = exec[prevIndex].gasUsed;
        game.targetGasUsed = exec[divergenceIndex].gasUsed;

        uint64 segmentGas = game.targetGasUsed - game.commonGasUsed;
        bool ready = segmentGas <= game.adjudicationThresholdGas || game.currentRound + 1 >= game.maxRounds;
        emit DivergenceDeclared(
            gameId, game.currentRound, divergenceIndex, game.commonRoot, game.executorRoot, game.challengerRoot, ready
        );

        delete executorSubdivisions[gameId];
        delete challengerSubdivisions[gameId];
        game.executorSubdivisionRoot = bytes32(0);
        game.challengerSubdivisionRoot = bytes32(0);

        if (ready) {
            game.status = PureVMTypes.DisputeGameStatus.ReadyForFinal;
            return;
        }

        game.currentRound += 1;
        game.status = PureVMTypes.DisputeGameStatus.Staking;
        game.roundDeadline = uint64(block.timestamp + game.roundDuration);
        emit DisputeRoundAdvanced(gameId, game.currentRound, game.commonGasUsed, game.targetGasUsed);
        if (_isRoundFunded(game)) {
            game.status = PureVMTypes.DisputeGameStatus.Open;
            emit DisputeRoundFunded(gameId, game.currentRound, requiredStakeForRound(gameId));
        }
    }

    function resolveDisputeGameWithProof(
        bytes32 gameId,
        PureVMTypes.CheckpointInput calldata actualCheckpoint,
        bytes calldata startSnapshotBytes,
        bytes calldata proofBytes
    ) external returns (PureVMTypes.DisputeWinner winner, bytes32 actualResultHash, bytes32 actualStateRoot) {
        _validatePayloadLimits(startSnapshotBytes.length, proofBytes.length);
        _validateUri("snapshotURI", actualCheckpoint.snapshotURI);

        PureVMTypes.DisputeGame storage game = disputeGames[gameId];
        if (game.status != PureVMTypes.DisputeGameStatus.ReadyForFinal) revert DisputeNotReadyForFinal();
        if (keccak256(startSnapshotBytes) != game.commonSnapshotBlobHash) revert StartSnapshotHashMismatch();
        if (actualCheckpoint.stepNumber != game.targetStep || actualCheckpoint.gasUsed != game.targetGasUsed) {
            revert InvalidCheckpointProgression();
        }

        PureVMTypes.TaskConfig storage task = tasks[game.taskId];
        if (!task.exists) revert InvalidTask();
        if (actualCheckpoint.gasUsed + actualCheckpoint.gasRemaining != task.totalGas) revert InvalidGasAccounting();

        uint64 expectedSteps = game.targetStep - game.commonStep;
        (bool valid, bytes32 initialRoot, bytes32 finalRoot, uint64 steps, bytes32 traceRoot) = IPureVMVerifier(
            task.verifier
        ).verifyTransitionDetailed(
            startSnapshotBytes, proofBytes, actualCheckpoint.stateRoot, expectedSteps, bytes32(0)
        );
        if (!valid) revert VerificationFailed();
        if (initialRoot != bytes32(0) && initialRoot != game.commonRoot) {
            revert StartRootMismatch(initialRoot, game.commonRoot);
        }
        if (steps != expectedSteps) revert VerifiedStepsMismatch(steps, expectedSteps);
        if (finalRoot != actualCheckpoint.stateRoot) revert FinalRootMismatch(finalRoot, actualCheckpoint.stateRoot);

        actualStateRoot = finalRoot;
        actualResultHash = checkpointClaimHash(game.taskId, game.toOrdinal, actualCheckpoint);
        if (actualStateRoot == game.executorRoot && actualStateRoot != game.challengerRoot) {
            winner = PureVMTypes.DisputeWinner.Executor;
        } else if (actualStateRoot == game.challengerRoot && actualStateRoot != game.executorRoot) {
            winner = PureVMTypes.DisputeWinner.Challenger;
        } else {
            winner = PureVMTypes.DisputeWinner.BothWrong;
        }
        if (winner == PureVMTypes.DisputeWinner.Executor) {
            if (actualCheckpoint.snapshotBlobHash != game.executorSnapshotBlobHash) {
                revert InvalidCheckpointProgression();
            }
        } else if (winner == PureVMTypes.DisputeWinner.Challenger) {
            if (actualCheckpoint.snapshotBlobHash != game.challengerSnapshotBlobHash) {
                revert InvalidCheckpointProgression();
            }
        }

        _registerDataAvailability(
            game.taskId,
            PureVMTypes.DataKind.Proof,
            game.fromOrdinal,
            keccak256(proofBytes),
            traceRoot,
            uint64(proofBytes.length),
            "",
            msg.sender,
            true
        );
        _settleDisputeGame(gameId, game, winner, actualStateRoot, traceRoot);
    }

    function resolveDisputeTimeout(bytes32 gameId) external returns (PureVMTypes.DisputeWinner winner) {
        PureVMTypes.DisputeGame storage game = disputeGames[gameId];
        if (game.status != PureVMTypes.DisputeGameStatus.Staking) revert InvalidDisputeGame();
        if (block.timestamp <= game.roundDeadline) revert DisputeTimeoutUnavailable();

        uint256 required = _requiredStakeForRound(game);
        bool executorFunded = game.executorStake >= required;
        bool challengerFunded = game.challengerStake >= required;
        if (executorFunded == challengerFunded) {
            winner = PureVMTypes.DisputeWinner.BothWrong;
        } else if (executorFunded) {
            winner = PureVMTypes.DisputeWinner.Executor;
        } else {
            winner = PureVMTypes.DisputeWinner.Challenger;
        }
        _settleDisputeGame(gameId, game, winner, bytes32(0), bytes32(0));
    }

    function _depositDisputeStake(bytes32 gameId, address party, uint256 amount) internal {
        PureVMTypes.DisputeGame storage game = disputeGames[gameId];
        if (game.status == PureVMTypes.DisputeGameStatus.None) revert InvalidDisputeGame();
        if (game.status == PureVMTypes.DisputeGameStatus.Resolved) revert DisputeGameAlreadyResolved();
        if (game.status != PureVMTypes.DisputeGameStatus.Staking && game.status != PureVMTypes.DisputeGameStatus.Open) {
            revert InvalidDisputeGame();
        }
        if (amount == 0) revert InvalidDisputeStake();

        bool executorSide = party == game.executor;
        if (!executorSide && party != game.challenger) revert UnauthorizedDisputeParty();

        uint256 totalStake;
        if (executorSide) {
            game.executorStake += amount;
            totalStake = game.executorStake;
        } else {
            game.challengerStake += amount;
            totalStake = game.challengerStake;
        }
        emit DisputeStakeDeposited(gameId, party, game.currentRound, amount, totalStake);

        if (_isRoundFunded(game)) {
            game.status = PureVMTypes.DisputeGameStatus.Open;
            emit DisputeRoundFunded(gameId, game.currentRound, _requiredStakeForRound(game));
        }
    }

    function _registerDataAvailability(
        bytes32 taskId,
        PureVMTypes.DataKind kind,
        uint32 ordinal,
        bytes32 dataHash,
        bytes32 semanticHash,
        uint64 size,
        string memory uri,
        address publisher,
        bool available
    ) internal returns (bytes32 dataId) {
        if (kind == PureVMTypes.DataKind.Unknown || dataHash == bytes32(0) || publisher == address(0)) {
            revert InvalidDataAvailability();
        }
        _validateUri("uri", uri);

        dataId = dataAvailabilityId(taskId, kind, ordinal, dataHash, semanticHash);
        PureVMTypes.DataAvailabilityMeta storage existing = dataAvailability[dataId];
        if (existing.publisher != address(0)) {
            if (existing.size != 0 && size != 0 && existing.size != size) {
                revert DataAvailabilityAlreadyRegistered();
            }
            existing.available = existing.available || available;
            return dataId;
        }

        dataAvailability[dataId] = PureVMTypes.DataAvailabilityMeta({
            taskId: taskId,
            kind: kind,
            ordinal: ordinal,
            dataHash: dataHash,
            semanticHash: semanticHash,
            size: size,
            uri: uri,
            publisher: publisher,
            registeredAtBlock: uint64(block.number),
            available: available
        });
        taskDataAvailabilityIds[taskId].push(dataId);

        emit DataAvailabilityRegistered(dataId, taskId, kind, ordinal, dataHash, semanticHash, size, uri, publisher);
    }

    function _registerArtifactManifest(
        bytes32 taskId,
        uint32 checkpointOrdinal,
        bytes32 manifestHash,
        string memory manifestURI,
        address publisher
    ) internal returns (bytes32 manifestId) {
        if (manifestHash == bytes32(0) || publisher == address(0)) revert InvalidDataAvailability();
        _validateUri("manifestURI", manifestURI);

        manifestId = artifactManifestId(taskId, checkpointOrdinal, manifestHash);
        bytes32 existingForCheckpoint = checkpointArtifactManifestIds[taskId][checkpointOrdinal];
        if (existingForCheckpoint != bytes32(0) && existingForCheckpoint != manifestId) {
            revert DataAvailabilityAlreadyRegistered();
        }

        PureVMTypes.ArtifactManifestMeta storage existing = artifactManifests[manifestId];
        if (existing.exists) {
            return manifestId;
        }

        artifactManifests[manifestId] = PureVMTypes.ArtifactManifestMeta({
            taskId: taskId,
            checkpointOrdinal: checkpointOrdinal,
            manifestHash: manifestHash,
            manifestURI: manifestURI,
            publisher: publisher,
            registeredAtBlock: uint64(block.number),
            exists: true
        });
        checkpointArtifactManifestIds[taskId][checkpointOrdinal] = manifestId;
        _registerDataAvailability(
            taskId,
            PureVMTypes.DataKind.Manifest,
            checkpointOrdinal,
            manifestHash,
            keccak256(abi.encode(taskId, checkpointOrdinal)),
            uint64(bytes(manifestURI).length),
            manifestURI,
            publisher,
            bytes(manifestURI).length > 0
        );

        emit ArtifactManifestRegistered(manifestId, taskId, checkpointOrdinal, manifestHash, manifestURI, publisher);
    }

    function _validatePayloadLimits(uint256 snapshotSize, uint256 proofSize) internal pure {
        if (snapshotSize > MAX_DIRECT_SNAPSHOT_BYTES) {
            revert InterfaceLimitExceeded("snapshotBytes", snapshotSize, MAX_DIRECT_SNAPSHOT_BYTES);
        }
        if (proofSize > MAX_PROOF_BYTES) {
            revert InterfaceLimitExceeded("proofBytes", proofSize, MAX_PROOF_BYTES);
        }
    }

    function _validateUri(string memory field, string memory uri) internal pure {
        uint256 size = bytes(uri).length;
        if (size > MAX_URI_BYTES) revert InterfaceLimitExceeded(field, size, MAX_URI_BYTES);
    }

    function _requireFundedRound(PureVMTypes.DisputeGame storage game) internal view {
        uint256 required = _requiredStakeForRound(game);
        if (game.executorStake < required || game.challengerStake < required) {
            revert DisputeRoundNotFunded(game.currentRound, game.executorStake, game.challengerStake, required);
        }
    }

    function _isRoundFunded(PureVMTypes.DisputeGame storage game) internal view returns (bool) {
        uint256 required = _requiredStakeForRound(game);
        return game.executorStake >= required && game.challengerStake >= required;
    }

    function _requiredStakeForRound(PureVMTypes.DisputeGame storage game) internal view returns (uint256) {
        return game.baseStake << game.currentRound;
    }

    function _validateSubdivisionSchedule(
        PureVMTypes.DisputeGame storage game,
        PureVMTypes.SubdivisionCommitment[] calldata commitments,
        bytes32 expectedEndRoot,
        bytes32 expectedEndBlob
    ) internal view {
        uint256 count = commitments.length;
        if (count < 2 || count > MAX_SUBDIVISION_COMMITMENTS) revert InvalidSubdivision();
        if (commitments[0].index != 0) revert SubdivisionScheduleMismatch();
        if (commitments[0].stepNumber != game.commonStep || commitments[0].gasUsed != game.commonGasUsed) {
            revert SubdivisionScheduleMismatch();
        }
        if (commitments[0].stateRoot != game.commonRoot) revert SubdivisionScheduleMismatch();
        if (commitments[0].snapshotBlobHash != game.commonSnapshotBlobHash) revert SubdivisionScheduleMismatch();

        for (uint256 i = 1; i < count; i++) {
            if (commitments[i].index != i) revert SubdivisionScheduleMismatch();
            if (commitments[i].stepNumber <= commitments[i - 1].stepNumber) revert SubdivisionScheduleMismatch();
            if (commitments[i].gasUsed <= commitments[i - 1].gasUsed) revert SubdivisionScheduleMismatch();
            if (commitments[i].gasUsed > game.targetGasUsed || commitments[i].stepNumber > game.targetStep) {
                revert SubdivisionScheduleMismatch();
            }
        }

        PureVMTypes.SubdivisionCommitment calldata last = commitments[count - 1];
        if (last.stepNumber != game.targetStep || last.gasUsed != game.targetGasUsed) {
            revert SubdivisionScheduleMismatch();
        }
        if (last.stateRoot != expectedEndRoot || last.snapshotBlobHash != expectedEndBlob) {
            revert SubdivisionScheduleMismatch();
        }
    }

    function _settleDisputeGame(
        bytes32 gameId,
        PureVMTypes.DisputeGame storage game,
        PureVMTypes.DisputeWinner winner,
        bytes32 actualStateRoot,
        bytes32 traceRoot
    ) internal {
        if (game.status == PureVMTypes.DisputeGameStatus.Resolved) revert DisputeGameAlreadyResolved();

        game.status = PureVMTypes.DisputeGameStatus.Resolved;
        game.winner = winner;
        game.resolvedAtBlock = uint64(block.number);

        uint256 payout = game.executorStake + game.challengerStake;
        game.executorStake = 0;
        game.challengerStake = 0;

        if (winner == PureVMTypes.DisputeWinner.Executor) {
            (bool okExecutor,) = payable(game.executor).call{value: payout}("");
            require(okExecutor, "executor dispute payout failed");
        } else if (winner == PureVMTypes.DisputeWinner.Challenger) {
            (bool okChallenger,) = payable(game.challenger).call{value: payout}("");
            require(okChallenger, "challenger dispute payout failed");
        } else if (payout > 0) {
            uint256 executorRefund = payout / 2;
            uint256 challengerRefund = payout - executorRefund;
            (bool okExecutor,) = payable(game.executor).call{value: executorRefund}("");
            require(okExecutor, "executor dispute refund failed");
            (bool okChallenger,) = payable(game.challenger).call{value: challengerRefund}("");
            require(okChallenger, "challenger dispute refund failed");
        }

        emit DisputeGameResolved(gameId, game.taskId, winner, actualStateRoot, traceRoot, payout);
    }

    function getTask(bytes32 taskId) external view returns (PureVMTypes.TaskConfig memory) {
        return tasks[taskId];
    }

    function getCheckpoint(bytes32 taskId, uint32 ordinal) external view returns (PureVMTypes.CheckpointMeta memory) {
        return checkpoints[taskId][ordinal];
    }

    function getAdjacentProof(bytes32 taskId, uint32 fromOrdinal)
        external
        view
        returns (PureVMTypes.AdjacentProofMeta memory)
    {
        return adjacentProofs[taskId][fromOrdinal];
    }

    function getDispute(bytes32 disputeId) external view returns (PureVMTypes.DisputeMeta memory) {
        return disputes[disputeId];
    }

    function getLatestDisputeForCheckpoint(bytes32 taskId, uint32 fromOrdinal) external view returns (bytes32) {
        return latestDisputeForCheckpoint[taskId][fromOrdinal];
    }

    function getDataAvailability(bytes32 dataId) external view returns (PureVMTypes.DataAvailabilityMeta memory) {
        return dataAvailability[dataId];
    }

    function getTaskDataAvailabilityIds(bytes32 taskId) external view returns (bytes32[] memory) {
        return taskDataAvailabilityIds[taskId];
    }

    function getDataAvailabilityChallenge(bytes32 challengeId)
        external
        view
        returns (PureVMTypes.DataAvailabilityChallengeMeta memory)
    {
        return dataAvailabilityChallenges[challengeId];
    }

    function getLatestDataAvailabilityChallengeForData(bytes32 dataId) external view returns (bytes32) {
        return latestDataAvailabilityChallengeForData[dataId];
    }

    function getArtifactManifest(bytes32 manifestId)
        external
        view
        returns (PureVMTypes.ArtifactManifestMeta memory)
    {
        return artifactManifests[manifestId];
    }

    function getCheckpointArtifactManifestId(bytes32 taskId, uint32 checkpointOrdinal) external view returns (bytes32) {
        return checkpointArtifactManifestIds[taskId][checkpointOrdinal];
    }

    function getDisputeGame(bytes32 gameId) external view returns (PureVMTypes.DisputeGame memory) {
        return disputeGames[gameId];
    }

    function getExecutorSubdivision(bytes32 gameId)
        external
        view
        returns (PureVMTypes.SubdivisionCommitment[] memory)
    {
        return executorSubdivisions[gameId];
    }

    function getChallengerSubdivision(bytes32 gameId)
        external
        view
        returns (PureVMTypes.SubdivisionCommitment[] memory)
    {
        return challengerSubdivisions[gameId];
    }

    function getLatestVerifiedOrdinal(bytes32 taskId) external view returns (uint32) {
        return tasks[taskId].latestVerifiedOrdinal;
    }

    function isStateRootVerified(bytes32 taskId, bytes32 stateRoot) external view returns (bool) {
        return verifiedRoots[taskId][stateRoot];
    }

    function computeTaskId(
        address taskOwner,
        uint256 nonce,
        bytes32 codeHash,
        uint64 totalGas,
        uint64 snapshotThresholdGas,
        bytes32 initialStateRoot
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(taskOwner, nonce, codeHash, totalGas, snapshotThresholdGas, initialStateRoot));
    }

    function checkpointTaskSummaryHash(bytes32 taskId, uint32 checkpointOrdinal) public pure returns (bytes32) {
        return keccak256(abi.encode("PUREVM_CHECKPOINT_TASK", taskId, checkpointOrdinal));
    }

    function checkpointClaimHash(bytes32 taskId, uint32 ordinal, PureVMTypes.CheckpointInput memory checkpoint)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                "PUREVM_CHECKPOINT_CLAIM",
                taskId,
                ordinal,
                checkpoint.stepNumber,
                checkpoint.gasUsed,
                checkpoint.gasRemaining,
                checkpoint.stateRoot,
                checkpoint.snapshotBlobHash,
                checkpoint.snapshotURI
            )
        );
    }

    function dataAvailabilityId(
        bytes32 taskId,
        PureVMTypes.DataKind kind,
        uint32 ordinal,
        bytes32 dataHash,
        bytes32 semanticHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode("PUREVM_DA", taskId, kind, ordinal, dataHash, semanticHash));
    }

    function artifactManifestId(bytes32 taskId, uint32 checkpointOrdinal, bytes32 manifestHash)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("PUREVM_ARTIFACT_MANIFEST", taskId, checkpointOrdinal, manifestHash));
    }

    function checkpointArtifactManifestHash(
        bytes32 taskId,
        uint32 fromOrdinal,
        uint32 toOrdinal,
        bytes32 startSnapshotBlobHash,
        bytes32 endSnapshotBlobHash,
        bytes32 proofBlobHash,
        bytes32 semanticHash,
        string memory snapshotURI,
        string memory proofURI
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "PUREVM_CHECKPOINT_ARTIFACTS",
                taskId,
                fromOrdinal,
                toOrdinal,
                startSnapshotBlobHash,
                endSnapshotBlobHash,
                proofBlobHash,
                semanticHash,
                snapshotURI,
                proofURI
            )
        );
    }

    function subdivisionRootHash(PureVMTypes.SubdivisionCommitment[] calldata commitments)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("PUREVM_SUBDIVISION", commitments));
    }

    function requiredStakeForRound(bytes32 gameId) public view returns (uint256) {
        PureVMTypes.DisputeGame storage game = disputeGames[gameId];
        if (game.status == PureVMTypes.DisputeGameStatus.None) revert InvalidDisputeGame();
        return _requiredStakeForRound(game);
    }

    function validateAdjacentThreshold(
        bytes32 taskId,
        uint32 fromOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint
    ) external view returns (bool) {
        PureVMTypes.TaskConfig storage task = tasks[taskId];
        if (!task.exists) revert InvalidTask();
        PureVMTypes.CheckpointMeta storage start = checkpoints[taskId][fromOrdinal];
        if (!start.exists || !start.verified) revert UnverifiedCheckpoint();
        bool isFinal = nextCheckpoint.gasUsed == task.totalGas;
        _validateThreshold(task, start, nextCheckpoint.gasUsed, nextCheckpoint.stepNumber, isFinal);
        return true;
    }

    function _validateCheckpointProgression(
        PureVMTypes.TaskConfig storage task,
        PureVMTypes.CheckpointMeta storage start,
        uint32 nextOrdinal,
        PureVMTypes.CheckpointInput calldata nextCheckpoint
    ) internal view {
        if (nextCheckpoint.stepNumber <= start.stepNumber) revert InvalidCheckpointProgression();
        if (nextCheckpoint.gasUsed <= start.gasUsed) revert InvalidCheckpointProgression();
        if (nextCheckpoint.gasUsed + nextCheckpoint.gasRemaining != task.totalGas) revert InvalidGasAccounting();
        if (nextOrdinal != start.ordinal + 1) revert InvalidOrdinal();

        bool isFinal = nextCheckpoint.gasUsed == task.totalGas;
        _validateThreshold(task, start, nextCheckpoint.gasUsed, nextCheckpoint.stepNumber, isFinal);
    }

    function _validateThreshold(
        PureVMTypes.TaskConfig storage task,
        PureVMTypes.CheckpointMeta storage start,
        uint64 endGasUsed,
        uint64 endStepNumber,
        bool isFinal
    ) internal view {
        if (endStepNumber <= start.stepNumber) revert InvalidCheckpointProgression();
        if (endGasUsed <= start.gasUsed) revert InvalidCheckpointProgression();

        if (isFinal) {
            return;
        }

        uint64 segmentGasUsed = endGasUsed - start.gasUsed;
        if (segmentGasUsed > task.snapshotThresholdGas) {
            revert SegmentGasThresholdExceeded(segmentGasUsed, task.snapshotThresholdGas);
        }
    }
}
