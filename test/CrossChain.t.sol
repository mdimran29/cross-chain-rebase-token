// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console, Test} from "forge-std/Test.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {TokenPool} from "@ccip/contracts/pools/TokenPool.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RateLimiter} from "@ccip/contracts/libraries/RateLimiter.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";
import {IRouterClient} from "@ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@ccip/contracts/libraries/Client.sol";

import {RebaseToken} from "../src/RebaseToken.sol";

import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";

import {Vault} from "../src/Vault.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";

// Tests to include
// Test you can bridge tokens - check the balance is correct
// test you can bridge a portion of tokens - check balances are correct
// test you can bridge and then bridge back all balance - check balances
// test you can bridge and then bridge back a portion - check balances
contract CrossChainTest is Test {
    address public owner = makeAddr("owner");
    address alice = makeAddr("alice");
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;
    uint256 public SEND_VALUE = 1e5;

    uint256 sepoliaFork;
    uint256 arbSepoliaFork;

    RebaseToken destRebaseToken;
    RebaseToken sourceRebaseToken;

    RebaseTokenPool destPool;
    RebaseTokenPool sourcePool;

    TokenAdminRegistry tokenAdminRegistrySepolia;
    TokenAdminRegistry tokenAdminRegistryarbSepolia;

    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    RegistryModuleOwnerCustom registryModuleOwnerCustomSepolia;
    RegistryModuleOwnerCustom registryModuleOwnerCustomarbSepolia;

    Vault vault;
    Treasury treasury;

    // SourceDeployer sourceDeployer;

    function setUp() public {
        address[] memory allowlist = new address[](0);

        // sourceDeployer = new SourceDeployer();

        // 1. Setup the Sepolia and arb forks
        sepoliaFork = vm.createSelectFork("eth-sepolia");
        arbSepoliaFork = vm.createFork("arb-sepolia");

        //NOTE: what does this do?
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // 2. Deploy and configure on the source chain: Sepolia
        //sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        //(sourceRebaseToken, sourcePool, vault) = sourceDeployer.run(owner);
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.startPrank(owner);
        sourceRebaseToken = new RebaseToken();
        console.log("source rebase token address");
        console.log(address(sourceRebaseToken));
        console.log("Deploying token pool on Sepolia");
        sourcePool = new RebaseTokenPool(
            IERC20(address(sourceRebaseToken)),
            allowlist,
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress,
            sepoliaNetworkDetails.chainSelector
        );
        // deploy the vault
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(sourceRebaseToken)), address(treasury));
        // add rewards to the vault
        vm.deal(address(vault), 1e18);
        // Set pool on the token contract for permissions on Sepolia
        sourceRebaseToken.grantMintAndBurnRole(address(sourcePool));
        sourceRebaseToken.grantMintAndBurnRole(address(vault));
        // Claim role on Sepolia
        registryModuleOwnerCustomSepolia =
            RegistryModuleOwnerCustom(sepoliaNetworkDetails.registryModuleOwnerCustomAddress);
        registryModuleOwnerCustomSepolia.registerAdminViaOwner(address(sourceRebaseToken));
        // Accept role on Sepolia
        tokenAdminRegistrySepolia = TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress);
        tokenAdminRegistrySepolia.acceptAdminRole(address(sourceRebaseToken));
        // Link token to pool in the token admin registry on Sepolia
        tokenAdminRegistrySepolia.setPool(address(sourceRebaseToken), address(sourcePool));
        vm.stopPrank();

        // 3. Deploy and configure on the destination chain: Arbitrum
        // Deploy the token contract on Arbitrum
        vm.selectFork(arbSepoliaFork);
        vm.startPrank(owner);
        console.log("Deploying token on Arbitrum");
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        destRebaseToken = new RebaseToken();
        console.log("dest rebase token address");
        console.log(address(destRebaseToken));
        // Deploy the token pool on Arbitrum
        console.log("Deploying token pool on Arbitrum");
        destPool = new RebaseTokenPool(
            IERC20(address(destRebaseToken)),
            allowlist,
            arbSepoliaNetworkDetails.rmnProxyAddress,
            arbSepoliaNetworkDetails.routerAddress,
            arbSepoliaNetworkDetails.chainSelector
        );
        // Set pool on the token contract for permissions on Arbitrum
        destRebaseToken.grantMintAndBurnRole(address(destPool));
        // Claim role on Arbitrum
        registryModuleOwnerCustomarbSepolia =
            RegistryModuleOwnerCustom(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress);
        registryModuleOwnerCustomarbSepolia.registerAdminViaOwner(address(destRebaseToken));
        // Accept role on Arbitrum
        tokenAdminRegistryarbSepolia = TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress);
        tokenAdminRegistryarbSepolia.acceptAdminRole(address(destRebaseToken));
        // Link token to pool in the token admin registry on Arbitrum
        tokenAdminRegistryarbSepolia.setPool(address(destRebaseToken), address(destPool));
        vm.stopPrank();
    }

    // Phase 0 starting values (see config/chains.json): capacity ~= 5% of expected
    // circulating supply per lane, refilling over 4h.
    uint128 public constant RATE_LIMIT_CAPACITY = 500_000e18;
    uint128 public constant RATE_LIMIT_RATE = uint128(uint256(500_000e18) / 4 hours);

    function configureTokenPool(
        uint256 fork,
        TokenPool localPool,
        TokenPool remotePool,
        IRebaseToken remoteToken,
        Register.NetworkDetails memory remoteNetworkDetails
    ) public {
        configureTokenPool(fork, localPool, remotePool, remoteToken, remoteNetworkDetails, true);
    }

    function configureTokenPool(
        uint256 fork,
        TokenPool localPool,
        TokenPool remotePool,
        IRebaseToken remoteToken,
        Register.NetworkDetails memory remoteNetworkDetails,
        bool rateLimitsEnabled
    ) public {
        vm.selectFork(fork);
        vm.startPrank(owner);
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(address(remotePool));

        //uint64 remoteChainSelector; // ──╮ Remote chain selector
        // bool allowed; // ────────────────╯ Whether the chain should be enabled
        // bytes remotePoolAddress; //        Address of the remote pool, ABI encoded in the case of a remote EVM chain.
        // bytes remoteTokenAddress; //       Address of the remote token, ABI encoded in the case of a remote EVM chain.
        // RateLimiter.Config outboundRateLimiterConfig; // Outbound rate limited config, meaning the rate limits for all of the onRamps for the given chain
        //  RateLimiter.Config inboundRateLimiterConfig; // Inbound rate limited config, meaning the rate limits for all of the offRamps for the given chain

        RateLimiter.Config memory rateLimiterConfig = rateLimitsEnabled
            ? RateLimiter.Config({isEnabled: true, capacity: RATE_LIMIT_CAPACITY, rate: RATE_LIMIT_RATE})
            : RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});

        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteNetworkDetails.chainSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(address(remoteToken)),
            outboundRateLimiterConfig: rateLimiterConfig,
            inboundRateLimiterConfig: rateLimiterConfig
        });
        uint64[] memory remoteChainSelectorsToRemove = new uint64[](0);
        localPool.applyChainUpdates(remoteChainSelectorsToRemove, chains);
        vm.stopPrank();
    }

    function bridgeTokens(
        uint256 amountToBridge,
        uint256 localFork,
        uint256 remoteFork,
        Register.NetworkDetails memory localNetworkDetails,
        Register.NetworkDetails memory remoteNetworkDetails,
        RebaseToken localToken,
        RebaseToken remoteToken
    ) public {
        // Create the message to send tokens cross-chain
        vm.selectFork(localFork);
        vm.startPrank(alice);
        Client.EVMTokenAmount[] memory tokenToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount =
            Client.EVMTokenAmount({token: address(localToken), amount: amountToBridge});
        tokenToSendDetails[0] = tokenAmount;
        // Approve the router to burn tokens on users behalf
        IERC20(address(localToken)).approve(localNetworkDetails.routerAddress, amountToBridge);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(alice), // we need to encode the address to bytes
            data: "", // We don't need any data for this example
            tokenAmounts: tokenToSendDetails, // this needs to be of type EVMTokenAmount[] as you could send multiple tokens
            extraArgs: "", // We don't need any extra args for this example
            feeToken: localNetworkDetails.linkAddress // The token used to pay for the fee
        });
        // Get and approve the fees
        vm.stopPrank();
        // Give the user the fee amount of LINK
        ccipLocalSimulatorFork.requestLinkFromFaucet(
            alice, IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message)
        );
        vm.startPrank(alice);
        IERC20(localNetworkDetails.linkAddress)
            .approve(
                localNetworkDetails.routerAddress,
                IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message)
            ); // Approve the fee
        // log the values before bridging
        uint256 balanceBeforeBridge = IERC20(address(localToken)).balanceOf(alice);
        console.log("Local balance before bridge: %d", balanceBeforeBridge);

        IRouterClient(localNetworkDetails.routerAddress).ccipSend(remoteNetworkDetails.chainSelector, message); // Send the message
        uint256 sourceBalanceAfterBridge = IERC20(address(localToken)).balanceOf(alice);
        console.log("Local balance after bridge: %d", sourceBalanceAfterBridge);
        assertEq(sourceBalanceAfterBridge, balanceBeforeBridge - amountToBridge);
        vm.stopPrank();

        // get initial balance on the destination chain, before routing the message
        vm.selectFork(remoteFork);
        uint256 initialArbBalance = IERC20(address(remoteToken)).balanceOf(alice);
        console.log("Remote balance before bridge: %d", initialArbBalance);

        // Pretend it takes 15 minutes to bridge the tokens
        vm.warp(block.timestamp + 900);
        // switchChainAndRouteMessage must be called while the SOURCE fork is still active:
        // it reads vm.activeFork() internally to identify the source router/onRamp, then
        // switches to the destination fork (forkId) itself to deliver the message.
        vm.selectFork(localFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork);

        console.log("Remote user interest rate: %d", remoteToken.getUserInterestRate(alice));
        uint256 destBalance = IERC20(address(remoteToken)).balanceOf(alice);
        console.log("Remote balance after bridge: %d", destBalance);
        // initialArbBalance was read before the simulated 900s bridge delay, so any
        // pre-existing destination balance may have accrued a small amount of interest
        // in the interim; allow a tight tolerance rather than asserting exact equality.
        assertApproxEqAbs(destBalance, initialArbBalance + amountToBridge, 5);
    }

    function testBridgeAllTokens() public {
        configureTokenPool(
            sepoliaFork, sourcePool, destPool, IRebaseToken(address(destRebaseToken)), arbSepoliaNetworkDetails
        );
        configureTokenPool(
            arbSepoliaFork, destPool, sourcePool, IRebaseToken(address(sourceRebaseToken)), sepoliaNetworkDetails
        );
        // We are working on the source chain (Sepolia)
        vm.selectFork(sepoliaFork);
        // Pretend a user is interacting with the protocol
        // Give the user some ETH
        vm.deal(alice, SEND_VALUE);
        vm.startPrank(alice);
        // Deposit to the vault and receive tokens
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        // bridge the tokens
        console.log("Bridging %d tokens", SEND_VALUE);
        uint256 startBalance = IERC20(address(sourceRebaseToken)).balanceOf(alice);
        assertEq(startBalance, SEND_VALUE);
        vm.stopPrank();
        // bridge ALL TOKENS to the destination chain
        bridgeTokens(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );
    }

    function testBridgeAllTokensBack() public {
        configureTokenPool(
            sepoliaFork, sourcePool, destPool, IRebaseToken(address(destRebaseToken)), arbSepoliaNetworkDetails
        );
        configureTokenPool(
            arbSepoliaFork, destPool, sourcePool, IRebaseToken(address(sourceRebaseToken)), sepoliaNetworkDetails
        );
        // We are working on the source chain (Sepolia)
        vm.selectFork(sepoliaFork);
        // Pretend a user is interacting with the protocol
        // Give the user some ETH
        vm.deal(alice, SEND_VALUE);
        vm.startPrank(alice);
        // Deposit to the vault and receive tokens
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        // bridge the tokens
        console.log("Bridging %d tokens", SEND_VALUE);
        uint256 startBalance = IERC20(address(sourceRebaseToken)).balanceOf(alice);
        assertEq(startBalance, SEND_VALUE);
        vm.stopPrank();
        // bridge ALL TOKENS to the destination chain
        bridgeTokens(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );
        // bridge back ALL TOKENS to the source chain after 1 hour
        vm.selectFork(arbSepoliaFork);
        console.log("User Balance Before Warp: %d", destRebaseToken.balanceOf(alice));
        vm.warp(block.timestamp + 3600);
        console.log("User Balance After Warp: %d", destRebaseToken.balanceOf(alice));
        uint256 destBalance = IERC20(address(destRebaseToken)).balanceOf(alice);
        console.log("Amount bridging back %d tokens ", destBalance);
        bridgeTokens(
            destBalance,
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            destRebaseToken,
            sourceRebaseToken
        );
    }

    function testBridgeTwice() public {
        configureTokenPool(
            sepoliaFork, sourcePool, destPool, IRebaseToken(address(destRebaseToken)), arbSepoliaNetworkDetails
        );
        configureTokenPool(
            arbSepoliaFork, destPool, sourcePool, IRebaseToken(address(sourceRebaseToken)), sepoliaNetworkDetails
        );
        // We are working on the source chain (Sepolia)
        vm.selectFork(sepoliaFork);
        // Pretend a user is interacting with the protocol
        // Give the user some ETH
        vm.deal(alice, SEND_VALUE);
        vm.startPrank(alice);
        // Deposit to the vault and receive tokens
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        uint256 startBalance = IERC20(address(sourceRebaseToken)).balanceOf(alice);
        assertEq(startBalance, SEND_VALUE);
        vm.stopPrank();
        // bridge half tokens to the destination chain
        // bridge the tokens
        console.log("Bridging %d tokens (first bridging event)", SEND_VALUE / 2);
        bridgeTokens(
            SEND_VALUE / 2,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );
        // wait 1 hour for the interest to accrue
        vm.selectFork(sepoliaFork);
        vm.warp(block.timestamp + 3600);
        uint256 newSourceBalance = IERC20(address(sourceRebaseToken)).balanceOf(alice);
        // bridge the tokens
        console.log("Bridging %d tokens (second bridging event)", newSourceBalance);
        bridgeTokens(
            newSourceBalance,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );
        // bridge back ALL TOKENS to the source chain after 1 hour
        vm.selectFork(arbSepoliaFork);
        // wait an hour for the tokens to accrue interest on the destination chain
        console.log("User Balance Before Warp: %d", destRebaseToken.balanceOf(alice));
        vm.warp(block.timestamp + 3600);
        console.log("User Balance After Warp: %d", destRebaseToken.balanceOf(alice));
        uint256 destBalance = IERC20(address(destRebaseToken)).balanceOf(alice);
        console.log("Amount bridging back %d tokens ", destBalance);
        bridgeTokens(
            destBalance,
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            destRebaseToken,
            sourceRebaseToken
        );
    }

    /// @notice Phase 0: with rate limits enabled, a bridge amount that exceeds the
    /// outbound bucket capacity must be throttled (revert), proving the limiter is
    /// actually wired up rather than silently disabled as before.
    function testBridgeRevertsWhenExceedingRateLimitCapacity() public {
        configureTokenPool(
            sepoliaFork, sourcePool, destPool, IRebaseToken(address(destRebaseToken)), arbSepoliaNetworkDetails, true
        );
        configureTokenPool(
            arbSepoliaFork, destPool, sourcePool, IRebaseToken(address(sourceRebaseToken)), sepoliaNetworkDetails, true
        );

        vm.selectFork(sepoliaFork);
        uint256 amountOverCapacity = uint256(RATE_LIMIT_CAPACITY) + 1;
        vm.deal(alice, amountOverCapacity);
        vm.startPrank(alice);
        Vault(payable(address(vault))).deposit{value: amountOverCapacity}();
        IERC20(address(sourceRebaseToken)).approve(sepoliaNetworkDetails.routerAddress, amountOverCapacity);

        Client.EVMTokenAmount[] memory tokenToSendDetails = new Client.EVMTokenAmount[](1);
        tokenToSendDetails[0] = Client.EVMTokenAmount({token: address(sourceRebaseToken), amount: amountOverCapacity});
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(alice),
            data: "",
            tokenAmounts: tokenToSendDetails,
            extraArgs: "",
            feeToken: sepoliaNetworkDetails.linkAddress
        });
        vm.stopPrank();

        ccipLocalSimulatorFork.requestLinkFromFaucet(
            alice,
            IRouterClient(sepoliaNetworkDetails.routerAddress).getFee(arbSepoliaNetworkDetails.chainSelector, message)
        );
        vm.startPrank(alice);
        IERC20(sepoliaNetworkDetails.linkAddress)
            .approve(
                sepoliaNetworkDetails.routerAddress,
                IRouterClient(sepoliaNetworkDetails.routerAddress)
                    .getFee(arbSepoliaNetworkDetails.chainSelector, message)
            );

        // Sending more than the bucket capacity in a single message must be throttled.
        vm.expectRevert();
        IRouterClient(sepoliaNetworkDetails.routerAddress).ccipSend(arbSepoliaNetworkDetails.chainSelector, message);
        vm.stopPrank();
    }

    /// @notice A bridge amount within capacity still succeeds once limits are enabled —
    /// proving the limiter throttles excess flow without blocking normal-sized transfers.
    function testBridgeSucceedsWithinRateLimitCapacity() public {
        configureTokenPool(
            sepoliaFork, sourcePool, destPool, IRebaseToken(address(destRebaseToken)), arbSepoliaNetworkDetails, true
        );
        configureTokenPool(
            arbSepoliaFork, destPool, sourcePool, IRebaseToken(address(sourceRebaseToken)), sepoliaNetworkDetails, true
        );

        vm.selectFork(sepoliaFork);
        vm.deal(alice, SEND_VALUE);
        vm.startPrank(alice);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        vm.stopPrank();

        bridgeTokens(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );
    }
}

// pragma solidity ^0.8.24;

// import {Test, console} from "forge-std/Test.sol";
// import {RebaseToken} from "../src/RebaseToken.sol";
// import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
// import {Vault} from "../src/Vault.sol";
// import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
// import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
// import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
// import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
// import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
// import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
// import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";

// contract CrossChainTest is Test {
//     address constant owner = makeAddr("owner");
//     uint256 sepoliaFork;
//     uint256 arbSepoliaFork;

//     CCIPLocalSimulatorFork ccipLocalSimulatorFork;

//     RebaseToken sepoliaToken;
//     RebaseToken arbSepoliaToken;

//     Vault vault;

//     RebaseTokenPool sepoliaPool;
//     RebaseTokenPool arbSepoliaPool;

//     Register.NetworkDetails sepoliaNetworkDetails;
//     Register.NetworkDetails arbSepoliaNetworkDetails;

//     function setUp() public {
//           sepoliaFork = vm.createSelectFork("eth-sepolia");
//         arbSepoliaFork = vm.createFork("arb-sepolia");

//         ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
//         vm.makePersistent(address(ccipLocalSimulatorFork));

//         // 1. Deploy and configure on Sepolia
//         vm.startPrank(owner);
//         sepoliaToken = new RebaseToken();
//         vault = new Vault(IRebaseToken(sepoliaToken));
//         sepoliaPool = new RebaseTokenPool(
//             IERC20(address(sepoliaToken)),
//             address[](0),
//             sepoliaNetworkDetails.rmnProxyAddress,
//             sepoliaNetworkDetails.routerAddress,
//             address(vault) // Add the missing argument
//         );
//         sepoliaToken.grantMintAndBurnRole(address(vault));
//         sepoliaToken.grantMintAndBurnRole(address(sepoliaPool));
//         RegistryModuleOwnerCustom(sepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(
//             address(sepoliaToken)
//         );
//         TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(sepoliaToken));
//         TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(
//             address(sepoliaToken), address(sepoliaPool)
//         );
//         vm.stopPrank();

//         //2. Deploy and configure on arb-sepolia
//         vm.selectFork(arbSepoliaFork);

//         arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
//         arbSepoliaToken = new RebaseToken();
//          arbSepoliaPool = new RebaseTokenPool(
//             IERC20(address(arbSepoliaToken)),
//             address[](0),
//             arbSepoliaNetworkDetails.rmnProxyAddress,
//             arbSepoliaNetworkDetails.routerAddress,
//             address(vault) );

//     }
//     // function setUp() public {
//     //     sepoliaFork = vm.createSelectFork("sepolia");
//     //     arbSepoliaFork = vm.createFork("arb-sepolia");

//     //     ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
//     //     vm.makePersistent(address(ccipLocalSimulatorFork));

//     //     // 1. Deploy and configure on Sepolia
//     //     sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
//     //     vm.startPrank(owner);
//     //     sepoliaToken = new RebaseToken();
//     //     vault = new Vault(IRebaseToken(sepoliaToken));
//     //     sepoliaPool = new RebaseTokenPool(
//     //         IERC20(address(sepoliaToken)),
//     //         address[](0),
//     //         sepoliaNetworkDetails.rmnProxyAddress,
//     //         sepoliaNetworkDetails.routerAddress,
//     //         address(vault) // Add the missing argument
//     //     );
//     //     sepoliaToken.grantMintAndBurnRole(address(vault));
//     //     sepoliaToken.grantMintAndBurnRole(address(sepoliaPool));
//     //     RegistryModuleOwnerCustom(sepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(
//     //         address(sepoliaToken)
//     //     );
//     //     TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(sepoliaToken));
//     //     TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(
//     //         address(sepoliaToken), address(sepoliaPool)
//     //     );
//     //     vm.stopPrank();

//     //     //2. Deploy and configure on arb-sepolia
//     //     vm.selectFork(arbSepoliaFork);

//     //     arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
//     //     arbSepoliaToken = new RebaseToken();
//     //      // arbSepoliaPool = new RebaseTokenPool(
//     //     //     IERC20(
//     //     //         address(
//     //     // arbSepoliaPool = new RebaseTokenPool(
//     //     //     IERC20(address(arbSepoliaToken)),
//     //     //     address[](0),
//     //     //     arbSepoliaNetworkDetails.rmnProxyAddress,
//     //     //     arbSepoliaNetworkDetails.routerAddress,
//     //     //     address(vault) );
//     //     (arbSepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(arbSepoliaToken));
//     //     TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(address(arbSepoliaToken), address(arbSepoliaPool) );

//     //     configerTokenPool(
//     //         sepoliaFork,
//     //         address(sepoliaPool),
//     //         arbSepoliaNetworkDetails.chainSelector,
//     //         address(arbSepoliaPool),
//     //         address(arbSepoliaToken)
//     //     );
//     //     configerTokenPool(
//     //         arbSepoliaFork,
//     //         address(arbSepoliaPool),
//     //         sepoliaNetworkDetails.chainSelector,
//     //         address(sepoliaPool),
//     //         address(sepoliaToken)
//     //     );
//     //     vm.startPrank(owner);

//     //     vm.stopPrank();
//     // }

//     function configerTokenPool(
//         uint256 fork,
//         address localPool,
//         uint64 remoteChainSelector,
//         address remotePool,
//         address remoteTokenAddress
//     ) public {
//         vm.selectFork(fork);
//         vm.prank(owner);
//         bytes[] memory remotePoolAddresses = new bytes[](1);
//         remotePoolAddresses[0] = abi.encode(remotePool);
//         TokenPool.ChainUpdate[] memory chainsToAdd = new TokenPool.ChainUpdate[](1);
//         chainsToAdd[0] = TokenPool.ChainUpdate({
//             remoteChainSelector: remoteChainSelector,
//             remotePoolAddresses: remotePoolAddresses,
//             remoteTokenAddress: abi.encode(remoteTokenAddress),
//             outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
//             inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
//         });

//         TokenPool(localPool).applyChainUpdates(new uint64[](0), chainsToAdd);
//     }
// }
