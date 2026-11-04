// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {FactoryFixture, FactoryToken} from "./FactoryFixture.sol";
import {NodeTypes} from "../../src/factory/NodeTypes.sol";
import {NodeFactory} from "../../src/factory/NodeFactory.sol";
import {NodeDeployer} from "../../src/factory/NodeDeployer.sol";
import {NodeVerifier} from "../../src/factory/NodeVerifier.sol";
import {ReleaseRegistry} from "../../src/factory/ReleaseRegistry.sol";
import {CreationCodeStore} from "../../src/factory/CreationCodeStore.sol";
import {NodeRoles} from "../../src/policy/NodeRoles.sol";
import {IAmmFeeVault} from "../../src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../../src/interfaces/IBookFeeVault.sol";
import {OrderEngine} from "../../src/OrderEngine.sol";
import {AMMEngine} from "../../src/AMMEngine.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MutableMetadataToken is ERC20 {
    uint8 private _precision = 6;
    constructor() ERC20("Mutable test", "MUT") {}

    function decimals() public view override returns (uint8) {
        return _precision;
    }

    function setDecimals(uint8 value) external {
        _precision = value;
    }
}

contract FactoryDeploymentTest is FactoryFixture {
    function test_RealFactoryDeploysPredictedIndependentNodesUnderLimits() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(1)));
        (address predicted, NodeTypes.Addresses memory expected) = factory.predictNode(r);
        uint256 beforeGas = gasleft();
        vm.prank(admin);
        (bytes32 id,) = factory.beginNode(r);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("factory prepare gas", used);
        assertLt(used, 16_000_000);
        assertEq(factory.nodeDeployer(id), address(0));
        assertEq(factory.nodeCount(), 0);
        assertEq(expected.marketFactory.code.length, 0);
        beforeGas = gasleft();
        vm.prank(admin);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        used = beforeGas - gasleft();
        emit log_named_uint("factory complete gas", used);
        assertLt(used, 16_000_000);
        assertEq(factory.nodeDeployer(id), predicted);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(expected)));
        assertEq(vm.getNonce(predicted), 7);
        assertEq(vm.getNonce(a.amm), 2);
        assertTrue(NodeDeployer(predicted).verifyWiring());
        assertLe(predicted.code.length, 24_576);
        assertLe(address(factory).code.length, 24_576);
        NodeTypes.Addresses memory b = _deployNode(secondAdmin, bytes32(uint256(2)));
        assertNotEq(a.amm, b.amm);
        assertNotEq(a.ammVault, b.ammVault);
        assertNotEq(a.book, b.book);
        assertNotEq(a.bookVault, b.bookVault);
        assertEq(NodeRoles(a.roles).nodeAdmin(), admin);
        assertEq(NodeRoles(b.roles).nodeAdmin(), secondAdmin);
        assertEq(factory.nodeCount(), 2);
    }

    function test_OnlyNamedAdminMustAuthorizeExactRequest() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(3)));
        r.requester = address(this);
        bytes32 hash = factory.requestHash(r);
        vm.prank(protocol);
        factory.approveRequest(hash); // Protocol consent cannot impersonate node admin.
        vm.expectRevert(NodeFactory.Unauthorized.selector);
        factory.beginNode(r);
        vm.prank(admin);
        factory.approveRequest(hash);
        r.ammSurplusRecipient = address(this);
        vm.expectRevert(NodeFactory.Unauthorized.selector);
        factory.beginNode(r);
        r.ammSurplusRecipient = admin;
        factory.beginNode(r);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        assertEq(NodeRoles(a.roles).nodeAdmin(), admin);
        assertEq(NodeRoles(a.roles).protocolAuthority(), protocol);
        assertFalse(factory.approvedRequests(admin, hash));
    }

    function test_RequesterAndStandingBookPolicyCannotBeSpoofed() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(4)));
        vm.expectRevert(NodeFactory.Unauthorized.selector);
        factory.beginNode(r);
        NodeTypes.BookPolicy memory forged = _bookPolicy();
        forged.protocolAuthority = admin;
        forged.bookConfig.protocolRecipient = admin;
        forged.bookSurplusRecipient = admin;
        forged.bookConfig.feeBps = 0;
        r.expectedBookPolicyHash = keccak256(abi.encode(forged));
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.beginNode(r);
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.Unauthorized.selector);
        registry.publishBookPolicy(address(stable), forged);
    }

    function test_RevokedAdminConsentAndStalePolicyRejectBegin() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(5)));
        r.requester = address(this);
        _approve(r);
        bytes32 hash = factory.requestHash(r);
        vm.prank(admin);
        factory.revokeRequest(hash);
        vm.expectRevert(NodeFactory.Unauthorized.selector);
        factory.beginNode(r);
        _approve(r);
        registry.publishBookPolicy(address(stable), _bookPolicy());
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.beginNode(r);
    }

    function test_DuplicateSaltCannotCreateAlternateParameters() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(6)));
        _approve(r);
        vm.prank(admin);
        factory.beginNode(r);
        vm.prank(admin);
        factory.completeNode(r);
        r.ammConfig.feeBps = 200;
        _approve(r);
        vm.prank(admin);
        vm.expectRevert(NodeFactory.NodeAlreadyExists.selector);
        factory.beginNode(r);
    }

    function test_FailedCompletionLeavesOnlyInertPreparationAndUnconsumedApproval()
        public
    {
        MutableMetadataToken token = new MutableMetadataToken();
        registry.setStablecoin(address(token), true);
        registry.publishBookPolicy(address(token), _bookPolicy());
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(7)));
        r.requester = address(this);
        r.bookToken = address(token);
        _approve(r);
        bytes32 hash = factory.requestHash(r);
        bytes32 id = factory.nodeId(r);
        (address deployer, NodeTypes.Addresses memory a) = factory.predictNode(r);
        factory.beginNode(r);
        token.setDecimals(19); // Unsupported precision is detected in the fifth child.
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(NodeDeployer.ChildDeploymentFailed.selector, uint8(4))
        );
        factory.completeNode(r);
        assertGt(deployer.code.length, 0);
        assertGt(a.roles.code.length, 0);
        assertGt(a.book.code.length, 0);
        assertGt(a.amm.code.length, 0);
        assertEq(a.ammVault.code.length, 0);
        assertEq(a.bookVault.code.length, 0);
        assertEq(a.marketFactory.code.length, 0);
        assertEq(factory.pendingDeployer(id), deployer);
        assertEq(factory.nodeDeployer(id), address(0));
        assertEq(factory.nodeCount(), 0);
        assertFalse(NodeDeployer(deployer).deployed());
        assertTrue(factory.approvedRequests(admin, hash));
        _assertNoActivationLogs();
    }

    function test_BeginRejectsAmmTermsTheSecondStageCannotDeploy() public {
        bytes32 salt = bytes32(uint256(70));
        NodeTypes.Request memory good = _request(admin, salt);
        bytes32 id = factory.nodeId(good);
        (address deployer,) = factory.predictNode(good);
        for (uint256 i; i < 6; ++i) {
            NodeTypes.Request memory r = _request(admin, salt);
            if (i == 0) r.ammSurplusRecipient = address(0);
            if (i == 1) r.ammConfig.operatorRecipient = address(0);
            if (i == 2) r.ammConfig.feeBps = 10_001;
            if (i == 3) r.ammConfig.operatorBps = 2000; // sum above 10_000
            if (i == 4) r.ammConfig.lpBps = 7999; // sum below 10_000
            if (i == 5) {
                r.ammConfig = IAmmFeeVault.AmmConfig(100, 65_535, 1, 0, 0, admin);
            }
            assertEq(factory.nodeId(r), id);
            vm.prank(admin);
            vm.expectRevert(NodeFactory.InvalidRequest.selector);
            factory.beginNode(r);
        }
        // A rejected request reserves nothing: the same salt serves the valid request.
        assertEq(factory.pendingDeployer(id), address(0));
        assertEq(factory.pendingRequestHash(id), bytes32(0));
        assertEq(deployer.code.length, 0);
        vm.prank(admin);
        factory.beginNode(good);
        vm.prank(admin);
        factory.completeNode(good);
        assertEq(factory.nodeDeployer(id), deployer);
        assertTrue(NodeDeployer(deployer).verifyWiring());
    }

    function test_RevocationBlocksFutureNodesAndDoesNotDisableExistingWiring() public {
        NodeTypes.Addresses memory a = _deployNode(admin, bytes32(uint256(8)));
        NodeTypes.Request memory r = _request(secondAdmin, bytes32(uint256(9)));
        _approve(r);
        registry.revokeRelease(RELEASE);
        vm.prank(secondAdmin);
        vm.expectRevert(NodeFactory.InvalidRelease.selector);
        factory.beginNode(r);
        vm.prank(admin);
        NodeRoles(a.roles).proposeNodeAdmin(secondAdmin);
        vm.prank(secondAdmin);
        NodeRoles(a.roles).acceptNodeAdmin();
        bytes32 firstId = factory.nodeIdAt(0);
        assertTrue(NodeDeployer(factory.nodeDeployer(firstId)).verifyWiring());
    }

    function test_OneShotAndCrossRoleConfiguration() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(10)));
        _approve(r);
        vm.prank(admin);
        factory.beginNode(r);
        vm.prank(admin);
        (bytes32 id, NodeTypes.Addresses memory a) = factory.completeNode(r);
        NodeDeployer d = NodeDeployer(factory.nodeDeployer(id));
        vm.expectRevert(NodeDeployer.Unauthorized.selector);
        d.prepare(r);
        vm.prank(address(factory));
        vm.expectRevert(NodeDeployer.AlreadyDeployed.selector);
        d.prepare(r);
        vm.prank(protocol);
        vm.expectRevert();
        IAmmFeeVault(a.ammVault).publishAmmConfig(r.ammConfig);
        vm.prank(admin);
        vm.expectRevert();
        IBookFeeVault(a.bookVault).publishBookConfig(_bookPolicy().bookConfig);
    }

    function test_IndependentTwoStepTransfersAndCanceledNomination() public {
        NodeRoles roles = new NodeRoles(admin, protocol, address(0));
        vm.prank(protocol);
        vm.expectRevert(NodeRoles.Unauthorized.selector);
        roles.proposeNodeAdmin(secondAdmin);
        vm.prank(admin);
        roles.proposeNodeAdmin(secondAdmin);
        vm.prank(protocol);
        roles.proposeProtocolAuthority(resolver);
        vm.prank(admin);
        roles.cancelNodeAdminTransfer();
        vm.prank(secondAdmin);
        vm.expectRevert(NodeRoles.Unauthorized.selector);
        roles.acceptNodeAdmin();
        vm.prank(resolver);
        roles.acceptProtocolAuthority();
        assertEq(roles.nodeAdmin(), admin);
        assertEq(roles.protocolAuthority(), resolver);
    }

    function test_RuntimeContinuityVerifierRejectsCodeReplacement() public {
        NodeTypes.Addresses memory a = _deployNode(admin, bytes32(uint256(12)));
        NodeDeployer deployer = NodeDeployer(factory.nodeDeployer(factory.nodeIdAt(0)));
        bytes memory original = a.roles.code;
        vm.etch(a.roles, bytes.concat(original, hex"00")); // Same entry points/getters, different code.
        assertEq(NodeRoles(a.roles).nodeAdmin(), admin);
        vm.expectRevert(
            abi.encodeWithSelector(NodeDeployer.InvalidRuntimeCode.selector, uint8(0))
        );
        deployer.verifyWiring();
    }

    function test_PendingRequiresExactRequestAndCannotRegisterMarkets() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(13)));
        _approve(r);
        (address deployer, NodeTypes.Addresses memory a) = factory.predictNode(r);
        vm.recordLogs();
        vm.prank(admin);
        (bytes32 id,) = factory.beginNode(r);
        _assertNoActivationLogs();
        assertEq(factory.pendingDeployer(id), deployer);
        assertEq(factory.pendingRequestHash(id), factory.requestHash(r));
        assertEq(factory.nodeCount(), 0);
        assertEq(factory.nodeDeployer(id), address(0));
        assertEq(vm.getNonce(deployer), 4);
        assertEq(a.marketFactory.code.length, 0);
        vm.prank(admin);
        vm.expectRevert();
        OrderEngine(a.book).registerMarket(address(0x123), address(stable), 0.5e18);
        vm.prank(admin);
        vm.expectRevert();
        AMMEngine(a.amm)
            .initializeMarket(address(0x123), address(stable), 6, 1e18, 1e18, 1e18, 1e18);
        vm.prank(admin);
        vm.expectRevert(NodeFactory.NodeAlreadyExists.selector);
        factory.beginNode(r);
        r.ammConfig.feeBps = 200;
        _approve(r);
        vm.prank(admin);
        vm.expectRevert(NodeFactory.InvalidRequest.selector);
        factory.completeNode(r);
        assertEq(factory.nodeCount(), 0);
    }

    function test_CompletionRechecksAdminConsentAndConsumesOnlyAfterSuccess() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(14)));
        r.requester = address(this);
        _approve(r);
        bytes32 hash = factory.requestHash(r);
        factory.beginNode(r);
        assertTrue(factory.approvedRequests(admin, hash));
        vm.prank(admin);
        factory.revokeRequest(hash);
        vm.expectRevert(NodeFactory.Unauthorized.selector);
        factory.completeNode(r);
        vm.prank(admin);
        factory.approveRequest(hash);
        factory.completeNode(r);
        assertFalse(factory.approvedRequests(admin, hash));
        assertEq(factory.nodeCount(), 1);
        _approve(r);
        vm.expectRevert(NodeFactory.InvalidRequest.selector);
        factory.completeNode(r);
    }

    function test_CompletionRechecksExpiryTokenAndReleaseAfterRepublication() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(15)));
        vm.prank(admin);
        factory.beginNode(r);
        registry.publishBookPolicy(address(stable), _changedBookPolicy());
        uint256 initial = vm.snapshotState();
        vm.warp(uint256(r.expiry) + 1);
        vm.prank(admin);
        vm.expectRevert(NodeFactory.InvalidRequest.selector);
        factory.completeNode(r);
        vm.revertToState(initial);
        registry.setStablecoin(address(stable), false);
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.completeNode(r);
        vm.revertToState(initial);
        registry.revokeRelease(RELEASE);
        vm.prank(admin);
        vm.expectRevert(NodeFactory.InvalidRelease.selector);
        factory.completeNode(r);
        assertEq(factory.nodeCount(), 0);
    }

    function test_ChangedPreparedRolesCannotActivateAndCompletionRollsBack() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(16)));
        _approve(r);
        (, NodeTypes.Addresses memory a) = factory.predictNode(r);
        vm.prank(admin);
        factory.beginNode(r);
        vm.prank(admin);
        NodeRoles(a.roles).proposeNodeAdmin(secondAdmin);
        vm.prank(secondAdmin);
        NodeRoles(a.roles).acceptNodeAdmin();
        vm.prank(admin);
        vm.expectRevert(NodeVerifier.InvalidInitialState.selector);
        factory.completeNode(r);
        assertEq(a.marketFactory.code.length, 0);
        assertEq(a.ammVault.code.length, 0);
        assertEq(a.bookVault.code.length, 0);
        assertEq(factory.nodeCount(), 0);
    }

    function test_PreparedRuntimeReplacementCannotActivate() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(17)));
        _approve(r);
        (, NodeTypes.Addresses memory a) = factory.predictNode(r);
        vm.prank(admin);
        factory.beginNode(r);
        vm.etch(a.roles, bytes.concat(a.roles.code, hex"00"));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(NodeDeployer.InvalidRuntimeCode.selector, uint8(0))
        );
        factory.completeNode(r);
        assertEq(a.marketFactory.code.length, 0);
    }

    function test_MetadataChangeBetweenStagesCannotActivateMismatchedBookUnits() public {
        MutableMetadataToken token = new MutableMetadataToken();
        registry.setStablecoin(address(token), true);
        registry.publishBookPolicy(address(token), _bookPolicy());
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(18)));
        r.bookToken = address(token);
        _approve(r);
        (, NodeTypes.Addresses memory a) = factory.predictNode(r);
        vm.prank(admin);
        factory.beginNode(r);
        assertEq(OrderEngine(a.book).baseTokenDecimals(), 6);
        token.setDecimals(18);
        vm.prank(admin);
        vm.expectRevert(NodeVerifier.InvalidWiring.selector);
        factory.completeNode(r);
        assertEq(a.bookVault.code.length, 0);
        assertEq(a.marketFactory.code.length, 0);
        assertEq(factory.nodeCount(), 0);
        token.setDecimals(6);
        vm.prank(admin);
        factory.completeNode(r);
        assertEq(IBookFeeVault(a.bookVault).baseTokenDecimals(), 6);
        assertEq(factory.nodeCount(), 1);
    }

    function test_OperatorAloneReceivesExactStandingBookTerms() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(20)));
        vm.prank(admin);
        factory.beginNode(r);
        vm.prank(admin);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        NodeTypes.BookPolicy memory policy = _bookPolicy();
        assertEq(NodeRoles(a.roles).protocolAuthority(), policy.protocolAuthority);
        assertEq(
            IBookFeeVault(a.bookVault).surplusRecipient(), policy.bookSurplusRecipient
        );
        assertEq(IBookFeeVault(a.bookVault).maxFeeBps(), policy.maxBookFeeBps);
        assertEq(
            IBookFeeVault(a.bookVault).configHash(1),
            keccak256(abi.encode(policy.bookConfig))
        );
        assertEq(
            IAmmFeeVault(a.ammVault).configHash(1), keccak256(abi.encode(r.ammConfig))
        );
        assertEq(IAmmFeeVault(a.ammVault).surplusRecipient(), admin);
    }

    function test_MissingPolicyAndWrongHashOrVersionCannotBegin() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(21)));
        r.expectedBookPolicyHash = bytes32(uint256(1));
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.beginNode(r);
        r = _request(admin, bytes32(uint256(21)));
        r.expectedBookPolicyVersion = 0;
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.beginNode(r);
        registry.setStablecoin(address(community), true);
        r.bookToken = address(community);
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.beginNode(r);
    }

    function test_StandingPolicyCannotBeOverriddenByEachBookField() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(22)));
        for (uint256 field; field < 6; ++field) {
            NodeTypes.BookPolicy memory fake = _bookPolicy();
            if (field == 0) fake.protocolAuthority = admin;
            if (field == 1) fake.bookSurplusRecipient = admin;
            if (field == 2) fake.maxBookFeeBps = 0;
            if (field == 3) fake.bookConfig.feeBps = 0;
            if (field == 4) fake.bookConfig.protocolRecipient = admin;
            if (field == 5) {
                fake.bookConfig.protocolBps = 10_000;
                fake.bookConfig.resolutionBps = 0;
            }
            r.expectedBookPolicyHash = keccak256(abi.encode(fake));
            vm.prank(admin);
            vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
            factory.beginNode(r);
        }
    }

    function test_BookPolicyPublicationValidatesTermsAndPreservesHistory() public {
        NodeTypes.BookPolicy memory policy = _bookPolicy();
        bytes32 original = registry.bookPolicyHash(address(stable), 1);
        uint256 initial = vm.snapshotState();
        for (uint256 field; field < 7; ++field) {
            NodeTypes.BookPolicy memory bad = _bookPolicy();
            if (field == 0) bad.protocolAuthority = address(0);
            if (field == 1) bad.bookSurplusRecipient = address(0);
            if (field == 2) bad.bookConfig.protocolRecipient = address(0);
            if (field == 3) bad.maxBookFeeBps = 10_001;
            if (field == 4) bad.bookConfig.feeBps = 501;
            if (field == 5) bad.bookConfig.protocolBps = 8001;
            vm.expectRevert(ReleaseRegistry.InvalidBookPolicy.selector);
            registry.publishBookPolicy(
                field == 6 ? address(community) : address(stable), bad
            );
            vm.revertToState(initial);
        }
        policy = _bookPolicy();
        policy.protocolAuthority = resolver;
        assertEq(registry.publishBookPolicy(address(stable), policy), 2);
        assertEq(registry.bookPolicyHash(address(stable), 1), original);
        assertEq(registry.bookPolicy(address(stable), 1).protocolAuthority, protocol);
        assertEq(registry.bookPolicy(address(stable), 2).protocolAuthority, resolver);
    }

    function test_ExistingNodesIgnoreNewPolicyAndRetainBookGovernance() public {
        NodeTypes.Addresses memory a = _deployNode(admin, bytes32(uint256(23)));
        NodeTypes.BookPolicy memory changed = _bookPolicy();
        changed.protocolAuthority = resolver;
        changed.bookConfig.protocolRecipient = resolver;
        registry.publishBookPolicy(address(stable), changed);
        NodeTypes.Addresses memory b = _deployNode(secondAdmin, bytes32(uint256(24)));
        assertEq(NodeRoles(a.roles).protocolAuthority(), protocol);
        assertEq(NodeRoles(b.roles).protocolAuthority(), resolver);
        assertEq(
            IBookFeeVault(a.bookVault).configByVersion(1).protocolRecipient, protocol
        );
        vm.prank(protocol);
        assertEq(
            IBookFeeVault(a.bookVault).publishBookConfig(_bookPolicy().bookConfig), 2
        );
        vm.prank(resolver);
        vm.expectRevert();
        IBookFeeVault(a.bookVault).publishBookConfig(changed.bookConfig);
        registry.setStablecoin(address(stable), false);
        vm.prank(protocol);
        assertEq(
            IBookFeeVault(a.bookVault).publishBookConfig(_bookPolicy().bookConfig), 3
        );
    }

    function test_OperatorChoosesPartialOrFullCapitalWithoutGrowthSwitches() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(25)));
        r.ammConfig = IAmmFeeVault.AmmConfig(100, 5000, 3000, 1000, 1000, admin);
        vm.prank(admin);
        factory.beginNode(r);
        vm.prank(admin);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        assertEq(IAmmFeeVault(a.ammVault).configByVersion(1).capitalBps, 5000);
        r = _request(admin, bytes32(uint256(26)));
        r.ammConfig = IAmmFeeVault.AmmConfig(10_000, 10_000, 0, 0, 0, admin);
        vm.prank(admin);
        factory.beginNode(r);
        vm.prank(admin);
        (, a) = factory.completeNode(r);
        assertEq(IAmmFeeVault(a.ammVault).configByVersion(1).capitalBps, 10_000);
        assertEq(IAmmFeeVault(a.ammVault).configByVersion(1).feeBps, 10_000);
        assertEq(IAmmFeeVault(a.ammVault).maxFeeBps(), 10_000);
        assertTrue(NodeDeployer(factory.nodeDeployer(factory.nodeId(r))).verifyWiring());
    }

    function test_ProtocolCannotVetoPendingNodeByTransferringItsRole() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(27)));
        (address deployer, NodeTypes.Addresses memory a) = factory.predictNode(r);
        vm.prank(admin);
        factory.beginNode(r);
        assertFalse(NodeDeployer(deployer).activated());
        assertEq(NodeRoles(a.roles).activationGate(), deployer);
        vm.prank(protocol);
        vm.expectRevert(NodeRoles.NodeNotActive.selector);
        NodeRoles(a.roles).proposeProtocolAuthority(resolver);
        vm.prank(protocol);
        vm.expectRevert(NodeRoles.NodeNotActive.selector);
        NodeRoles(a.roles).cancelProtocolAuthorityTransfer();
        vm.prank(resolver);
        vm.expectRevert(NodeRoles.NodeNotActive.selector);
        NodeRoles(a.roles).acceptProtocolAuthority();
        vm.prank(admin);
        factory.completeNode(r);
        assertTrue(NodeDeployer(deployer).activated());
        vm.prank(protocol);
        NodeRoles(a.roles).proposeProtocolAuthority(resolver);
        vm.prank(resolver);
        NodeRoles(a.roles).acceptProtocolAuthority();
        assertEq(NodeRoles(a.roles).protocolAuthority(), resolver);
        assertTrue(NodeDeployer(deployer).verifyWiring());
    }

    function test_NewPolicyCannotReplacePendingCommitment() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(28)));
        uint32 pinnedVersion = r.expectedBookPolicyVersion;
        bytes32 pinnedPolicyHash = r.expectedBookPolicyHash;
        vm.prank(admin);
        (bytes32 id,) = factory.beginNode(r);
        bytes32 originalHash = factory.pendingRequestHash(id);
        registry.publishBookPolicy(address(stable), _changedBookPolicy());
        r.expectedBookPolicyVersion = registry.activeBookPolicyVersion(r.bookToken);
        r.expectedBookPolicyHash =
            registry.bookPolicyHash(r.bookToken, r.expectedBookPolicyVersion);
        vm.prank(admin);
        vm.expectRevert(NodeFactory.InvalidRequest.selector);
        factory.completeNode(r);
        assertEq(factory.pendingRequestHash(id), originalHash);
        assertEq(factory.nodeCount(), 0);
        r.expectedBookPolicyVersion = pinnedVersion;
        r.expectedBookPolicyHash = pinnedPolicyHash;
        vm.prank(admin);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        _assertBookPolicy(a, _bookPolicy());
    }

    function test_IdenticalRepublicationAllowsPendingCompletionWithPinnedTerms() public {
        _assertCompletionAfterRepublication(false);
    }

    function test_ChangedRepublicationAllowsPendingCompletionWithPinnedTerms() public {
        _assertCompletionAfterRepublication(true);
    }

    function test_WrongHistoricalPolicyHashCannotCompletePendingNode() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(31)));
        bytes32 pinnedPolicyHash = r.expectedBookPolicyHash;
        vm.prank(admin);
        (bytes32 id,) = factory.beginNode(r);
        bytes32 requestHash = factory.pendingRequestHash(id);
        registry.publishBookPolicy(address(stable), _changedBookPolicy());
        r.expectedBookPolicyHash = registry.bookPolicyHash(address(stable), 2);
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.completeNode(r);
        assertEq(factory.pendingRequestHash(id), requestHash);
        assertEq(factory.nodeCount(), 0);
        r.expectedBookPolicyHash = pinnedPolicyHash;
        vm.prank(admin);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        _assertBookPolicy(a, _bookPolicy());
    }

    function test_HistoricalPolicyValidationRejectsInvalidVersionAndHash() public {
        bytes32 pinnedHash = registry.bookPolicyHash(address(stable), 1);
        registry.publishBookPolicy(address(stable), _changedBookPolicy());
        assertEq(
            registry.validateBookPolicy(address(stable), 1, pinnedHash).protocolAuthority,
            protocol
        );
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        registry.validateActiveBookPolicy(address(stable), 1, pinnedHash);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        registry.validateBookPolicy(address(stable), 0, bytes32(0));
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        registry.validateBookPolicy(address(stable), 3, pinnedHash);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        registry.validateBookPolicy(address(stable), 1, bytes32(uint256(1)));
    }

    function test_ReenabledStablecoinResumesUnchangedPendingPolicy() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(29)));
        vm.prank(admin);
        factory.beginNode(r);
        registry.publishBookPolicy(address(stable), _changedBookPolicy());
        registry.setStablecoin(r.bookToken, false);
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.completeNode(r);
        registry.setStablecoin(r.bookToken, true);
        vm.prank(admin);
        (, NodeTypes.Addresses memory a) = factory.completeNode(r);
        assertEq(factory.nodeCount(), 1);
        _assertBookPolicy(a, _bookPolicy());
    }

    function _assertCompletionAfterRepublication(bool changeTerms) private {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(30)));
        bytes32 pinnedPolicyHash = r.expectedBookPolicyHash;
        vm.prank(admin);
        (bytes32 id, address deployer) = factory.beginNode(r);
        NodeTypes.BookPolicy memory next =
            changeTerms ? _changedBookPolicy() : _bookPolicy();
        assertEq(registry.publishBookPolicy(address(stable), next), 2);
        assertEq(registry.bookPolicyHash(address(stable), 1), pinnedPolicyHash);
        // The old version is still valid for this pending request, but not a new begin.
        vm.prank(admin);
        vm.expectRevert(ReleaseRegistry.StaleBookPolicy.selector);
        factory.beginNode(r);
        vm.prank(admin);
        (bytes32 activatedId, NodeTypes.Addresses memory a) = factory.completeNode(r);
        assertEq(activatedId, id);
        assertEq(factory.nodeDeployer(id), deployer);
        assertTrue(NodeDeployer(deployer).activated());
        assertTrue(NodeDeployer(deployer).verifyWiring());
        _assertBookPolicy(a, _bookPolicy());
        if (changeTerms) {
            assertNotEq(NodeRoles(a.roles).protocolAuthority(), next.protocolAuthority);
            assertNotEq(
                IBookFeeVault(a.bookVault).surplusRecipient(), next.bookSurplusRecipient
            );
            assertNotEq(IBookFeeVault(a.bookVault).maxFeeBps(), next.maxBookFeeBps);
            assertNotEq(
                IBookFeeVault(a.bookVault).configHash(1),
                keccak256(abi.encode(next.bookConfig))
            );
        }
        assertEq(registry.activeBookPolicyVersion(address(stable)), 2);
    }

    function _changedBookPolicy() private view returns (NodeTypes.BookPolicy memory) {
        return NodeTypes.BookPolicy(
            resolver,
            secondAdmin,
            750,
            IBookFeeVault.BookConfig(250, 4000, 6000, secondAdmin)
        );
    }

    function _assertBookPolicy(
        NodeTypes.Addresses memory a,
        NodeTypes.BookPolicy memory policy
    ) private view {
        assertEq(NodeRoles(a.roles).protocolAuthority(), policy.protocolAuthority);
        assertEq(
            IBookFeeVault(a.bookVault).surplusRecipient(), policy.bookSurplusRecipient
        );
        assertEq(IBookFeeVault(a.bookVault).maxFeeBps(), policy.maxBookFeeBps);
        assertEq(
            IBookFeeVault(a.bookVault).configHash(1),
            keccak256(abi.encode(policy.bookConfig))
        );
    }

    function _assertNoActivationLogs() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], NodeFactory.NodeCreated.selector);
        }
    }

    function test_ImmutableCreationCodeAndReleaseAreNotReplaceable() public {
        bytes memory code = registry.creationCode(RELEASE, 2);
        assertGt(code.length, 24_575); // AMM includes its manager; proves multi-chunk path.
        assertEq(keccak256(code), registry.creationCodeHash(RELEASE, 2));
        ReleaseRegistry.CodeInput[6] memory empty;
        vm.expectRevert(ReleaseRegistry.InvalidRelease.selector);
        registry.publishRelease(
            RELEASE,
            bytes20(uint160(1)),
            bytes32(uint256(1)),
            address(truthImplementation),
            bytes32(uint256(1)),
            empty
        );
        vm.expectRevert(CreationCodeStore.InvalidChunkLength.selector);
        new CreationCodeStore(new bytes(24_576));
    }
}
