// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title PureVM Snapshot Registry
 * @notice 用于链上验证PureVM执行快照的注册表合约
 * @dev 配合预编译合约0x0d0d使用
 */
contract SnapshotRegistry {
    
    // 预编译合约地址（在部署时初始化）
    address public constant VALIDATOR = address(0x0000000000000000000000000000000000000d0d);
    
    struct Checkpoint {
        bytes32 stateRoot;
        bytes stateData;      // 可选：存储完整状态数据（昂贵，建议存储链下）
        uint64 stepNumber;
        uint64 timestamp;
        bool verified;
    }
    
    // stepNumber => Checkpoint
    mapping(uint64 => Checkpoint) public checkpoints;
    
    // stateRoot => bool（快速查询是否已验证）
    mapping(bytes32 => bool) public verifiedRoots;
    
    // 事件
    event CheckpointRegistered(uint64 indexed stepNumber, bytes32 indexed stateRoot, uint64 gasUsed);
    event TransitionProven(uint64 indexed fromStep, uint64 indexed toStep, bytes32 indexed finalRoot);
    
    error InvalidTransition();
    error CheckpointExists();
    error InvalidInitialState();
    
    /**
     * @notice 注册初始检查点（step 0）
     * @param stateData 序列化的初始VM状态
     * @param stateRoot 状态哈希（必须匹配keccak256(stateData)）
     */
    function registerInitialCheckpoint(bytes calldata stateData, bytes32 stateRoot) external {
        if (checkpoints[0].timestamp != 0) revert CheckpointExists();
        
        // 验证提供的哈希与数据匹配
        require(keccak256(stateData) == stateRoot, "Hash mismatch");
        
        checkpoints[0] = Checkpoint({
            stateRoot: stateRoot,
            stateData: stateData,
            stepNumber: 0,
            timestamp: uint64(block.timestamp),
            verified: true
        });
        
        verifiedRoots[stateRoot] = true;
        emit CheckpointRegistered(0, stateRoot, 0);
    }
    
    /**
     * @notice 提交并验证状态转移证明
     * @param fromStep 起始步骤（必须已验证）
     * @param toStep 目标步骤
     * @param proofData 转移证明（JSON序列化）
     * @param expectedFinalRoot 期望的最终状态根
     * @param traceRoot 执行轨迹的Merkle根（可选验证）
     */
    function submitTransitionProof(
        uint64 fromStep,
        uint64 toStep,
        bytes calldata proofData,
        bytes32 expectedFinalRoot,
        bytes32 traceRoot
    ) external returns (bool) {
        Checkpoint storage start = checkpoints[fromStep];
        if (!start.verified) revert InvalidInitialState();
        if (checkpoints[toStep].timestamp != 0) revert CheckpointExists();
        
        uint64 steps = toStep - fromStep;
        
        // 构造预编译合约输入
        bytes memory input = abi.encodePacked(
            steps,
            start.stateRoot,
            expectedFinalRoot,
            keccak256(start.stateData), // codeHash，应从状态中正确提取
            traceRoot,
            proofData
        );
        
        // 调用预编译验证
        (bool success, bytes memory output) = VALIDATOR.staticcall(input);
        require(success, "Precompile call failed");
        
        bool valid = abi.decode(output, (uint256)) == 1;
        if (!valid) revert InvalidTransition();
        
        // 存储新的检查点
        checkpoints[toStep] = Checkpoint({
            stateRoot: expectedFinalRoot,
            stateData: "", // 不存储完整数据以节省gas，可通过事件或链下获取
            stepNumber: toStep,
            timestamp: uint64(block.timestamp),
            verified: true
        });
        
        verifiedRoots[expectedFinalRoot] = true;
        
        emit TransitionProven(fromStep, toStep, expectedFinalRoot);
        return true;
    }
    
    /**
     * @notice 批量验证连续转移（A->B->C）
     * @param stepSequence 步骤序列 [0, 100, 200]
     * @param proofs 相邻步骤间的证明数组（长度=stepSequence.length-1）
     * @param traceRoots 对应的轨迹根数组
     */
    function batchVerify(
        uint64[] calldata stepSequence,
        bytes[] calldata proofs,
        bytes32[] calldata traceRoots
    ) external {
        require(stepSequence.length > 1, "Need at least 2 steps");
        require(stepSequence.length == proofs.length + 1, "Proof count mismatch");
        require(stepSequence.length == traceRoots.length + 1, "Trace root count mismatch");
        
        for (uint i = 0; i < proofs.length; i++) {
            submitTransitionProof(
                stepSequence[i],
                stepSequence[i+1],
                proofs[i],
                checkpoints[stepSequence[i+1]].stateRoot, // 假设已预计算或存储
                traceRoots[i]
            );
        }
    }
    
    /**
     * @notice 检查状态根是否已被验证
     */
    function isVerified(bytes32 stateRoot) external view returns (bool) {
        return verifiedRoots[stateRoot];
    }
    
    /**
     * @notice 获取检查点数据（用于链下恢复执行）
     */
    function getCheckpointData(uint64 step) external view returns (bytes memory) {
        return checkpoints[step].stateData;
    }
    
    /**
     * @notice 获取最新已验证的步骤号
     */
    function getLatestStep() external view returns (uint64) {
        uint64 step = 0;
        while (checkpoints[step + 1].verified) {
            step++;
            if (step > 1e9) break; // 防止无限循环
        }
        return step;
    }
}