// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pool} from "@ccip/contracts/libraries/Pool.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";
import {RateLimiter} from "@ccip/contracts/libraries/RateLimiter.sol";
import {TokenPool} from "@ccip/contracts/pools/TokenPool.sol";

import {RebaseToken} from "../../src/RebaseToken.sol";
import {RebaseTokenPool} from "../../src/RebaseTokenPool.sol";
import {MessageCodec} from "../../src/bridge/MessageCodec.sol";
import {CircuitBreaker} from "../../src/safety/CircuitBreaker.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Exercises RebaseTokenPool's Phase-1 hardening (versioned payloads, replay guard,
/// pause, circuit breaker) directly, without a CCIP fork: the router/rmnProxy are mocked so
/// `_onlyOnRamp` / `_onlyOffRamp` / `_validateReleaseOrMint`'s RMN-curse check pass, letting these
/// tests run fast and offline while CrossChain.t.sol still covers the real end-to-end fork path.
contract BridgeHardeningTest is Test {
    RebaseToken token;
    RebaseTokenPool pool;

    address owner = makeAddr("owner");
    address router = makeAddr("router");
    address rmnProxy = makeAddr("rmnProxy");
    address onRamp = makeAddr("onRamp");
    address offRamp = makeAddr("offRamp");
    address user = makeAddr("user");

    uint64 constant REMOTE_SELECTOR = 16015286601757825753;
    uint64 constant LOCAL_SELECTOR = 3478487238524512106;
    address remotePool = makeAddr("remotePool");
    address remoteToken = makeAddr("remoteToken");

    function setUp() public {
        vm.mockCall(rmnProxy, abi.encodeWithSignature("isCursed(bytes16)"), abi.encode(false));

        vm.startPrank(owner);
        token = new RebaseToken();
        pool = new RebaseTokenPool(IERC20(address(token)), new address[](0), rmnProxy, router, LOCAL_SELECTOR);
        token.grantMintAndBurnRole(address(pool));
        pool.grantRole(Roles.LANE_ADMIN_ROLE, owner);

        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: REMOTE_SELECTOR,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
        pool.applyChainUpdates(new uint64[](0), chains);
        vm.stopPrank();

        vm.mockCall(
            router, abi.encodeWithSelector(bytes4(keccak256("getOnRamp(uint64)")), REMOTE_SELECTOR), abi.encode(onRamp)
        );
        vm.mockCall(
            router,
            abi.encodeWithSelector(bytes4(keccak256("isOffRamp(uint64,address)")), REMOTE_SELECTOR, offRamp),
            abi.encode(true)
        );

        // The real CCIP router transfers `amount` from the user to the pool before calling
        // lockOrBurn (which then burns from its own balance, address(this)) — simulate that
        // pre-transfer by minting directly to the pool.
        vm.prank(address(pool));
        token.mint(address(pool), 1000, 5e10);
        vm.prank(address(pool));
        token.mint(user, 1000, 5e10);
    }

    function _validLockOrBurnIn(uint256 amount) internal view returns (Pool.LockOrBurnInV1 memory) {
        return Pool.LockOrBurnInV1({
            receiver: abi.encode(user),
            remoteChainSelector: REMOTE_SELECTOR,
            originalSender: user,
            amount: amount,
            localToken: address(token)
        });
    }

    function _releaseOrMintIn(uint256 amount, bytes memory sourcePoolData)
        internal
        view
        returns (Pool.ReleaseOrMintInV1 memory)
    {
        return Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(user),
            remoteChainSelector: REMOTE_SELECTOR,
            receiver: user,
            sourceDenominatedAmount: amount,
            localToken: address(token),
            sourcePoolAddress: abi.encode(remotePool),
            sourcePoolData: sourcePoolData,
            offchainTokenData: ""
        });
    }

    // ---------------------------------------------------------------
    // Versioning
    // ---------------------------------------------------------------

    function testLockOrBurnEncodesSupportedVersion() public {
        vm.prank(onRamp);
        Pool.LockOrBurnOutV1 memory out = pool.lockOrBurn(_validLockOrBurnIn(100));
        assertEq(MessageCodec.decodeVersion(out.destPoolData), MessageCodec.VERSION_1);
    }

    function testReleaseOrMintRevertsOnUnsupportedVersion() public {
        vm.prank(owner);
        pool.setVersionSupported(MessageCodec.VERSION_1, false);

        vm.prank(onRamp);
        Pool.LockOrBurnOutV1 memory out = pool.lockOrBurn(_validLockOrBurnIn(100));

        vm.prank(offRamp);
        vm.expectRevert(abi.encodeWithSelector(Errors.Pool__UnsupportedVersion.selector, MessageCodec.VERSION_1));
        pool.releaseOrMint(_releaseOrMintIn(100, out.destPoolData));
    }

    function testReleaseOrMintRevertsOnMalformedSourcePoolData() public {
        vm.prank(offRamp);
        vm.expectRevert(MessageCodec.MalformedPayload.selector);
        pool.releaseOrMint(_releaseOrMintIn(100, hex"01"));
    }

    // ---------------------------------------------------------------
    // Replay
    // ---------------------------------------------------------------

    function testSameMessageCannotMintTwice() public {
        vm.prank(onRamp);
        Pool.LockOrBurnOutV1 memory out = pool.lockOrBurn(_validLockOrBurnIn(100));

        uint256 balanceBefore = token.balanceOf(user);
        vm.prank(offRamp);
        pool.releaseOrMint(_releaseOrMintIn(100, out.destPoolData));
        assertEq(token.balanceOf(user), balanceBefore + 100);

        vm.prank(offRamp);
        vm.expectRevert();
        pool.releaseOrMint(_releaseOrMintIn(100, out.destPoolData));
    }

    function testDifferentNoncesProduceDifferentHashesAndBothMint() public {
        vm.startPrank(onRamp);
        Pool.LockOrBurnOutV1 memory out1 = pool.lockOrBurn(_validLockOrBurnIn(50));
        Pool.LockOrBurnOutV1 memory out2 = pool.lockOrBurn(_validLockOrBurnIn(50));
        vm.stopPrank();

        assertTrue(keccak256(out1.destPoolData) != keccak256(out2.destPoolData));

        vm.startPrank(offRamp);
        pool.releaseOrMint(_releaseOrMintIn(50, out1.destPoolData));
        pool.releaseOrMint(_releaseOrMintIn(50, out2.destPoolData));
        vm.stopPrank();
    }

    function testMessageExecutedTracksPayloadHash() public {
        vm.prank(onRamp);
        Pool.LockOrBurnOutV1 memory out = pool.lockOrBurn(_validLockOrBurnIn(100));

        MessageCodec.BridgePayload memory decoded = MessageCodec.decodeV1(out.destPoolData);
        bytes32 expectedHash = MessageCodec.hash(decoded, 100);
        assertFalse(pool.isMessageExecuted(expectedHash));

        vm.prank(offRamp);
        pool.releaseOrMint(_releaseOrMintIn(100, out.destPoolData));
        assertTrue(pool.isMessageExecuted(expectedHash));
    }

    // ---------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------

    function testLockOrBurnRevertsWhenBridgeOutPaused() public {
        vm.prank(owner);
        pool.grantRole(Roles.PAUSER_ROLE, owner);
        vm.prank(owner);
        pool.pauseBridgeOut();

        vm.prank(onRamp);
        vm.expectRevert(Errors.Pool__BridgeOutPaused.selector);
        pool.lockOrBurn(_validLockOrBurnIn(100));
    }

    function testReleaseOrMintRevertsWhenBridgeInPaused() public {
        vm.prank(onRamp);
        Pool.LockOrBurnOutV1 memory out = pool.lockOrBurn(_validLockOrBurnIn(100));

        vm.startPrank(owner);
        pool.grantRole(Roles.PAUSER_ROLE, owner);
        pool.pauseBridgeIn();
        vm.stopPrank();

        vm.prank(offRamp);
        vm.expectRevert(Errors.Pool__BridgeInPaused.selector);
        pool.releaseOrMint(_releaseOrMintIn(100, out.destPoolData));
    }

    function testOnlyUnpauserCanUnpause() public {
        vm.startPrank(owner);
        pool.grantRole(Roles.PAUSER_ROLE, owner);
        pool.pauseBridgeOut();
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert();
        pool.unpauseBridgeOut();

        vm.startPrank(owner);
        pool.grantRole(Roles.UNPAUSER_ROLE, owner);
        pool.unpauseBridgeOut();
        vm.stopPrank();

        vm.prank(onRamp);
        pool.lockOrBurn(_validLockOrBurnIn(10));
    }

    function testNonPauserCannotPauseBridge() public {
        vm.prank(makeAddr("randomAddress"));
        vm.expectRevert();
        pool.pauseBridgeOut();
    }

    // ---------------------------------------------------------------
    // Circuit breaker
    // ---------------------------------------------------------------

    function testCircuitBreakerTripsAndPausesBothDirections() public {
        vm.prank(owner);
        CircuitBreaker breaker = new CircuitBreaker(address(pool), 1 hours, 150, 1 days);
        vm.prank(owner);
        pool.setCircuitBreaker(address(breaker));

        // Net outflow of 200 (> threshold 150) in one lockOrBurn trips the breaker and pauses
        // both directions.
        vm.prank(onRamp);
        pool.lockOrBurn(_validLockOrBurnIn(200));

        assertTrue(breaker.tripped());
        assertTrue(pool.bridgeOutPaused());
        assertTrue(pool.bridgeInPaused());

        vm.prank(onRamp);
        vm.expectRevert(Errors.Pool__BridgeOutPaused.selector);
        pool.lockOrBurn(_validLockOrBurnIn(10));
    }

    function testCircuitBreakerResetRequiresCooldown() public {
        vm.prank(owner);
        CircuitBreaker breaker = new CircuitBreaker(address(pool), 1 hours, 150, 1 days);
        vm.prank(owner);
        pool.setCircuitBreaker(address(breaker));

        vm.prank(onRamp);
        pool.lockOrBurn(_validLockOrBurnIn(200));
        assertTrue(breaker.tripped());

        vm.prank(owner);
        vm.expectRevert();
        breaker.reset();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        breaker.reset();
        assertFalse(breaker.tripped());
    }

    function testCircuitBreakerOnlyCallableByItsPool() public {
        CircuitBreaker breaker = new CircuitBreaker(address(pool), 1 hours, 150, 1 days);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.NotPool.selector, address(this)));
        breaker.checkAndRecord(1, 1);
    }
}
