// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPureVMSnapshotStore} from "./interfaces/IPureVMSnapshotStore.sol";

contract PureVMSnapshotStore is IPureVMSnapshotStore {
    struct SnapshotBlob {
        address uploader;
        bytes32 blobHash;
        bytes data;
        bool exists;
    }

    mapping(bytes32 => mapping(uint32 => SnapshotBlob)) private blobs;

    error SnapshotAlreadyExists();
    error SnapshotNotFound();
    error UnauthorizedSnapshotDelete();

    event SnapshotUploaded(bytes32 indexed taskId, uint32 indexed ordinal, bytes32 blobHash, uint256 size);
    event SnapshotDeleted(bytes32 indexed taskId, uint32 indexed ordinal, bytes32 blobHash);

    function uploadSnapshot(bytes32 taskId, uint32 ordinal, bytes calldata snapshotBytes) external override {
        SnapshotBlob storage blob = blobs[taskId][ordinal];
        if (blob.exists) revert SnapshotAlreadyExists();

        bytes32 blobHash = keccak256(snapshotBytes);
        blobs[taskId][ordinal] = SnapshotBlob({
            uploader: msg.sender,
            blobHash: blobHash,
            data: snapshotBytes,
            exists: true
        });

        emit SnapshotUploaded(taskId, ordinal, blobHash, snapshotBytes.length);
    }

    function deleteSnapshot(bytes32 taskId, uint32 ordinal) external override {
        SnapshotBlob storage blob = blobs[taskId][ordinal];
        if (!blob.exists) revert SnapshotNotFound();
        if (blob.uploader != msg.sender) revert UnauthorizedSnapshotDelete();

        bytes32 blobHash = blob.blobHash;
        delete blobs[taskId][ordinal];
        emit SnapshotDeleted(taskId, ordinal, blobHash);
    }

    function getSnapshot(bytes32 taskId, uint32 ordinal) external view override returns (bytes memory) {
        SnapshotBlob storage blob = blobs[taskId][ordinal];
        if (!blob.exists) revert SnapshotNotFound();
        return blob.data;
    }

    function getSnapshotHash(bytes32 taskId, uint32 ordinal) external view override returns (bytes32) {
        SnapshotBlob storage blob = blobs[taskId][ordinal];
        if (!blob.exists) revert SnapshotNotFound();
        return blob.blobHash;
    }

    function hasSnapshot(bytes32 taskId, uint32 ordinal) external view override returns (bool) {
        return blobs[taskId][ordinal].exists;
    }
}
