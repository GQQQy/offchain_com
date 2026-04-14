// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract ValidatorManager {
    struct ValidatorInfo {
        uint256 activeStake;
        uint256 pendingWithdrawal;
        uint64 withdrawalAvailableAt;
        bool exists;
    }

    uint256 public immutable minimumStake;
    uint64 public immutable unstakeDelay;

    mapping(address => ValidatorInfo) public validators;
    address[] private validatorSet;

    error StakeTooSmall();
    error ValidatorUnknown();
    error InsufficientStake();
    error WithdrawalNotReady();
    error NoPendingWithdrawal();

    event ValidatorStaked(address indexed validator, uint256 amount, uint256 totalActiveStake);
    event ValidatorUnstakeRequested(address indexed validator, uint256 amount, uint64 availableAt);
    event ValidatorWithdrawalCompleted(address indexed validator, uint256 amount);

    constructor(uint256 minimumStake_, uint64 unstakeDelay_) {
        minimumStake = minimumStake_;
        unstakeDelay = unstakeDelay_;
    }

    function stake() external payable {
        if (msg.value == 0) revert StakeTooSmall();

        ValidatorInfo storage info = validators[msg.sender];
        if (!info.exists) {
            info.exists = true;
            validatorSet.push(msg.sender);
        }
        info.activeStake += msg.value;

        emit ValidatorStaked(msg.sender, msg.value, info.activeStake);
    }

    function requestUnstake(uint256 amount) external {
        ValidatorInfo storage info = validators[msg.sender];
        if (!info.exists) revert ValidatorUnknown();
        if (amount == 0 || info.activeStake < amount) revert InsufficientStake();

        info.activeStake -= amount;
        info.pendingWithdrawal += amount;
        info.withdrawalAvailableAt = uint64(block.timestamp + unstakeDelay);

        emit ValidatorUnstakeRequested(msg.sender, amount, info.withdrawalAvailableAt);
    }

    function finalizeUnstake() external {
        ValidatorInfo storage info = validators[msg.sender];
        if (!info.exists) revert ValidatorUnknown();
        if (info.pendingWithdrawal == 0) revert NoPendingWithdrawal();
        if (block.timestamp < info.withdrawalAvailableAt) revert WithdrawalNotReady();

        uint256 amount = info.pendingWithdrawal;
        info.pendingWithdrawal = 0;
        info.withdrawalAvailableAt = 0;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");

        emit ValidatorWithdrawalCompleted(msg.sender, amount);
    }

    function isEligible(address validator) public view returns (bool) {
        ValidatorInfo storage info = validators[validator];
        return info.exists && info.activeStake >= minimumStake;
    }

    function activeStakeOf(address validator) external view returns (uint256) {
        return validators[validator].activeStake;
    }

    function getEligibleValidators() public view returns (address[] memory eligible) {
        uint256 count = 0;
        for (uint256 i = 0; i < validatorSet.length; i++) {
            if (isEligible(validatorSet[i])) {
                count++;
            }
        }

        eligible = new address[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < validatorSet.length; i++) {
            address validator = validatorSet[i];
            if (isEligible(validator)) {
                eligible[cursor++] = validator;
            }
        }
    }

    function selectValidators(bytes32 seed, uint32 count) external view returns (address[] memory selected) {
        address[] memory eligible = getEligibleValidators();
        if (eligible.length == 0 || count == 0) {
            return new address[](0);
        }

        uint256 actualCount = count;
        if (actualCount > eligible.length) {
            actualCount = eligible.length;
        }

        uint256[] memory weights = new uint256[](eligible.length);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < eligible.length; i++) {
            uint256 weight = validators[eligible[i]].activeStake;
            weights[i] = weight;
            totalWeight += weight;
        }

        selected = new address[](actualCount);
        uint256 cursor = 0;
        uint256 nonce = 0;

        while (cursor < actualCount) {
            uint256 target = uint256(keccak256(abi.encode(seed, nonce))) % totalWeight;
            nonce++;

            uint256 cumulative = 0;
            uint256 index = 0;
            for (uint256 i = 0; i < eligible.length; i++) {
                uint256 weight = weights[i];
                if (weight == 0) {
                    continue;
                }
                cumulative += weight;
                if (target < cumulative) {
                    index = i;
                    break;
                }
            }

            selected[cursor++] = eligible[index];
            totalWeight -= weights[index];
            weights[index] = 0;
        }
    }

    function validatorCount() external view returns (uint256) {
        return validatorSet.length;
    }
}
