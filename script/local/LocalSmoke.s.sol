// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NodeFactory} from "../../src/factory/NodeFactory.sol";
import {NodeDeployer} from "../../src/factory/NodeDeployer.sol";
import {NodeTypes} from "../../src/factory/NodeTypes.sol";
import {ReleaseRegistry} from "../../src/factory/ReleaseRegistry.sol";
import {CreationCodeStore} from "../../src/factory/CreationCodeStore.sol";
import {NodeRoles} from "../../src/policy/NodeRoles.sol";
import {TruthMarket} from "../../src/TruthMarket.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {AMMEngine} from "../../src/AMMEngine.sol";
import {OrderEngine} from "../../src/OrderEngine.sol";
import {IOrderEngine} from "../../src/interfaces/IOrderEngine.sol";
import {LPPositionManager} from "../../src/LPPositionManager.sol";
import {ManualAdjudicator} from "../../src/adjudicators/ManualAdjudicator.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IAmmFeeVault} from "../../src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../../src/interfaces/IBookFeeVault.sol";
import {IAMMEngine} from "../../src/interfaces/IAMMEngine.sol";

/// @notice Freely minted assets for an isolated local chain only.
contract LocalSmokeToken is ERC20 {
    uint8 private immutable _precision;

    constructor(string memory symbol_, uint8 precision_) ERC20(symbol_, symbol_) {
        require(block.chainid == 31_337, "LOCAL_CHAIN_ONLY");
        _precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return _precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Local-only acceptance workflow. Uses public Anvil development accounts.
/// @dev run-local-smoke.py additionally verifies loopback RPC and Anvil client identity.
contract LocalSmoke is Script {
    string private constant MNEMONIC =
        "test test test test test test test test test test test junk";
    string private constant MANIFEST = "deployments/local/factory-smoke.json";
    bytes32 private constant RELEASE = keccak256("local-smoke-release-v1");

    struct State {
        address registry;
        address factory;
        address stable;
        address community;
        NodeTypes.Addresses a;
        NodeTypes.Addresses b;
        address adjudicatorA;
        address adjudicatorB;
        address[6] markets;
        uint256[6] bootstrap;
        uint256 addedPosition;
        uint256 timeoutRefund;
        uint256[2] ammSellPayoutsNative;
        uint256 deploymentBlock;
        NodeTypes.Request requestA;
        NodeTypes.Request requestB;
        NodeTypes.BookPolicy bookPolicyA;
        NodeTypes.BookPolicy bookPolicyB;
        address deployerA;
        address deployerB;
        bytes32[12] artifactHashes;
        bytes32[6] creationHashes;
        bytes32 releaseManifestHash;
        string interfaceVersion;
        bytes32 sdkAbiHash;
    }
    State private s;

    function _key(uint32 index) private returns (uint256) {
        return vm.deriveKey(MNEMONIC, index);
    }

    function _actor(uint32 index) private returns (address) {
        return vm.addr(_key(index));
    }

    function _start(uint32 index) private {
        vm.startBroadcast(_key(index));
    }

    function _guard() private view {
        require(block.chainid == 31_337, "LOCAL_CHAIN_ONLY");
    }

    /// @notice Phase 1: deploy, configure, create and fund both nodes.
    function run() external {
        _guard();
        s.deploymentBlock = block.number;
        _deployRelease();
        s.a = _createNode(1, bytes32(uint256(1)), false);
        s.b = _createNode(2, bytes32(uint256(2)), true);
        s.adjudicatorA = _activate(s.a, 1);
        s.adjudicatorB = _activate(s.b, 2);
        _fundActors();
        for (uint256 i; i < 5; ++i) {
            bool second = i == 4;
            NodeTypes.Addresses memory a = second ? s.b : s.a;
            (s.markets[i], s.bootstrap[i]) = _createMarket(
                a,
                second ? s.adjudicatorB : s.adjudicatorA,
                second ? 2 : 1,
                i == 1 ? s.community : s.stable,
                i
            );
        }
        _reconcile();
        _write("deployed");
    }

    /// @notice Phase 2: runner advances Anvil past the explicitly scheduled opening.
    function tradeAndResolve() external {
        _guard();
        _load();
        _addSponsorship();
        for (uint256 i; i < 5; ++i) {
            _tradeAmm(i);
            _tradeBook(i, i == 3);
        }
        require(
            OrderEngine(s.a.book).getNet(s.markets[3], _actor(6)) == 0, "TAKER_NOT_CLOSED"
        );
        s.timeoutRefund =
            IBookFeeVault(s.a.bookVault).refundableResolutionOf(s.markets[3], _actor(6));
        require(s.timeoutRefund > 0, "NO_TIMEOUT_REFUND_ACCRUED");
        _transferAndPublish();
        (s.markets[5], s.bootstrap[5]) =
            _createMarket(s.a, s.adjudicatorA, 8, s.stable, 5);
        _resolveWithVeto();
        _reconcile();
        _write("traded");
    }

    function _deployRelease() private {
        address protocol = _actor(3);
        _start(0);
        s.stable = address(new LocalSmokeToken("LOCAL_USD", 6));
        s.community = address(new LocalSmokeToken("LOCAL_COMM", 18));
        ReleaseRegistry registry = new ReleaseRegistry(protocol);
        s.registry = address(registry);
        TruthMarket truth = new TruthMarket();
        ReleaseRegistry.CodeInput[6] memory codes;
        string[6] memory names = [
            "NodeRoles.sol:NodeRoles",
            "OrderEngine.sol:OrderEngine",
            "AMMEngine.sol:AMMEngine",
            "AmmFeeVault.sol:AmmFeeVault",
            "BookFeeVault.sol:BookFeeVault",
            "MarketFactory.sol:MarketFactory"
        ];
        for (uint256 i; i < 6; ++i) {
            codes[i] = _store(vm.getCode(names[i]));
            s.creationHashes[i] = codes[i].creationHash;
        }
        string[12] memory artifactNames = [
            "NodeRoles",
            "OrderEngine",
            "AMMEngine",
            "AmmFeeVault",
            "BookFeeVault",
            "MarketFactory",
            "NodeDeployer",
            "TruthMarket",
            "LPPositionManager",
            "VenueFeeVault",
            "NodeFactory",
            "ReleaseRegistry"
        ];
        for (uint256 i; i < 12; ++i) {
            s.artifactHashes[i] = keccak256(
                bytes(
                    vm.readFile(
                        string.concat(
                            "out/", artifactNames[i], ".sol/", artifactNames[i], ".json"
                        )
                    )
                )
            );
        }
        string memory sdkBundle = vm.readFile("sdk/abi.json");
        s.interfaceVersion = vm.parseJsonString(sdkBundle, ".interfaceVersion");
        require(
            keccak256(bytes(s.interfaceVersion)) == keccak256("sooth-factory-v0.1.0"),
            "SDK_INTERFACE_VERSION"
        );
        s.sdkAbiHash = keccak256(bytes(sdkBundle));
        s.releaseManifestHash = keccak256(
            abi.encode(
                bytes20(hex"5d56b26198e716a8fc82cea3af1bf415c770549a"),
                s.artifactHashes,
                s.interfaceVersion,
                s.sdkAbiHash
            )
        );
        vm.stopBroadcast();
        _start(3);
        registry.setStablecoin(s.stable, true);
        registry.publishBookPolicy(
            s.stable,
            NodeTypes.BookPolicy(
                protocol,
                protocol,
                500,
                IBookFeeVault.BookConfig(100, 2000, 8000, protocol)
            )
        );
        registry.publishRelease(
            RELEASE,
            bytes20(hex"5d56b26198e716a8fc82cea3af1bf415c770549a"),
            s.releaseManifestHash,
            address(truth),
            keccak256(vm.getCode("NodeDeployer.sol:NodeDeployer")),
            codes
        );
        vm.stopBroadcast();
        _start(0);
        s.factory = address(new NodeFactory(s.registry));
        vm.stopBroadcast();
    }

    function _store(bytes memory code)
        private
        returns (ReleaseRegistry.CodeInput memory input)
    {
        input.length = uint32(code.length);
        input.creationHash = keccak256(code);
        uint256 count = (code.length + 24_574) / 24_575;
        input.chunks = new address[](count);
        for (uint256 c; c < count; ++c) {
            uint256 offset = c * 24_575;
            uint256 length = code.length - offset;
            if (length > 24_575) length = 24_575;
            bytes memory chunk = new bytes(length);
            assembly ("memory-safe") {
                for { let i := 0 } lt(i, length) { i := add(i, 32) } {
                    mstore(
                        add(add(chunk, 32), i),
                        mload(add(add(code, 32), add(offset, i)))
                    )
                }
            }
            input.chunks[c] = address(new CreationCodeStore(chunk));
        }
    }

    function _createNode(uint32 operator, bytes32 salt, bool second)
        private
        returns (NodeTypes.Addresses memory a)
    {
        NodeTypes.Request memory r;
        r.releaseId = RELEASE;
        r.userSalt = salt;
        r.requester = _actor(operator);
        r.nodeAdmin = r.requester;
        r.bookToken = s.stable;
        r.ammSurplusRecipient = r.nodeAdmin;
        r.expiry = uint64(block.timestamp + 1 days);
        ReleaseRegistry registry = ReleaseRegistry(s.registry);
        r.expectedBookPolicyVersion = registry.activeBookPolicyVersion(s.stable);
        r.expectedBookPolicyHash =
            registry.bookPolicyHash(s.stable, r.expectedBookPolicyVersion);
        NodeTypes.BookPolicy memory policy =
            registry.bookPolicy(s.stable, r.expectedBookPolicyVersion);
        r.ammConfig = IAmmFeeVault.AmmConfig(
            100, 0, second ? 7000 : 8000, 1000, second ? 2000 : 1000, r.nodeAdmin
        );
        NodeFactory factory = NodeFactory(s.factory);
        (address predicted, NodeTypes.Addresses memory expected) = factory.predictNode(r);
        _start(operator);
        (bytes32 id,) = factory.beginNode(r);
        require(
            factory.nodeDeployer(id) == address(0)
                && factory.pendingDeployer(id) == predicted,
            "PREMATURE_ACTIVATION"
        );
        vm.stopBroadcast();
        if (!second) {
            // The first node keeps its prepared policy even when different terms
            // become active before completion. The second node uses the new terms.
            NodeTypes.BookPolicy memory nextPolicy =
                registry.bookPolicy(s.stable, r.expectedBookPolicyVersion);
            nextPolicy.maxBookFeeBps += 100;
            _start(3);
            registry.publishBookPolicy(s.stable, nextPolicy);
            vm.stopBroadcast();
            require(
                registry.activeBookPolicyVersion(s.stable) > r.expectedBookPolicyVersion
                    && registry.bookPolicyHash(
                        s.stable, registry.activeBookPolicyVersion(s.stable)
                    ) != r.expectedBookPolicyHash,
                "POLICY_NOT_REPUBLISHED"
            );
        }
        _start(operator);
        (, NodeTypes.Addresses memory actual) = factory.completeNode(r);
        vm.stopBroadcast();
        require(
            factory.nodeDeployer(id) == predicted
                && keccak256(abi.encode(expected)) == keccak256(abi.encode(actual)),
            "PREDICTION_MISMATCH"
        );
        require(NodeDeployer(predicted).verifyWiring(), "WIRING");
        require(
            IBookFeeVault(actual.bookVault).maxFeeBps() == policy.maxBookFeeBps
                && IBookFeeVault(actual.bookVault).surplusRecipient()
                    == policy.bookSurplusRecipient
                && keccak256(
                    abi.encode(IBookFeeVault(actual.bookVault).configByVersion(1))
                ) == keccak256(abi.encode(policy.bookConfig))
                && NodeRoles(actual.roles).protocolAuthority()
                    == policy.protocolAuthority,
            "PINNED_BOOK_TERMS_CHANGED"
        );
        if (second) {
            s.requestB = r;
            s.bookPolicyB = policy;
            s.deployerB = predicted;
        } else {
            s.requestA = r;
            s.bookPolicyA = policy;
            s.deployerA = predicted;
        }
        return actual;
    }

    function _activate(NodeTypes.Addresses memory a, uint32 operator)
        private
        returns (address)
    {
        address guardian = _actor(5);
        address resolver = _actor(4);
        address owner = _actor(operator);
        _start(operator);
        ManualAdjudicator adjudicator =
            new ManualAdjudicator(owner, a.marketFactory, 1 hours);
        adjudicator.approveGuardian(guardian);
        adjudicator.setResolutionRecipient(resolver);
        adjudicator.approveResolver(resolver);
        adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
        MarketFactory l = MarketFactory(a.marketFactory);
        l.setInvalidationBuffer(7 days);
        l.setTokenAllowed(s.stable, true, l.TOKEN_RISK_ACKNOWLEDGEMENT());
        l.setTokenAllowed(s.community, true, l.TOKEN_RISK_ACKNOWLEDGEMENT());
        l.setAdjudicatorAllowed(address(adjudicator), true);
        vm.stopBroadcast();
        return address(adjudicator);
    }

    function _fundActors() private {
        address[] memory actors = new address[](10);
        for (uint32 i; i < 10; ++i) {
            actors[i] = _actor(i);
        }
        _start(0);
        for (uint256 i; i < actors.length; ++i) {
            LocalSmokeToken(s.stable).mint(actors[i], 10_000e6);
            LocalSmokeToken(s.community).mint(actors[i], 10_000e18);
        }
        vm.stopBroadcast();
        for (uint32 i = 1; i < 10; ++i) {
            _start(i);
            LocalSmokeToken(s.stable).approve(s.a.marketFactory, 1000e6);
            LocalSmokeToken(s.stable).approve(s.b.marketFactory, 1000e6);
            LocalSmokeToken(s.community).approve(s.a.marketFactory, 1000e18);
            LocalSmokeToken(s.stable).approve(s.a.amm, 1000e6);
            LocalSmokeToken(s.stable).approve(s.b.amm, 1000e6);
            LocalSmokeToken(s.community).approve(s.a.amm, 1000e18);
            LocalSmokeToken(s.stable).approve(s.a.book, 1000e6);
            LocalSmokeToken(s.stable).approve(s.b.book, 1000e6);
            vm.stopBroadcast();
        }
    }

    function _createMarket(
        NodeTypes.Addresses memory a,
        address adjudicator,
        uint32 operator,
        address token,
        uint256 index
    ) private returns (address market, uint256 lp) {
        IMarketFactory.MarketParams memory p;
        p.question = string.concat("Local acceptance market ", vm.toString(index));
        p.startTime = uint64(block.timestamp + 1 hours);
        p.deadline = uint64(block.timestamp + 2 days);
        p.adjudicator = adjudicator;
        p.tokenA = token;
        p.bBase = 100e18;
        p.initialProbabilityWad = 0.5e18;
        p.adjudicatorConfig =
            abi.encode(_actor(4), p.deadline, bytes("LOCAL_ONLY_EVIDENCE_FIXTURE"));
        p.maxInputNative = token == s.stable ? 100e6 : 100e18;
        p.quoteDeadline = uint64(block.timestamp + 1 days);
        p.expectedAmmVersion = IAmmFeeVault(a.ammVault).activeConfigVersion();
        p.expectedBookVersion = IBookFeeVault(a.bookVault).activeConfigVersion();
        p.expectedAmmHash = IAmmFeeVault(a.ammVault).configHash(p.expectedAmmVersion);
        p.expectedBookHash = IBookFeeVault(a.bookVault).configHash(p.expectedBookVersion);
        p.resolutionTermsHash = keccak256(abi.encode("LOCAL_ONLY", index));
        p.expectedProfileHash = ManualAdjudicator(adjudicator).profileHash();
        p.expectedInvalidationBuffer = MarketFactory(a.marketFactory).invalidationBuffer();
        _start(operator);
        (market, lp) = MarketFactory(a.marketFactory).createMarket(p);
        vm.stopBroadcast();
    }

    function _addSponsorship() private {
        AMMEngine amm = AMMEngine(s.a.amm);
        (uint256 amount, uint256 units, uint256 odds, bytes32 hash) =
            amm.quoteLiquidityWithState(s.markets[0], 10e18);
        IAMMEngine.LiquidityLimits memory limits = IAMMEngine.LiquidityLimits(
            amount, units, odds - 1, odds + 1, block.timestamp + 1 hours, hash
        );
        _start(7);
        (s.addedPosition,) = amm.increaseLiquidity(s.markets[0], 10e18, limits);
        vm.stopBroadcast();
    }

    function _tradeAmm(uint256 index) private {
        AMMEngine amm = AMMEngine(index == 4 ? s.b.amm : s.a.amm);
        _start(6);
        amm.tradePositions(s.markets[index], 1, int256(10e18), 10e18);
        vm.stopBroadcast();
        if (index <= 1) _sellAmm(amm, index);
    }

    function _sellAmm(AMMEngine amm, uint256 index) private {
        address market = s.markets[index];
        LocalSmokeToken token = LocalSmokeToken(amm.tokenAOf(market));
        uint256 unit = 10 ** (18 - token.decimals());
        address seller = _actor(6);
        uint256 sellerBefore = token.balanceOf(seller);
        uint256 engineBefore = token.balanceOf(address(amm));
        uint256 vaultBefore = token.balanceOf(s.a.ammVault);
        uint256 collateralBefore = amm.getMarketCollateral(market);
        _start(6);
        uint256 proceedsWad = amm.tradePositions(market, 1, -int256(2e18), 0);
        vm.stopBroadcast();
        uint256 paidNative = proceedsWad / unit;
        uint256 revenueNative = token.balanceOf(s.a.ammVault) - vaultBefore;
        require(
            token.balanceOf(seller) - sellerBefore == paidNative, "SELL_DIRECT_PAYOUT"
        );
        require(
            engineBefore - token.balanceOf(address(amm)) == paidNative + revenueNative,
            "SELL_CUSTODY_DELTA"
        );
        require(
            collateralBefore - amm.getMarketCollateral(market)
                == (paidNative + revenueNative) * unit,
            "SELL_REMAINDER_ATTRIBUTION"
        );
        (uint256 yes, uint256 no) = amm.getPosition(market, seller);
        require(yes == 8e18 && no == 0, "SELL_POSITION_DELTA");
        s.ammSellPayoutsNative[index] = paidNative;
    }

    function _bookTerms(uint8 outcome, uint8 action, uint128 amount, bool rest)
        private
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p.outcome = outcome;
        p.action = action;
        p.priceTick = 500;
        p.amount = amount;
        p.matchLimit = 64;
        p.validUntil = uint64(block.timestamp + 1 hours);
        p.rest = rest;
        p.maxTokenIn = action == 0 ? 100e6 : 0;
    }

    function _tradeBook(uint256 index, bool closeAll) private {
        address market = s.markets[index];
        OrderEngine book = OrderEngine(index == 4 ? s.b.book : s.a.book);
        _start(7);
        book.placeOrder(market, _bookTerms(0, 0, uint128(100e18), true));
        vm.stopBroadcast();
        _start(6);
        book.placeOrder(market, _bookTerms(1, 0, uint128(40e18), false));
        vm.stopBroadcast();
        _start(7);
        book.cancel(market, 1, 500);
        // The two complementary owners sell inventory to one another. Matching
        // burns a complete set; neither sale asks for fresh quote collateral.
        if (closeAll) book.placeOrder(market, _bookTerms(0, 1, uint128(40e18), true));
        vm.stopBroadcast();
        if (closeAll) {
            _start(6);
            book.placeOrder(market, _bookTerms(1, 1, uint128(40e18), false));
            vm.stopBroadcast();
            (uint256 yes, uint256 no) = book.getPosition(market, _actor(6));
            require(yes == 0 && no == 0, "TAKER_GROSS_NOT_CLOSED");
            (yes, no) = book.getPosition(market, _actor(7));
            require(yes == 0 && no == 0, "MAKER_GROSS_NOT_CLOSED");
        }
    }

    function _transferAndPublish() private {
        address nextAdmin = _actor(8);
        address nextProtocol = _actor(9);
        _start(1);
        NodeRoles(s.a.roles).proposeNodeAdmin(nextAdmin);
        vm.stopBroadcast();
        _start(8);
        NodeRoles(s.a.roles).acceptNodeAdmin();
        IAmmFeeVault(s.a.ammVault)
            .publishAmmConfig(IAmmFeeVault.AmmConfig(200, 0, 8000, 1000, 1000, nextAdmin));
        vm.stopBroadcast();
        _start(3);
        NodeRoles(s.a.roles).proposeProtocolAuthority(nextProtocol);
        vm.stopBroadcast();
        _start(9);
        NodeRoles(s.a.roles).acceptProtocolAuthority();
        IBookFeeVault(s.a.bookVault)
            .publishBookConfig(IBookFeeVault.BookConfig(200, 2000, 8000, nextProtocol));
        vm.stopBroadcast();
        require(
            IAmmFeeVault(s.a.ammVault).configOf(s.markets[0]).operatorRecipient
                == _actor(1),
            "OLD_AMM_RECIPIENT_CHANGED"
        );
        require(
            IBookFeeVault(s.a.bookVault).configOf(s.markets[0]).protocolRecipient
                == _actor(3),
            "OLD_BOOK_RECIPIENT_CHANGED"
        );
    }

    function _resolveWithVeto() private {
        _start(4);
        ManualAdjudicator(s.adjudicatorA).resolve(s.markets[0], 1, keccak256("first"));
        vm.stopBroadcast();
        _start(5);
        ManualAdjudicator(s.adjudicatorA).dispute(s.markets[0]);
        vm.stopBroadcast();
        require(
            !TruthMarket(s.markets[0]).isTradingOpen()
                && !TruthMarket(s.markets[0]).isLiquidityOpen(),
            "VETO_GATES"
        );
        _start(4);
        ManualAdjudicator(s.adjudicatorA).resolve(s.markets[0], 1, keccak256("corrected"));
        ManualAdjudicator(s.adjudicatorA).resolve(s.markets[1], 0, keccak256("no"));
        ManualAdjudicator(s.adjudicatorA).resolve(s.markets[2], 2, keccak256("invalid"));
        ManualAdjudicator(s.adjudicatorB).resolve(s.markets[4], 1, keccak256("node-b"));
        vm.stopBroadcast();
    }

    /// @notice Phase 3: runner advances local Anvil by three hours before calling.
    function settleNormal() external {
        _guard();
        _load();
        _start(0);
        for (uint256 i; i < 5; ++i) {
            if (i == 3) continue;
            ManualAdjudicator(i == 4 ? s.adjudicatorB : s.adjudicatorA)
                .settle(s.markets[i]);
        }
        vm.stopBroadcast();
        for (uint256 i; i < 5; ++i) {
            if (i != 3) _claims(i, false);
        }
        require(
            IBookFeeVault(s.a.bookVault).refundableResolutionOf(s.markets[2], _actor(6))
                == 0,
            "NORMAL_REFUND"
        );
        _reconcile();
        _write("normal-settled");
    }

    /// @notice Phase 4: runner advances local Anvil past the deadline plus buffer.
    function settleTimeout() external {
        _guard();
        _load();
        _start(0);
        TruthMarket(s.markets[3]).invalidate();
        TruthMarket(s.markets[5]).invalidate();
        vm.stopBroadcast();
        _claims(3, true);
        _claims(5, true);
        uint256 before = LocalSmokeToken(s.stable).balanceOf(_actor(6));
        _start(0);
        uint256 paid =
            IBookFeeVault(s.a.bookVault).claimTimeoutRefund(s.markets[3], _actor(6));
        uint256 replay =
            IBookFeeVault(s.a.bookVault).claimTimeoutRefund(s.markets[3], _actor(6));
        vm.stopBroadcast();
        require(paid == s.timeoutRefund && replay == 0, "REFUND_REPLAY");
        require(
            LocalSmokeToken(s.stable).balanceOf(_actor(6)) - before == paid,
            "REFUND_BALANCE"
        );
        _reconcile();
        _write("complete");
    }

    function _claims(uint256 index, bool timeout) private {
        NodeTypes.Addresses memory a = index == 4 ? s.b : s.a;
        address market = s.markets[index];
        AMMEngine amm = AMMEngine(a.amm);
        _start(0);
        IAmmFeeVault(a.ammVault).finalize(market);
        IBookFeeVault(a.bookVault).finalize(market);
        IAmmFeeVault(a.ammVault).claimOperatorFees(market);
        IBookFeeVault(a.bookVault).claimProtocolFees(market);
        if (!timeout) {
            IAmmFeeVault(a.ammVault).claimResolutionFees(market);
            IBookFeeVault(a.bookVault).claimResolutionFees(market);
        }
        vm.stopBroadcast();
        if (index != 5) {
            _start(6);
            amm.settlePosition(market);
            if (index != 3) OrderEngine(a.book).settlePosition(market);
            vm.stopBroadcast();
        }
        if (index != 3 && index != 5) {
            _start(7);
            OrderEngine(a.book).settlePosition(market);
            vm.stopBroadcast();
        }
        if (index == 0) {
            _start(7);
            uint256 units = LPPositionManager(a.positionManager)
                .balanceOf(_actor(7), s.addedPosition);
            amm.claimAvailable(market, s.addedPosition, units);
            vm.stopBroadcast();
        }
        uint32 holder = index == 4 ? 2 : (index == 5 ? 8 : 1);
        uint256 bootstrapUnits = LPPositionManager(a.positionManager)
            .balanceOf(_actor(holder), s.bootstrap[index]);
        _start(holder);
        amm.claimAvailable(market, s.bootstrap[index], bootstrapUnits);
        (uint256 principal, uint256 floor, uint256 fees) =
            amm.claimAvailable(market, s.bootstrap[index], 0);
        vm.stopBroadcast();
        require(principal == 0 && floor == 0 && fees == 0, "LP_REPLAY");
    }

    function _reconcile() private view {
        _reconcileNode(s.a, true);
        _reconcileNode(s.b, false);
    }

    function _reconcileNode(NodeTypes.Addresses memory a, bool first) private view {
        address[2] memory tokens = [s.stable, s.community];
        for (uint256 t; t < 2; ++t) {
            uint256 unit = 10 ** (18 - LocalSmokeToken(tokens[t]).decimals());
            require(
                LocalSmokeToken(tokens[t]).balanceOf(a.amm) * unit
                    >= AMMEngine(a.amm).totalLiabilitiesOf(tokens[t]),
                "AMM_INSOLVENT"
            );
            require(
                LocalSmokeToken(tokens[t]).balanceOf(a.ammVault)
                    >= IAmmFeeVault(a.ammVault).totalLiabilitiesOf(tokens[t]),
                "AMM_FEES_INSOLVENT"
            );
        }
        require(
            LocalSmokeToken(s.stable).balanceOf(a.bookVault)
                >= IBookFeeVault(a.bookVault).totalLiabilitiesOf(s.stable),
            "BOOK_FEES_INSOLVENT"
        );
        uint256 backing;
        for (uint256 i; i < 6; ++i) {
            if (s.markets[i] == address(0) || (first ? i == 4 : i != 4)) continue;
            backing += OrderEngine(a.book).getCollateralBacking(s.markets[i]);
        }
        require(
            LocalSmokeToken(s.stable).balanceOf(a.book)
                >= backing + OrderEngine(a.book).totalDeferred(),
            "BOOK_INSOLVENT"
        );
    }

    function _load() private {
        s = abi.decode(vm.parseJsonBytes(vm.readFile(MANIFEST), ".encoded"), (State));
    }

    function _write(string memory phase) private {
        string memory key = "localSmoke";
        vm.serializeString(key, "phase", phase);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "deploymentBlock", s.deploymentBlock);
        vm.serializeAddress(key, "registry", s.registry);
        vm.serializeAddress(key, "factory", s.factory);
        vm.serializeAddress(
            key, "truthImplementation", MarketFactory(s.a.marketFactory).truthMarketImpl()
        );
        vm.serializeAddress(key, "stable", s.stable);
        vm.serializeAddress(key, "community", s.community);
        vm.serializeUint(key, "stableDecimals", 6);
        vm.serializeUint(key, "communityDecimals", 18);
        vm.serializeAddress(key, "nodeA_roles", s.a.roles);
        vm.serializeAddress(key, "nodeA_marketFactory", s.a.marketFactory);
        vm.serializeAddress(key, "nodeA_amm", s.a.amm);
        vm.serializeAddress(key, "nodeA_book", s.a.book);
        vm.serializeAddress(key, "nodeA_ammVault", s.a.ammVault);
        vm.serializeAddress(key, "nodeA_bookVault", s.a.bookVault);
        vm.serializeAddress(key, "nodeA_positionManager", s.a.positionManager);
        vm.serializeAddress(key, "nodeB_roles", s.b.roles);
        vm.serializeAddress(key, "nodeB_marketFactory", s.b.marketFactory);
        vm.serializeAddress(key, "nodeB_amm", s.b.amm);
        vm.serializeAddress(key, "nodeB_book", s.b.book);
        vm.serializeAddress(key, "nodeB_ammVault", s.b.ammVault);
        vm.serializeAddress(key, "nodeB_bookVault", s.b.bookVault);
        vm.serializeAddress(key, "nodeB_positionManager", s.b.positionManager);
        vm.serializeAddress(key, "adjudicatorA", s.adjudicatorA);
        vm.serializeAddress(key, "adjudicatorB", s.adjudicatorB);
        address[] memory markets = new address[](6);
        for (uint256 i; i < 6; ++i) {
            markets[i] = s.markets[i];
        }
        vm.serializeAddress(key, "markets", markets);
        vm.serializeUint(key, "timeoutRefundNative", s.timeoutRefund);
        // Decimal strings preserve eighteen-decimal token amounts through JSON
        // parsers whose numeric type cannot represent every uint256 exactly.
        string[] memory sellPayouts = new string[](2);
        sellPayouts[0] = vm.toString(s.ammSellPayoutsNative[0]);
        sellPayouts[1] = vm.toString(s.ammSellPayoutsNative[1]);
        vm.serializeString(key, "ammSellPayoutsNative", sellPayouts);
        address[] memory actors = new address[](10);
        for (uint32 i; i < 10; ++i) {
            actors[i] = _actor(i);
        }
        vm.serializeAddress(key, "actors", actors);
        vm.serializeBytes(key, "requestA", abi.encode(s.requestA));
        vm.serializeBytes(key, "requestB", abi.encode(s.requestB));
        vm.serializeBytes(key, "bookPolicyA", abi.encode(s.bookPolicyA));
        vm.serializeBytes(key, "bookPolicyB", abi.encode(s.bookPolicyB));
        vm.serializeBytes32(
            key, "requestAHash", NodeTypes.requestHash(s.factory, s.requestA)
        );
        vm.serializeBytes32(
            key, "requestBHash", NodeTypes.requestHash(s.factory, s.requestB)
        );
        vm.serializeAddress(key, "nodeA_deployer", s.deployerA);
        vm.serializeAddress(key, "nodeB_deployer", s.deployerB);
        vm.serializeBytes32(key, "releaseManifestHash", s.releaseManifestHash);
        vm.serializeString(key, "interfaceVersion", s.interfaceVersion);
        vm.serializeBytes32(key, "sdkAbiHash", s.sdkAbiHash);
        bytes32[] memory artifactHashes = new bytes32[](12);
        bytes32[] memory creationHashes = new bytes32[](6);
        for (uint256 i; i < 12; ++i) {
            artifactHashes[i] = s.artifactHashes[i];
        }
        for (uint256 i; i < 6; ++i) {
            creationHashes[i] = s.creationHashes[i];
        }
        vm.serializeBytes32(key, "artifactHashes", artifactHashes);
        vm.serializeBytes32(key, "creationHashes", creationHashes);
        string memory json = vm.serializeBytes(key, "encoded", abi.encode(s));
        vm.writeJson(json, MANIFEST);
    }
}
