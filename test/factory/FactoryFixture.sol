// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NodeTypes} from "../../src/factory/NodeTypes.sol";
import {NodeFactory} from "../../src/factory/NodeFactory.sol";
import {NodeDeployer} from "../../src/factory/NodeDeployer.sol";
import {ReleaseRegistry} from "../../src/factory/ReleaseRegistry.sol";
import {CreationCodeStore} from "../../src/factory/CreationCodeStore.sol";
import {NodeRoles} from "../../src/policy/NodeRoles.sol";
import {TruthMarket} from "../../src/TruthMarket.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IAmmFeeVault} from "../../src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../../src/interfaces/IBookFeeVault.sol";
import {ManualAdjudicator} from "../../src/adjudicators/ManualAdjudicator.sol";

contract FactoryToken is ERC20 {
    uint8 private immutable _precision;

    constructor(string memory name_, uint8 precision_) ERC20(name_, name_) {
        _precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return _precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Real release/factory fixture. Numerical policy is test data, not a production default.
abstract contract FactoryFixture is Test {
    bytes32 internal constant RELEASE = keccak256("local-factory-v1");
    address internal admin = address(0xA11CE);
    address internal secondAdmin = address(0xA22CE);
    address internal protocol = address(0xB0B);
    address internal guardian = address(0x600D);
    address internal resolver = address(0xDECA);
    ReleaseRegistry internal registry;
    NodeFactory internal factory;
    TruthMarket internal truthImplementation;
    FactoryToken internal stable;
    FactoryToken internal community;

    function setUp() public virtual {
        stable = new FactoryToken("USD-local", 6);
        community = new FactoryToken("COMM-local", 18);
        registry = new ReleaseRegistry(address(this));
        registry.setStablecoin(address(stable), true);
        registry.publishBookPolicy(address(stable), _bookPolicy());
        truthImplementation = new TruthMarket();
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
            codes[i] = _storeCode(vm.getCode(names[i]));
        }
        registry.publishRelease(
            RELEASE,
            bytes20(hex"5d56b26198e716a8fc82cea3af1bf415c770549a"),
            keccak256("local-test-manifest"),
            address(truthImplementation),
            keccak256(vm.getCode("NodeDeployer.sol:NodeDeployer")),
            codes
        );
        factory = new NodeFactory(address(registry));
    }

    function _storeCode(bytes memory code)
        internal
        returns (ReleaseRegistry.CodeInput memory input)
    {
        uint256 count = (code.length + 24_574) / 24_575;
        input.chunks = new address[](count);
        input.creationHash = keccak256(code);
        input.length = uint32(code.length);
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

    function _request(address operator, bytes32 salt)
        internal
        view
        returns (NodeTypes.Request memory r)
    {
        r.releaseId = RELEASE;
        r.userSalt = salt;
        r.requester = operator;
        r.nodeAdmin = operator;
        r.bookToken = address(stable);
        r.ammSurplusRecipient = operator;
        r.expiry = uint64(block.timestamp + 1 days);
        r.expectedBookPolicyVersion = registry.activeBookPolicyVersion(r.bookToken);
        r.expectedBookPolicyHash =
            registry.bookPolicyHash(r.bookToken, r.expectedBookPolicyVersion);
        r.ammConfig = IAmmFeeVault.AmmConfig(100, 0, 8000, 1000, 1000, operator);
    }

    function _bookPolicy() internal view returns (NodeTypes.BookPolicy memory) {
        return NodeTypes.BookPolicy(
            protocol, protocol, 500, IBookFeeVault.BookConfig(100, 2000, 8000, protocol)
        );
    }

    function _approve(NodeTypes.Request memory r) internal {
        bytes32 hash = factory.requestHash(r);
        vm.prank(r.nodeAdmin);
        factory.approveRequest(hash);
    }

    function _deployNode(address operator, bytes32 salt)
        internal
        returns (NodeTypes.Addresses memory a)
    {
        NodeTypes.Request memory r = _request(operator, salt);
        vm.prank(operator);
        factory.beginNode(r);
        vm.prank(operator);
        (, a) = factory.completeNode(r);
    }

    /// @dev `early` false is the shipped default: resolution opens at the deadline.
    function _profile(NodeTypes.Addresses memory a, address operator, bool early)
        internal
        returns (ManualAdjudicator adjudicator)
    {
        adjudicator = new ManualAdjudicator(operator, a.marketFactory, 1 hours);
        vm.startPrank(operator);
        adjudicator.approveGuardian(guardian);
        adjudicator.setResolutionRecipient(resolver);
        adjudicator.approveResolver(resolver);
        if (early) adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
        vm.stopPrank();
    }

    function _activate(NodeTypes.Addresses memory a, address operator)
        internal
        returns (ManualAdjudicator adjudicator)
    {
        adjudicator = _profile(a, operator, true);
        vm.startPrank(operator);
        MarketFactory l = MarketFactory(a.marketFactory);
        l.setInvalidationBuffer(7 days);
        l.setTokenAllowed(address(stable), true, l.TOKEN_RISK_ACKNOWLEDGEMENT());
        l.setTokenAllowed(address(community), true, l.TOKEN_RISK_ACKNOWLEDGEMENT());
        l.setAdjudicatorAllowed(address(adjudicator), true);
        vm.stopPrank();
    }

    function _params(
        NodeTypes.Addresses memory a,
        ManualAdjudicator adjudicator,
        address token
    ) internal view returns (IMarketFactory.MarketParams memory p) {
        p.question = "Local factory test question";
        p.startTime = uint64(block.timestamp);
        p.deadline = uint64(block.timestamp + 2 days);
        p.adjudicator = address(adjudicator);
        p.tokenA = token;
        p.bBase = 100e18;
        p.initialProbabilityWad = 0.5e18;
        p.adjudicatorConfig =
            abi.encode(resolver, p.deadline, bytes("local evidence terms"));
        p.maxInputNative = 100 * 10 ** FactoryToken(token).decimals();
        p.quoteDeadline = uint64(block.timestamp + 5 minutes);
        p.expectedAmmVersion = IAmmFeeVault(a.ammVault).activeConfigVersion();
        p.expectedBookVersion = IBookFeeVault(a.bookVault).activeConfigVersion();
        p.expectedAmmHash = IAmmFeeVault(a.ammVault).configHash(p.expectedAmmVersion);
        p.expectedBookHash = IBookFeeVault(a.bookVault).configHash(p.expectedBookVersion);
        p.resolutionTermsHash = keccak256("local evidence/source/tie rules");
        p.expectedProfileHash = adjudicator.profileHash();
        p.expectedInvalidationBuffer = MarketFactory(a.marketFactory).invalidationBuffer();
    }

    function _fund(address operator, address marketFactory, FactoryToken token) internal {
        token.mint(operator, 10_000 * 10 ** token.decimals());
        vm.prank(operator);
        token.approve(marketFactory, type(uint256).max);
    }
}
