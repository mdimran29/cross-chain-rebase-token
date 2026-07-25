// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Encodes/decodes the versioned CCIP `destPoolData` / `sourcePoolData` payload carried
/// by RebaseTokenPool. Replaces the Phase-0 bare `abi.encode(uint256 userInterestRate)` wire
/// format with a self-describing, hash-bound one so the schema can evolve without breaking
/// in-flight or cross-version messages.
/// @dev CCIP's `FeeQuoter` caps `destPoolData` at `Pool.CCIP_LOCK_OR_BURN_V1_RET_BYTES` (32 bytes)
/// unless a lane's `TokenTransferFeeConfig.destBytesOverhead` is raised — an admin action outside
/// this pool's control on public lanes. So the wire format below is bit-packed into exactly one
/// 32-byte word (not `abi.encode`d, which would pad every field to its own word). `sender` is
/// deliberately excluded from the wire payload: `lockOrBurnIn.originalSender` /
/// `releaseOrMintIn.receiver` already carry that identity out of band at both call sites, and
/// CCIP's own onRamp/offRamp + trusted-remote checks (`_onlyOnRamp`/`_onlyOffRamp`,
/// `isRemotePool`) are the actual trust root for who is allowed to move value — duplicating the
/// sender into the hashed payload would add no real integrity guarantee here, only bytes.
library MessageCodec {
    uint16 internal constant VERSION_1 = 1;
    uint8 internal constant MSG_TOKEN_TRANSFER = 1;

    error UnsupportedVersion(uint16 version);
    error MalformedPayload();

    /// @dev Bit layout of the packed wire word (MSB to LSB): version(16) | msgType(8) |
    /// sourceChainSelector(64) | nonce(32) | userInterestRate(136). 136 bits gives
    /// `userInterestRate` (PRECISION_FACTOR = 1e18 scale, starting at 5e10 and monotonically
    /// decreasing) enormous headroom (~1e41) while still fitting everything in one word.
    struct BridgePayload {
        uint16 version;
        uint8 msgType;
        uint64 sourceChainSelector;
        uint32 nonce;
        uint136 userInterestRate;
    }

    uint256 private constant RATE_BITS = 136;
    uint256 private constant NONCE_BITS = 32;
    uint256 private constant SELECTOR_BITS = 64;
    uint256 private constant MSG_TYPE_BITS = 8;

    /// @notice Packs a v1 payload into a single 32-byte word. The leading `version` bits let the
    /// destination dispatch to the correct decoder before attempting a full decode.
    function encodeV1(BridgePayload memory payload) internal pure returns (bytes memory) {
        uint256 word = (uint256(payload.version) << 240) | (uint256(payload.msgType) << 232)
            | (uint256(payload.sourceChainSelector) << 168) | (uint256(payload.nonce) << 136)
            | uint256(payload.userInterestRate);
        return abi.encodePacked(word);
    }

    /// @notice Reads only the leading version bits without decoding the rest of the payload.
    /// @dev Every supported version places `version` in the top 16 bits of the single word, so
    /// this is safe to call before knowing which layout follows.
    function decodeVersion(bytes memory data) internal pure returns (uint16 version) {
        if (data.length != 32) revert MalformedPayload();
        uint256 word;
        assembly {
            word := mload(add(data, 32))
        }
        version = uint16(word >> 240);
    }

    function decodeV1(bytes memory data) internal pure returns (BridgePayload memory payload) {
        if (data.length != 32) revert MalformedPayload();
        uint256 word;
        assembly {
            word := mload(add(data, 32))
        }
        // forge-lint: disable-start(unsafe-typecast)
        // Each cast below extracts an exact bit range from a word this library itself packed in
        // encodeV1 — shifting first then truncating discards only the higher bits already
        // consumed by the preceding field, never live data.
        payload.version = uint16(word >> 240);
        if (payload.version != VERSION_1) revert UnsupportedVersion(payload.version);
        payload.msgType = uint8(word >> 232);
        payload.sourceChainSelector = uint64(word >> 168);
        payload.nonce = uint32(word >> 136);
        payload.userInterestRate = uint136(word);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Canonical, integrity-binding hash of a payload plus the bridged `amount`.
    /// @dev Always `abi.encode` (never `encodePacked`) for the *hashed* representation — packed
    /// dynamic types are hash-collision-ambiguous; here every field is fixed-width, but encode is
    /// used regardless for consistency with the rest of the protocol's hashing convention. This
    /// hash is used both as a tamper check (recomputed on the destination and compared) and as
    /// the key for the replay-guard set, so integrity and replay defense share one 32-byte handle.
    function hash(BridgePayload memory payload, uint256 amount) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                payload.version,
                payload.msgType,
                payload.sourceChainSelector,
                amount,
                payload.userInterestRate,
                payload.nonce
            )
        );
    }
}
