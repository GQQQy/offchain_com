// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPureVMSnapshotStore {
    function uploadSnapshot(bytes32 taskId, uint32 ordinal, bytes calldata snapshotBytes) external;
    function deleteSnapshot(bytes32 taskId, uint32 ordinal) external;
    function getSnapshot(bytes32 taskId, uint32 ordinal) external view returns (bytes memory);
    function getSnapshotHash(bytes32 taskId, uint32 ordinal) external view returns (bytes32);
    function hasSnapshot(bytes32 taskId, uint32 ordinal) external view returns (bool);
}
