// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pool} from "@ccip/contracts/libraries/Pool.sol";
import {TokenPool} from "@ccip/contracts/pools/TokenPool.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";
import {MessageCodec} from "./bridge/MessageCodec.sol";
import {Roles} from "./libraries/Roles.sol";
import {Errors} from "./libraries/Errors.sol";

/// @notice Burn-and-mint CCIP pool for RebaseToken, hardened per Phase 1 (Bridge Hardening):
/// versioned + hashed payloads, a protocol-level replay guard, scoped pause, and circuit-breaker
/// hooks — layered on top of (not replacing) CCIP's own trusted-remote, rate-limit, and
/// onRamp/offRamp checks in `TokenPool._validateLockOrBurn` / `_validateReleaseOrMint`.
contract RebaseTokenPool is TokenPool, AccessControl {
    using MessageCodec for MessageCodec.BridgePayload;

    /// @notice This pool's own CCIP chain selector, embedded in every outbound payload so the
    /// hash binds a message to the lane it was sent on (not just the remote leg). Set at deploy
    /// time from the same `Register.NetworkDetails.chainSelector` used to configure this chain
    /// everywhere else in the deploy scripts/tests.
    uint64 public immutable i_localChainSelector;

    /// @dev nonce is per-source-pool (this contract), not per-user — it only needs to make each
    /// outbound payload unique for hashing/replay purposes, not to enforce per-user ordering.
    /// uint32 (per MessageCodec's packed wire format) comfortably outlives any real deployment
    /// (4.29 billion outbound bridges from a single pool).
    uint32 private s_outboundNonce;

    /// @notice Versions this pool will decode on `releaseOrMint`. Governance enables a new
    /// version on the destination before the source starts emitting it (see NatSpec on
    /// `setVersionSupported`), and reverses the order to sunset one.
    mapping(uint16 => bool) private s_supportedVersions;

    /// @notice Protocol-level executed-message set, keyed by the payload hash. Defense in depth
    /// on top of CCIP's own per-message execution guarantee (roadmap §3.7): protects this pool
    /// even if a future migration reuses it with a different router, and makes "no message mints
    /// twice" provable in this repo's own tests rather than assumed from a dependency.
    mapping(bytes32 => bool) private s_executedMessages;

    bool public bridgeOutPaused;
    bool public bridgeInPaused;

    address public circuitBreaker;

    event BridgeInitiated(
        address indexed sender,
        uint64 indexed destChainSelector,
        uint256 amount,
        uint256 userInterestRate,
        bytes32 payloadHash,
        uint256 nonce
    );
    event BridgeCompleted(
        address indexed receiver,
        uint64 indexed sourceChainSelector,
        uint256 amount,
        uint256 userInterestRate,
        bytes32 payloadHash
    );
    event MessageExecuted(bytes32 indexed payloadHash);
    event VersionSupportedSet(uint16 indexed version, bool supported);
    event CircuitBreakerSet(address indexed circuitBreaker);
    event BridgeOutPausedSet(bool isPaused);
    event BridgeInPausedSet(bool isPaused);

    modifier whenBridgeOutNotPaused() {
        if (bridgeOutPaused) revert Errors.Pool__BridgeOutPaused();
        _;
    }

    modifier whenBridgeInNotPaused() {
        if (bridgeInPaused) revert Errors.Pool__BridgeInPaused();
        _;
    }

    constructor(IERC20 token, address[] memory allowlist, address rmnProxy, address router, uint64 localChainSelector)
        TokenPool(token, ERC20(address(token)).decimals(), allowlist, rmnProxy, router)
    {
        i_localChainSelector = localChainSelector;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        s_supportedVersions[MessageCodec.VERSION_1] = true;
        emit VersionSupportedSet(MessageCodec.VERSION_1, true);
    }

    /// @notice Fast, single-signer pause of outbound bridging only. Redemptions/deposits and
    /// inbound bridging are unaffected — mirrors the scoped-pause granularity from Phase 0.
    /// @dev Also callable by `circuitBreaker` (granted `Roles.PAUSER_ROLE`), so an automated
    /// anomaly trip has exactly the same — and no more — authority than a human Guardian pause.
    function pauseBridgeOut() external onlyRole(Roles.PAUSER_ROLE) {
        bridgeOutPaused = true;
        emit BridgeOutPausedSet(true);
    }

    function pauseBridgeIn() external onlyRole(Roles.PAUSER_ROLE) {
        bridgeInPaused = true;
        emit BridgeInPausedSet(true);
    }

    /// @notice Unpausing is deliberately gated behind a separate, slower role than pausing (see
    /// Phase 0 rationale on RebaseToken/Vault) so a single compromised PAUSER can't both freeze
    /// and immediately unfreeze the bridge.
    function unpauseBridgeOut() external onlyRole(Roles.UNPAUSER_ROLE) {
        bridgeOutPaused = false;
        emit BridgeOutPausedSet(false);
    }

    function unpauseBridgeIn() external onlyRole(Roles.UNPAUSER_ROLE) {
        bridgeInPaused = false;
        emit BridgeInPausedSet(false);
    }

    /// @notice Enables or disables decoding of a given payload version on `releaseOrMint`.
    /// @dev Rollout discipline: enable a new version on the destination pool *before* the source
    /// pool starts emitting it (source and destination are the same contract per-chain here, but
    /// different chains upgrade independently) — reverse the order to sunset a version.
    function setVersionSupported(uint16 version, bool supported) external onlyRole(Roles.LANE_ADMIN_ROLE) {
        s_supportedVersions[version] = supported;
        emit VersionSupportedSet(version, supported);
    }

    function isVersionSupported(uint16 version) external view returns (bool) {
        return s_supportedVersions[version];
    }

    function isMessageExecuted(bytes32 payloadHash) external view returns (bool) {
        return s_executedMessages[payloadHash];
    }

    /// @notice Wires an aggregate CircuitBreaker and grants it exactly `PAUSER_ROLE` — subtractive
    /// authority only, never mint/burn/rate/fee power. Timelock-gated in production (currently
    /// `DEFAULT_ADMIN_ROLE`, matching this repo's Phase 0/1 admin model).
    function setCircuitBreaker(address _circuitBreaker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (circuitBreaker != address(0)) {
            _revokeRole(Roles.PAUSER_ROLE, circuitBreaker);
        }
        circuitBreaker = _circuitBreaker;
        if (_circuitBreaker != address(0)) {
            _grantRole(Roles.PAUSER_ROLE, _circuitBreaker);
        }
        emit CircuitBreakerSet(_circuitBreaker);
    }

    /// @notice burns the tokens on the source chain
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn)
        public
        virtual
        override
        whenBridgeOutNotPaused
        returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut)
    {
        _validateLockOrBurn(lockOrBurnIn);
        // Burn the tokens on the source chain. This returns their userAccumulatedInterest before the tokens were burned (in case all tokens were burned, we don't want to send 0 cross-chain)
        uint256 userInterestRate = IRebaseToken(address(i_token)).getUserInterestRate(lockOrBurnIn.originalSender);
        if (userInterestRate > type(uint136).max) {
            revert Errors.Pool__InterestRateOverflow(userInterestRate);
        }
        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount);

        uint32 nonce = ++s_outboundNonce;
        MessageCodec.BridgePayload memory payload = MessageCodec.BridgePayload({
            version: MessageCodec.VERSION_1,
            msgType: MessageCodec.MSG_TOKEN_TRANSFER,
            sourceChainSelector: i_localChainSelector,
            nonce: nonce,
            // forge-lint: disable-next-line(unsafe-typecast)
            userInterestRate: uint136(userInterestRate) // checked against type(uint136).max above
        });
        bytes32 payloadHash = payload.hash(lockOrBurnIn.amount);

        if (address(circuitBreaker) != address(0)) {
            ICircuitBreaker(circuitBreaker).checkAndRecord(0, lockOrBurnIn.amount);
        }

        emit BridgeInitiated(
            lockOrBurnIn.originalSender,
            lockOrBurnIn.remoteChainSelector,
            lockOrBurnIn.amount,
            userInterestRate,
            payloadHash,
            nonce
        );

        // encode a function call to pass the caller's info to the destination pool and update it
        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector), destPoolData: payload.encodeV1()
        });
    }

    /// @notice Mints the tokens on the destination chain
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn)
        public
        virtual
        override
        whenBridgeInNotPaused
        returns (Pool.ReleaseOrMintOutV1 memory)
    {
        // sourcePoolData carries the versioned BridgePayload (not the base class's decimals
        // encoding), so remote decimals are assumed equal to local decimals; see
        // _parseRemoteDecimals override below.
        uint256 localAmount = _calculateLocalAmount(releaseOrMintIn.sourceDenominatedAmount, _parseRemoteDecimals(""));
        _validateReleaseOrMint(releaseOrMintIn, localAmount);

        uint16 version = MessageCodec.decodeVersion(releaseOrMintIn.sourcePoolData);
        if (!s_supportedVersions[version]) {
            revert Errors.Pool__UnsupportedVersion(version);
        }
        MessageCodec.BridgePayload memory payload = MessageCodec.decodeV1(releaseOrMintIn.sourcePoolData);

        bytes32 payloadHash = payload.hash(localAmount);
        if (s_executedMessages[payloadHash]) {
            revert Errors.Pool__MessageAlreadyExecuted(payloadHash);
        }
        // Marked executed before minting (checks-effects-interactions): the mint below only
        // calls the trusted RebaseToken, but keeping this ordering means a future callback-bearing
        // token integration can never re-enter and replay the same message.
        s_executedMessages[payloadHash] = true;
        emit MessageExecuted(payloadHash);

        address receiver = releaseOrMintIn.receiver;
        if (address(circuitBreaker) != address(0)) {
            ICircuitBreaker(circuitBreaker).checkAndRecord(localAmount, 0);
        }

        // Mints rebasing tokens to the receiver on the destination chain.
        // This will also mint any interest that has accrued since the last time the user's balance was updated.
        IRebaseToken(address(i_token)).mint(receiver, localAmount, payload.userInterestRate);

        emit BridgeCompleted(
            receiver, releaseOrMintIn.remoteChainSelector, localAmount, payload.userInterestRate, payloadHash
        );

        return Pool.ReleaseOrMintOutV1({destinationAmount: localAmount});
    }

    /// @dev sourcePoolData is repurposed to carry the versioned BridgePayload rather than the
    /// base TokenPool's decimals encoding, so remote decimals can't be read from it here. Every
    /// RebaseToken deployment uses the same (18) decimals, so local decimals is always correct.
    function _parseRemoteDecimals(bytes memory) internal view virtual override returns (uint8) {
        return getTokenDecimals();
    }

    /// @dev TokenPool and AccessControl both declare `supportsInterface`; resolve the diamond by
    /// supporting both parents' interface sets.
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        virtual
        override(TokenPool, AccessControl)
        returns (bool)
    {
        return TokenPool.supportsInterface(interfaceId) || interfaceId == type(IAccessControl).interfaceId;
    }
}

interface ICircuitBreaker {
    function checkAndRecord(uint256 inflow, uint256 outflow) external;
}
