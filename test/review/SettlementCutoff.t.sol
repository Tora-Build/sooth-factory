// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {AdjudicatorBase} from "src/adjudicators/AdjudicatorBase.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {BookFeeVault} from "src/BookFeeVault.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {NodeRoles} from "src/policy/NodeRoles.sol";

contract CutoffAttestingAdjudicator is AdjudicatorBase {
    constructor(address factory) AdjudicatorBase(msg.sender, factory, 100) {}

    function _requiresAttestation() internal pure override returns (bool) {
        return true;
    }

    function _verifyAttestation(address, bytes calldata) internal pure override {}
}

contract CutoffToken is ERC20 {
    constructor() ERC20("Cutoff fixture", "CUT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Only custody receipt and LP fee attribution are mocked. Both fee vaults,
///      LP accounting, TruthMarket and adjudicator execute their production code.
contract CutoffFeeEngine {
    LPPositionManager public manager;

    function seed(AmmFeeVault vault, address market, address holder)
        external
        returns (uint256)
    {
        manager = new LPPositionManager(address(this), address(vault));
        vault.enablePositionFees(market, address(manager));
        return manager.bootstrap(market, holder, 1e18, 1e18);
    }

    function accountingLocked() external pure returns (bool) {
        return false;
    }

    function deposit(
        address vault,
        address market,
        IERC20 token,
        uint256 amount,
        address payer
    ) external {
        token.approve(vault, amount);
        IAmmFeeVault(vault).depositRevenue(market, amount, payer);
    }
}

contract SettlementCutoffTest is Test {
    uint64 private constant START = 1000;
    uint64 private constant DEADLINE = 2000;
    uint64 private constant BUFFER = 300;
    uint256 private constant CUTOFF = uint256(DEADLINE) + BUFFER;
    uint48 private constant VETO = 100;
    address private constant RESOLVER = address(0xA11CE);
    address private constant GUARDIAN = address(0x600D);
    address private constant RECIPIENT = address(0xFEED);
    address private constant LP = address(0x1A);
    address private constant PAYER = address(0x2A);
    address private constant OPERATOR = address(0x3A);
    address private constant PROTOCOL = address(0x4A);

    TruthMarket private implementation;
    ManualAdjudicator private adjudicator;

    function setUp() public {
        vm.warp(START);
        implementation = new TruthMarket();
        adjudicator = new ManualAdjudicator(address(this), address(this), VETO);
        adjudicator.approveGuardian(GUARDIAN);
        adjudicator.setResolutionRecipient(RECIPIENT);
        adjudicator.approveResolver(RESOLVER);
        adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
    }

    function _clone(address adj, uint64 deadline, uint64 buffer)
        private
        returns (TruthMarket)
    {
        return TruthMarket(
            Clones.cloneWithImmutableArgs(
                address(implementation),
                abi.encodePacked(
                    keccak256("cutoff question"),
                    START,
                    deadline,
                    adj,
                    address(this),
                    address(this),
                    buffer,
                    keccak256("cutoff terms")
                )
            )
        );
    }

    function _configured(AdjudicatorBase adj, uint64 deadline)
        private
        returns (TruthMarket market)
    {
        market = _clone(address(adj), deadline, BUFFER);
        adj.configureMarket(address(market), abi.encode(RESOLVER, deadline, bytes("")));
    }

    // 0=LIVE, 1=RESOLVING, 2=ATTESTED, 3=vetoed/disputed (TruthMarket LIVE).
    function _prepare(uint8 phase, uint8 outcome) private returns (TruthMarket market) {
        vm.warp(START);
        market = _configured(adjudicator, DEADLINE);
        _phase(market, phase, outcome);
    }

    function _phase(TruthMarket market, uint8 phase, uint8 outcome) private {
        if (phase == 0) return;
        vm.prank(RESOLVER);
        adjudicator.resolve(address(market), outcome, keccak256("evidence"));
        if (phase == 2) adjudicator.attest(address(market), "");
        if (phase == 3) {
            vm.prank(GUARDIAN);
            adjudicator.dispute(address(market));
        }
    }

    function _assertTerminal(TruthMarket market, bool timedOut, uint8 outcome)
        private
        view
    {
        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), outcome);
        assertEq(
            uint8(market.settlementKind()),
            uint8(
                timedOut
                    ? ITruthMarket.SettlementKind.INVALIDATED
                    : ITruthMarket.SettlementKind.ADJUDICATED
            )
        );
        assertFalse(adjudicator.canSettle(address(market)));
    }

    function test_ResolvingAndAttestedSettleAtTMinusOneAllOutcomesBothOrders() public {
        for (uint8 phase = 1; phase <= 2; ++phase) {
            for (uint8 outcome; outcome <= 2; ++outcome) {
                for (uint8 timeoutFirst; timeoutFirst < 2; ++timeoutFirst) {
                    TruthMarket market = _prepare(phase, outcome);
                    vm.warp(CUTOFF - 1);
                    assertTrue(adjudicator.canSettle(address(market)));
                    if (timeoutFirst == 1) {
                        vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
                        market.invalidate();
                    }
                    adjudicator.settle(address(market));
                    vm.expectRevert(TruthMarket.AlreadySettled.selector);
                    market.invalidate();
                    _assertTerminal(market, false, outcome);
                }
            }
        }
    }

    function test_AtTAndTPlusOneTimeoutWinsEveryUnsettledPhaseBothOrders() public {
        for (uint8 phase; phase < 4; ++phase) {
            for (uint8 afterCutoff; afterCutoff < 2; ++afterCutoff) {
                for (uint8 timeoutFirst; timeoutFirst < 2; ++timeoutFirst) {
                    TruthMarket market = _prepare(phase, 1);
                    vm.warp(CUTOFF + afterCutoff);
                    assertFalse(adjudicator.canSettle(address(market)));
                    if (timeoutFirst == 0) {
                        vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
                        adjudicator.settle(address(market));
                        assertFalse(market.isSettled());
                    }
                    vm.prank(PAYER);
                    market.invalidate();
                    vm.expectRevert(AdjudicatorBase.MarketAlreadySettled.selector);
                    adjudicator.settle(address(market));
                    _assertTerminal(market, true, 2);
                }
            }
        }
    }

    function test_LiveAndDisputedAtTMinusOneCannotSettleOrTimeout() public {
        for (uint8 phase; phase <= 3; phase += 3) {
            TruthMarket market = _prepare(phase, 1);
            vm.warp(CUTOFF - 1);
            assertFalse(adjudicator.canSettle(address(market)));
            vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
            market.invalidate();
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAdjudicator.InvalidPhase.selector,
                    adjudicator.PHASE_RESOLVED(),
                    phase == 0 ? adjudicator.PHASE_ACTIVE() : adjudicator.PHASE_DISPUTED()
                )
            );
            adjudicator.settle(address(market));
            assertFalse(market.isSettled());
        }
    }

    function test_ProposalAndReproposalRequireFullVetoWindowStrictlyBeforeT() public {
        for (uint8 phase; phase <= 3; phase += 3) {
            TruthMarket market = _prepare(phase, 1);
            vm.warp(CUTOFF - VETO - 1);
            vm.prank(RESOLVER);
            adjudicator.resolve(address(market), 2, keccak256("last eligible"));
            vm.warp(CUTOFF - 1);
            adjudicator.settle(address(market));
            _assertTerminal(market, false, 2);

            market = _prepare(phase, 1);
            uint256[3] memory times = [CUTOFF - VETO, CUTOFF, CUTOFF + 1];
            for (uint256 i; i < times.length; ++i) {
                vm.warp(times[i]);
                vm.prank(RESOLVER);
                vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
                adjudicator.resolve(address(market), 2, keccak256("too late"));
            }
            assertTrue(market.isLive());
        }
    }

    function test_AttestationAndDisputeRejectAtAndAfterTWithoutMutation() public {
        for (uint8 afterCutoff; afterCutoff < 2; ++afterCutoff) {
            TruthMarket market = _prepare(1, 1);
            vm.warp(CUTOFF + afterCutoff);
            vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
            adjudicator.attest(address(market), "");
            vm.prank(GUARDIAN);
            vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
            adjudicator.dispute(address(market));
            assertTrue(market.isResolving());
            assertEq(adjudicator.getPhase(address(market)), adjudicator.PHASE_RESOLVED());
            market.invalidate();
            vm.prank(GUARDIAN);
            vm.expectRevert(AdjudicatorBase.MarketAlreadySettled.selector);
            adjudicator.dispute(address(market));
            _assertTerminal(market, true, 2);
        }
    }

    function test_RequiredAttestationStillCannotExtendCutoff() public {
        CutoffAttestingAdjudicator adj = new CutoffAttestingAdjudicator(address(this));
        adj.approveResolver(RESOLVER);
        adj.setEarlyResolution(true);
        adj.freezeProfile();
        TruthMarket market = _configured(adj, DEADLINE);
        vm.prank(RESOLVER);
        adj.resolve(address(market), 1, keccak256("evidence"));
        // The veto period runs from the attestation and must end before the cutoff.
        vm.warp(CUTOFF - 100);
        vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
        adj.attest(address(market), "");
        vm.warp(CUTOFF - 101);
        assertFalse(adj.canSettle(address(market)));
        adj.attest(address(market), "");
        assertFalse(adj.canSettle(address(market)));
        vm.warp(CUTOFF - 1);
        assertTrue(adj.canSettle(address(market)));
        vm.warp(CUTOFF);
        assertFalse(adj.canSettle(address(market)));
        vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
        adj.settle(address(market));
        market.invalidate();
        _assertTerminal(market, true, 2);
    }

    function test_CustomAdjudicatorCannotSettleOrAdvanceAnyPhaseAtOrAfterT() public {
        for (uint8 phase; phase < 4; ++phase) {
            for (uint8 afterCutoff; afterCutoff < 2; ++afterCutoff) {
                vm.warp(START);
                TruthMarket market = _clone(address(this), DEADLINE, BUFFER);
                if (phase != 0) market.resolve(2);
                if (phase == 2) market.attest();
                if (phase == 3) market.veto();
                vm.warp(CUTOFF + afterCutoff);
                vm.expectRevert(TruthMarket.SettlementDeadlinePassed.selector);
                if (phase == 0 || phase == 3) market.resolve(1);
                else if (phase == 1) market.attest();
                else market.settle();
                if (phase == 1 || phase == 2) {
                    vm.expectRevert(TruthMarket.SettlementDeadlinePassed.selector);
                    market.veto();
                }
                market.invalidate();
                _assertTerminal(market, true, 2);
            }
        }
    }

    function test_CustomAdjudicatorCanFinishAtTMinusOneIncludingInvalid() public {
        TruthMarket market = _clone(address(this), DEADLINE, BUFFER);
        vm.warp(CUTOFF - 1);
        market.resolve(2);
        market.attest();
        market.settle();
        _assertTerminal(market, false, 2);
    }

    function test_AdjudicatorRefusesZeroAndInfiniteDeadlines() public {
        // Clone first. `expectRevert` treats the clone's CREATE as the next
        // call, and a successful create then surfaces as FailedDeployment.
        TruthMarket zero = _clone(address(adjudicator), 0, BUFFER);
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        adjudicator.configureMarket(
            address(zero), abi.encode(RESOLVER, uint64(0), bytes(""))
        );
        TruthMarket endless = _clone(address(adjudicator), type(uint64).max, BUFFER);
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        adjudicator.configureMarket(
            address(endless), abi.encode(RESOLVER, type(uint64).max, bytes(""))
        );
        // The truth contract still has no timeout if it is constructed with an
        // infinite deadline. This adjudicator will not bind that market.
        vm.expectRevert(TruthMarket.InfiniteDeadline.selector);
        endless.invalidate();
    }

    function test_FiniteDeadlinePlusBufferUsesUint256WithoutOverflow() public {
        uint64 deadline = type(uint64).max - 1;
        uint64 buffer = type(uint64).max;
        uint256 cutoff = uint256(deadline) + buffer;
        TruthMarket market = _clone(address(this), deadline, buffer);
        vm.warp(cutoff - 1);
        market.resolve(1);
        market.attest();
        market.settle();
        _assertTerminal(market, false, 1);
        market = _clone(address(this), deadline, buffer);
        vm.warp(cutoff);
        vm.expectRevert(TruthMarket.SettlementDeadlinePassed.selector);
        market.resolve(1);
        market.invalidate();
        _assertTerminal(market, true, 2);
    }

    struct Fees {
        CutoffToken token;
        AmmFeeVault amm;
        BookFeeVault book;
        uint256 position;
    }

    function _fundFees(TruthMarket market) private returns (Fees memory f) {
        f.token = new CutoffToken();
        NodeRoles roles = new NodeRoles(address(this), address(this), address(0));
        CutoffFeeEngine ammEngine = new CutoffFeeEngine();
        CutoffFeeEngine bookEngine = new CutoffFeeEngine();
        IAmmFeeVault.Init memory ammInit;
        ammInit.engine = address(ammEngine);
        ammInit.marketFactory = address(this);
        ammInit.roles = address(roles);
        ammInit.surplusRecipient = OPERATOR;
        ammInit.initialConfig = IAmmFeeVault.AmmConfig(100, 0, 6000, 2000, 2000, OPERATOR);
        f.amm = new AmmFeeVault(ammInit);
        f.book = new BookFeeVault(
            IBookFeeVault.Init(
                address(bookEngine),
                address(this),
                address(roles),
                address(f.token),
                PROTOCOL,
                500,
                IBookFeeVault.BookConfig(100, 1000, 9000, PROTOCOL)
            )
        );
        f.amm.registerMarket(address(market), address(f.token), 6, 1, RECIPIENT);
        f.book.registerMarket(address(market), address(f.token), 6, 1, RECIPIENT);
        f.position = ammEngine.seed(f.amm, address(market), LP);
        f.token.mint(address(ammEngine), 500);
        f.token.mint(address(bookEngine), 1000);
        ammEngine.deposit(address(f.amm), address(market), f.token, 500, PAYER);
        bookEngine.deposit(address(f.book), address(market), f.token, 1000, PAYER);
    }

    function _claimLP(Fees memory f, TruthMarket market) private returns (uint256) {
        vm.prank(LP);
        return f.amm.claimLPDividendForPosition(address(market), f.position);
    }

    function _claimAndCheck(
        Fees memory f,
        TruthMarket market,
        bool timeout,
        bool bookFirst
    ) private {
        if (timeout) {
            if (bookFirst) {
                assertEq(f.book.claimTimeoutRefund(address(market), PAYER), 100);
                assertEq(_claimLP(f, market), 400);
            } else {
                assertEq(_claimLP(f, market), 400);
                assertEq(f.book.claimTimeoutRefund(address(market), PAYER), 100);
            }
            vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
            f.amm.claimResolutionFees(address(market));
            vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
            f.book.claimResolutionFees(address(market));
            assertEq(f.token.balanceOf(RECIPIENT), 0);
            assertEq(f.token.balanceOf(PAYER), 100);
            assertEq(f.token.balanceOf(LP), 400);
            assertEq(f.book.claimTimeoutRefund(address(market), PAYER), 0);
        } else {
            if (bookFirst) {
                assertEq(f.book.claimResolutionFees(address(market)), 100);
                assertEq(f.amm.claimResolutionFees(address(market)), 100);
            } else {
                assertEq(f.amm.claimResolutionFees(address(market)), 100);
                assertEq(f.book.claimResolutionFees(address(market)), 100);
            }
            assertEq(_claimLP(f, market), 300);
            vm.expectRevert(VenueFeeVault.InvalidPhase.selector);
            f.book.claimTimeoutRefund(address(market), PAYER);
            assertEq(f.token.balanceOf(RECIPIENT), 200);
            assertEq(f.token.balanceOf(PAYER), 0);
            assertEq(f.token.balanceOf(LP), 300);
        }
        assertEq(f.amm.claimOperatorFees(address(market)), 100);
        assertEq(f.book.claimProtocolFees(address(market)), 900);
        assertEq(f.token.balanceOf(OPERATOR), 100);
        assertEq(f.token.balanceOf(PROTOCOL), 900);
        assertEq(f.amm.totalLiabilitiesOf(address(f.token)), 0);
        assertEq(f.book.totalLiabilitiesOf(address(f.token)), 0);
        assertEq(f.token.balanceOf(address(f.amm)), 0);
        assertEq(f.token.balanceOf(address(f.book)), 0);
        assertEq(_claimLP(f, market), 0);
    }

    function test_TMinusOneAllAdjudicatedOutcomesPayResolverBothVenueOrders() public {
        for (uint8 phase = 1; phase <= 2; ++phase) {
            for (uint8 outcome; outcome <= 2; ++outcome) {
                for (uint8 bookFirst; bookFirst < 2; ++bookFirst) {
                    TruthMarket market = _prepare(0, outcome);
                    Fees memory f = _fundFees(market);
                    _phase(market, phase, outcome);
                    vm.warp(CUTOFF - 1);
                    adjudicator.settle(address(market));
                    // Later claims must preserve the pre-cutoff settlement kind.
                    vm.warp(CUTOFF + 1);
                    _claimAndCheck(f, market, false, bookFirst == 1);
                    _assertTerminal(market, false, outcome);
                }
            }
        }
    }

    function test_TAndTPlusOneAllPhasesPayLpAndPayerBothVenueAndTransactionOrders()
        public
    {
        for (uint8 phase; phase < 4; ++phase) {
            for (uint8 afterCutoff; afterCutoff < 2; ++afterCutoff) {
                for (uint8 bookFirst; bookFirst < 2; ++bookFirst) {
                    for (uint8 timeoutFirst; timeoutFirst < 2; ++timeoutFirst) {
                        TruthMarket market = _prepare(0, 2);
                        Fees memory f = _fundFees(market);
                        _phase(market, phase, 2);
                        vm.warp(CUTOFF + afterCutoff);
                        if (timeoutFirst == 0) {
                            vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
                            adjudicator.settle(address(market));
                        }
                        // Each venue independently triggers the shared timeout.
                        _claimAndCheck(f, market, true, bookFirst == 1);
                        vm.expectRevert(AdjudicatorBase.MarketAlreadySettled.selector);
                        adjudicator.settle(address(market));
                        _assertTerminal(market, true, 2);
                    }
                }
            }
        }
    }
}
