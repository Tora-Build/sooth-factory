// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {BookFeeVault} from "src/BookFeeVault.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {NodeRoles} from "src/policy/NodeRoles.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";

contract FeeTestToken is ERC20 {
    uint8 private immutable _decimals;
    uint256 public tax;
    uint256 public bonus;
    address public blocked;
    address public callback;
    bytes public payload;
    bool public callbackSucceeded;

    constructor(uint8 d) ERC20("Fee fixture", "FEE") {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(uint256 bps) external {
        tax = bps;
    }

    function setBonus(uint256 amount) external {
        bonus = amount;
    }

    function setBlocked(address account) external {
        blocked = account;
    }

    function arm(address target, bytes calldata data) external {
        callback = target;
        payload = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != blocked || blocked == address(0), "BLOCKED");
        uint256 cut = from == address(0) ? 0 : amount * tax / 10_000;
        super._update(from, to, amount - cut);
        if (cut != 0) super._update(from, address(0xFEE), cut);
        if (from != address(0) && bonus != 0) super._update(address(0), to, bonus);
        if (callback != address(0)) {
            address target = callback;
            callback = address(0);
            (callbackSucceeded,) = target.call(payload);
        }
    }
}

contract FeeTestMarket {
    address public immutable marketFactory;
    uint64 public immutable deadline;
    uint64 public constant invalidationBuffer = 1 hours;
    bool public isSettled;
    uint8 public winningOutcome;
    ITruthMarket.SettlementKind public settlementKind;

    constructor(address marketFactory_) {
        marketFactory = marketFactory_;
        deadline = uint64(block.timestamp + 1 days);
    }

    function isLiquidityOpen() external view returns (bool) {
        return !isSettled;
    }

    function settle(uint8 outcome) external {
        require(!isSettled);
        winningOutcome = outcome;
        isSettled = true;
        settlementKind = ITruthMarket.SettlementKind.ADJUDICATED;
    }

    function invalidate() external {
        require(!isSettled && block.timestamp >= uint256(deadline) + invalidationBuffer);
        winningOutcome = 2;
        isSettled = true;
        settlementKind = ITruthMarket.SettlementKind.INVALIDATED;
    }
}

contract FeeTestEngine {
    using SafeERC20 for IERC20;
    AmmFeeVault public ammVault;
    LPPositionManager public manager;

    function connect(AmmFeeVault vault) external {
        require(address(manager) == address(0));
        ammVault = vault;
        manager = new LPPositionManager(address(this), address(vault));
    }

    function accountingLocked() external pure returns (bool) {
        return false;
    }

    function seed(address market, address holder) external returns (uint256 id) {
        ammVault.enablePositionFees(market, address(manager));
        id = manager.bootstrap(market, holder, 1e18, 1e18);
    }

    function add(address market, address holder) external returns (uint256) {
        return manager.add(market, holder, 1e18, 1e18, 1e18);
    }

    function deposit(
        address vault,
        address market,
        IERC20 token,
        uint256 amount,
        address payer
    ) external {
        token.forceApprove(vault, amount);
        IAmmFeeVault(vault).depositRevenue(market, amount, payer);
    }
}

contract VenueFeeVaultsTest is Test {
    FeeTestToken token;
    NodeRoles nodeRoles;
    FeeTestEngine ammEngine;
    FeeTestEngine bookEngine;
    AmmFeeVault amm;
    BookFeeVault book;
    FeeTestMarket market;
    uint256 position;
    address admin = address(0xA);
    address protocol = address(0xB);
    address operatorRecipient = address(0xC);
    address protocolRecipient = address(0xD);
    address resolver = address(0xE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        _setup(18);
    }

    function _setup(uint8 decimals) private {
        token = new FeeTestToken(decimals);
        nodeRoles = new NodeRoles(admin, protocol, address(0));
        ammEngine = new FeeTestEngine();
        bookEngine = new FeeTestEngine();
        // Explicit local fixtures only: no production rate/split is implied.
        amm = new AmmFeeVault(
            IAmmFeeVault.Init(
                address(ammEngine),
                address(this),
                address(nodeRoles),
                operatorRecipient,
                _ammConfig()
            )
        );
        book = new BookFeeVault(
            IBookFeeVault.Init(
                address(bookEngine),
                address(this),
                address(nodeRoles),
                address(token),
                protocolRecipient,
                500,
                _bookConfig()
            )
        );
        ammEngine.connect(amm);
        market = _market();
        position = ammEngine.seed(address(market), alice);
    }

    function _ammConfig() private view returns (IAmmFeeVault.AmmConfig memory) {
        return IAmmFeeVault.AmmConfig(100, 5000, 3000, 1000, 1000, operatorRecipient);
    }

    function _bookConfig() private view returns (IBookFeeVault.BookConfig memory) {
        return IBookFeeVault.BookConfig(100, 1000, 9000, protocolRecipient);
    }

    function _market() private returns (FeeTestMarket m) {
        m = new FeeTestMarket(address(this));
        amm.registerMarket(
            address(m),
            address(token),
            token.decimals(),
            amm.activeConfigVersion(),
            resolver
        );
        book.registerMarket(
            address(m),
            address(token),
            token.decimals(),
            book.activeConfigVersion(),
            resolver
        );
    }

    function _deposit(uint256 ammAmount, uint256 bookAmount) private {
        token.mint(address(ammEngine), ammAmount);
        token.mint(address(bookEngine), bookAmount);
        ammEngine.deposit(address(amm), address(market), token, ammAmount, alice);
        bookEngine.deposit(address(book), address(market), token, bookAmount, bob);
    }

    function _claimLP(address holder, uint256 id) private returns (uint256) {
        vm.prank(holder);
        return amm.claimLPDividendForPosition(address(market), id);
    }

    function _assertSolvent() private view {
        assertGe(token.balanceOf(address(amm)), amm.totalLiabilitiesOf(address(token)));
        assertGe(token.balanceOf(address(book)), book.totalLiabilitiesOf(address(token)));
    }

    function test_SameTokenAdjudicatedClaimsBothOrders() public {
        _deposit(500, 1000);
        market.settle(1);
        assertEq(book.claimProtocolFees(address(market)), 900);
        assertEq(_claimLP(alice, position), 300);
        assertEq(amm.claimResolutionFees(address(market)), 100);
        assertEq(book.claimResolutionFees(address(market)), 100);
        assertEq(amm.claimOperatorFees(address(market)), 100);
        assertEq(token.balanceOf(resolver), 200);
        assertEq(book.refundableResolutionOf(address(market), bob), 0);
        assertEq(amm.totalLiabilitiesOf(address(token)), 0);
        assertEq(book.totalLiabilitiesOf(address(token)), 0);
        assertEq(_claimLP(alice, position), 0);
        assertEq(book.claimProtocolFees(address(market)), 0);
        vm.expectRevert(VenueFeeVault.InvalidPhase.selector);
        book.claimTimeoutRefund(address(market), bob);
        _assertSolvent();
    }

    function test_SameTokenSixDecimalsTimeoutBothClaimOrders() public {
        _setup(6);
        _deposit(500, 1000);
        vm.warp(uint256(market.deadline()) + market.invalidationBuffer());
        assertEq(book.claimTimeoutRefund(address(market), bob), 100);
        assertEq(token.balanceOf(address(amm)), 500);
        assertEq(_claimLP(alice, position), 400);
        assertEq(amm.claimOperatorFees(address(market)), 100);
        assertEq(book.claimProtocolFees(address(market)), 900);
        assertEq(book.claimTimeoutRefund(address(market), bob), 0);
        vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
        amm.claimResolutionFees(address(market));
        vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
        book.claimResolutionFees(address(market));
        _assertSolvent();
    }

    function test_AdjudicatedInvalidPaysResolverNotRefund() public {
        _deposit(500, 1000);
        market.settle(2);
        assertEq(amm.claimResolutionFees(address(market)), 100);
        assertEq(book.claimResolutionFees(address(market)), 100);
        assertEq(_claimLP(alice, position), 300);
        vm.expectRevert(VenueFeeVault.InvalidPhase.selector);
        book.claimTimeoutRefund(address(market), bob);
    }

    function test_EarningTimeOrdinaryAndTimeoutFeesRemainWithOldHolder() public {
        _deposit(500, 1000);
        LPPositionManager manager = ammEngine.manager();
        vm.prank(alice);
        manager.transfer(bob, position, 1e18);
        uint256 late = ammEngine.add(address(market), alice);
        _deposit(500, 1000);
        vm.warp(uint256(market.deadline()) + market.invalidationBuffer());
        // Alice earned 400 before transfer, then 200 on her new entry. Bob earns
        // only the second period's 200, even though he now owns the initial entry.
        assertEq(_claimLP(alice, late), 600);
        assertEq(_claimLP(bob, position), 200);
        assertEq(book.claimTimeoutRefund(address(market), bob), 200);
        _assertSolvent();
    }

    function test_CrossRoleAndUnauthorizedReceiptRejected() public {
        IAmmFeeVault.AmmConfig memory ac = _ammConfig();
        IBookFeeVault.BookConfig memory bc = _bookConfig();
        vm.prank(protocol);
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        amm.publishAmmConfig(ac);
        vm.prank(admin);
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        book.publishBookConfig(bc);
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        amm.depositRevenue(address(market), 10, alice);
        vm.prank(address(ammEngine));
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        book.depositRevenue(address(market), 10, alice);
    }

    function test_RoleTransferAndConfigChangesPreserveOldRecipients() public {
        _deposit(500, 1000);
        vm.prank(admin);
        nodeRoles.proposeNodeAdmin(alice);
        vm.prank(alice);
        nodeRoles.acceptNodeAdmin();
        vm.prank(protocol);
        nodeRoles.proposeProtocolAuthority(bob);
        vm.prank(bob);
        nodeRoles.acceptProtocolAuthority();
        IAmmFeeVault.AmmConfig memory ac = _ammConfig();
        ac.operatorRecipient = alice;
        IBookFeeVault.BookConfig memory bc = _bookConfig();
        bc.protocolRecipient = bob;
        vm.prank(alice);
        amm.publishAmmConfig(ac);
        vm.prank(bob);
        book.publishBookConfig(bc);
        assertEq(amm.configOf(address(market)).operatorRecipient, operatorRecipient);
        assertEq(book.configOf(address(market)).protocolRecipient, protocolRecipient);
        amm.claimOperatorFees(address(market));
        book.claimProtocolFees(address(market));
        assertEq(token.balanceOf(operatorRecipient), 100);
        assertEq(token.balanceOf(protocolRecipient), 900);
        FeeTestMarket later = _market();
        assertEq(amm.configOf(address(later)).operatorRecipient, alice);
        assertEq(book.configOf(address(later)).protocolRecipient, bob);
    }

    function test_FeeReceiptCannotConsumeDonationOrShortTransfer() public {
        token.mint(address(amm), 200);
        token.mint(address(book), 200);
        token.mint(address(ammEngine), 100);
        token.mint(address(bookEngine), 100);
        token.setTax(1000);
        vm.expectRevert(VenueFeeVault.DepositAmountMismatch.selector);
        ammEngine.deposit(address(amm), address(market), token, 100, alice);
        vm.expectRevert(VenueFeeVault.DepositAmountMismatch.selector);
        bookEngine.deposit(address(book), address(market), token, 100, bob);
        assertEq(amm.totalLiabilitiesOf(address(token)), 0);
        assertEq(book.totalLiabilitiesOf(address(token)), 0);
        assertEq(token.balanceOf(address(amm)), 200);
        assertEq(token.balanceOf(address(book)), 200);
    }

    function test_ReentrantSurplusSweepCannotTakeInFlightRevenue() public {
        token.mint(address(ammEngine), 500);
        token.arm(
            address(amm), abi.encodeCall(amm.sweepUnattributedSurplus, (address(token)))
        );
        ammEngine.deposit(address(amm), address(market), token, 500, alice);
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(operatorRecipient), 0);
        assertEq(amm.totalLiabilitiesOf(address(token)), 500);
    }

    function test_DonationsAndClaimsNeverBecomeSurplusAtSettlement() public {
        _deposit(501, 1001);
        token.mint(address(amm), 7);
        token.mint(address(book), 9);
        market.settle(0);
        assertEq(amm.sweepUnattributedSurplus(address(token)), 7);
        assertEq(book.sweepUnattributedSurplus(address(token)), 9);
        assertEq(amm.totalLiabilitiesOf(address(token)), 501);
        assertEq(book.totalLiabilitiesOf(address(token)), 1001);
        _claimLP(alice, position);
        assertEq(amm.sweepUnattributedSurplus(address(token)), 0);
        _assertSolvent();
    }

    function test_BonusReceiptsAndInexactPayoutsRevertAtomically() public {
        token.mint(address(ammEngine), 500);
        token.mint(address(bookEngine), 1000);
        token.setBonus(1);
        vm.expectRevert(VenueFeeVault.DepositAmountMismatch.selector);
        ammEngine.deposit(address(amm), address(market), token, 500, alice);
        vm.expectRevert(VenueFeeVault.DepositAmountMismatch.selector);
        bookEngine.deposit(address(book), address(market), token, 1000, bob);
        assertEq(amm.totalLiabilitiesOf(address(token)), 0);
        assertEq(book.totalLiabilitiesOf(address(token)), 0);
        token.setBonus(0);
        ammEngine.deposit(address(amm), address(market), token, 500, alice);
        bookEngine.deposit(address(book), address(market), token, 1000, bob);
        token.setTax(1000);
        vm.expectRevert(VenueFeeVault.TransferAmountMismatch.selector);
        amm.claimOperatorFees(address(market));
        vm.expectRevert(VenueFeeVault.TransferAmountMismatch.selector);
        book.claimProtocolFees(address(market));
        assertEq(amm.totalLiabilitiesOf(address(token)), 500);
        assertEq(book.totalLiabilitiesOf(address(token)), 1000);
        assertEq(token.balanceOf(operatorRecipient), 0);
        assertEq(token.balanceOf(protocolRecipient), 0);
    }

    function test_FinalizationIsIndependentIdempotentAndSettlementGated() public {
        _deposit(500, 1000);
        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        amm.finalize(address(market));
        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        book.claimTimeoutRefund(address(market), bob);
        market.settle(1);
        amm.finalize(address(market));
        amm.finalize(address(market));
        book.finalize(address(market));
        book.finalize(address(market));
        assertEq(amm.totalLiabilitiesOf(address(token)), 500);
        assertEq(book.totalLiabilitiesOf(address(token)), 1000);
        token.mint(address(ammEngine), 1);
        vm.expectRevert(VenueFeeVault.InvalidPhase.selector);
        ammEngine.deposit(address(amm), address(market), token, 1, alice);
        assertEq(_claimLP(alice, position), 300);
    }

    function test_OneNativeUnitDustHasOnlyItsOwnVenueRecipient() public {
        _deposit(1, 1);
        assertEq(
            amm.accountOf(address(market), IAmmFeeVault.Bucket.LP, address(token)), 0
        );
        assertEq(
            amm.accountOf(
                address(market), IAmmFeeVault.Bucket.RESOLUTION, address(token)
            ),
            0
        );
        assertEq(book.refundableResolutionOf(address(market), bob), 0);
        assertEq(amm.claimOperatorFees(address(market)), 1);
        assertEq(book.claimProtocolFees(address(market)), 1);
        assertEq(token.balanceOf(operatorRecipient), 1);
        assertEq(token.balanceOf(protocolRecipient), 1);
        assertEq(amm.totalLiabilitiesOf(address(token)), 0);
        assertEq(book.totalLiabilitiesOf(address(token)), 0);
    }

    function test_RateCapsRecipientValidationAndDuplicateRegistration() public {
        IAmmFeeVault.AmmConfig memory ac = _ammConfig();
        ac.feeBps = 10_001;
        vm.prank(admin);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        amm.publishAmmConfig(ac);
        IBookFeeVault.BookConfig memory bc = _bookConfig();
        bc.feeBps = 501;
        vm.prank(protocol);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        book.publishBookConfig(bc);
        ac.feeBps = 0;
        ac.operatorRecipient = address(0);
        vm.prank(admin);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        amm.publishAmmConfig(ac);
        vm.expectRevert(VenueFeeVault.AlreadyRegistered.selector);
        amm.registerMarket(address(market), address(token), 18, 1, resolver);
        vm.prank(alice);
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        book.registerMarket(address(market), address(token), 18, 1, resolver);
        assertEq(amm.activeConfigVersion(), 1);
        assertEq(book.activeConfigVersion(), 1);
    }

    function test_FullCapitalAndFixedDepthConfigsAreAccepted() public {
        IAmmFeeVault.AmmConfig memory ac =
            IAmmFeeVault.AmmConfig(100, 10_000, 0, 0, 0, operatorRecipient);
        vm.prank(admin);
        assertEq(amm.publishAmmConfig(ac), 2);
        assertEq(amm.configByVersion(2).capitalBps, 10_000);
        ac = IAmmFeeVault.AmmConfig(0, 0, 6000, 2000, 2000, operatorRecipient);
        AmmFeeVault fixedDepth = new AmmFeeVault(
            IAmmFeeVault.Init(
                address(ammEngine),
                address(this),
                address(nodeRoles),
                operatorRecipient,
                ac
            )
        );
        assertEq(fixedDepth.configByVersion(1).feeBps, 0);
        assertEq(fixedDepth.configHash(1), keccak256(abi.encode(ac)));
    }

    function test_FullCapitalCanBeChosenAtConstruction() public {
        IAmmFeeVault.Init memory init = IAmmFeeVault.Init(
            address(ammEngine),
            address(this),
            address(nodeRoles),
            operatorRecipient,
            IAmmFeeVault.AmmConfig(10_000, 10_000, 0, 0, 0, operatorRecipient)
        );
        AmmFeeVault fullCapital = new AmmFeeVault(init);
        assertEq(fullCapital.configByVersion(1).capitalBps, 10_000);
        assertEq(fullCapital.configByVersion(1).feeBps, 10_000);
        assertEq(fullCapital.maxFeeBps(), 10_000);
    }

    function test_OperatorCanChooseFutureRateAndCapitalWithoutSeparateCeilings() public {
        IAmmFeeVault.Init memory init = IAmmFeeVault.Init(
            address(ammEngine),
            address(this),
            address(nodeRoles),
            operatorRecipient,
            IAmmFeeVault.AmmConfig(100, 0, 8000, 1000, 1000, operatorRecipient)
        );
        AmmFeeVault fixedDepth = new AmmFeeVault(init);
        fixedDepth.registerMarket(address(market), address(token), 18, 1, resolver);
        vm.prank(protocol);
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        fixedDepth.publishAmmConfig(
            IAmmFeeVault.AmmConfig(10_000, 5000, 3000, 1000, 1000, operatorRecipient)
        );
        vm.prank(admin);
        fixedDepth.publishAmmConfig(
            IAmmFeeVault.AmmConfig(10_000, 5000, 3000, 1000, 1000, operatorRecipient)
        );
        assertEq(fixedDepth.activeConfigVersion(), 2);
        assertEq(fixedDepth.configOf(address(market)).capitalBps, 0);
        assertEq(fixedDepth.configOf(address(market)).feeBps, 100);
        assertEq(fixedDepth.configByVersion(2).capitalBps, 5000);
        assertEq(fixedDepth.configByVersion(2).feeBps, 10_000);
    }

    function test_SurplusEventsExplicitlyIdentifyVenue() public {
        token.mint(address(amm), 7);
        token.mint(address(book), 9);
        vm.expectEmit(true, true, true, true, address(amm));
        emit VenueFeeVault.SurplusSwept(0, address(token), operatorRecipient, 7);
        amm.sweepUnattributedSurplus(address(token));
        vm.expectEmit(true, true, true, true, address(book));
        emit VenueFeeVault.SurplusSwept(1, address(token), protocolRecipient, 9);
        book.sweepUnattributedSurplus(address(token));
    }

    function test_HistoricalDonationCannotFundNewMarketCredit() public {
        token.mint(address(amm), 500);
        vm.expectRevert();
        ammEngine.deposit(address(amm), address(market), token, 500, alice);
        assertEq(amm.totalLiabilitiesOf(address(token)), 0);
        assertEq(amm.sweepUnattributedSurplus(address(token)), 500);
        assertEq(token.balanceOf(operatorRecipient), 500);
    }

    function test_LpRoundingReserveCannotBeSweptAfterAllClaims() public {
        uint256 second = ammEngine.add(address(market), bob);
        _deposit(5, 0); // 3 LP units across two equally weighted positions
        market.settle(1);
        assertEq(_claimLP(alice, position), 1);
        assertEq(_claimLP(bob, second), 1);
        amm.claimOperatorFees(address(market));
        amm.claimResolutionFees(address(market));
        assertEq(amm.totalLiabilitiesOf(address(token)), 1);
        assertEq(amm.sweepUnattributedSurplus(address(token)), 0);
    }

    function test_BlockedRefundDoesNotBlockOtherVenueOrPayer() public {
        _deposit(500, 1000);
        token.mint(address(bookEngine), 1000);
        bookEngine.deposit(address(book), address(market), token, 1000, alice);
        token.setBlocked(bob);
        vm.warp(uint256(market.deadline()) + market.invalidationBuffer());
        vm.expectRevert("BLOCKED");
        book.claimTimeoutRefund(address(market), bob);
        assertEq(book.refundableResolutionOf(address(market), bob), 100);
        assertEq(book.claimTimeoutRefund(address(market), alice), 100);
        assertEq(_claimLP(alice, position), 400);
        _assertSolvent();
    }

    function test_RegistrationRejectsStaleVersionDecimalsAndForeignNode() public {
        FeeTestMarket next = new FeeTestMarket(address(this));
        vm.expectRevert(VenueFeeVault.StaleConfig.selector);
        amm.registerMarket(address(next), address(token), 18, 2, resolver);
        vm.expectRevert(VenueFeeVault.InvalidToken.selector);
        amm.registerMarket(address(next), address(token), 6, 1, resolver);
        FeeTestMarket foreign = new FeeTestMarket(alice);
        vm.expectRevert(VenueFeeVault.NotAuthorized.selector);
        book.registerMarket(address(foreign), address(token), 18, 1, resolver);
    }

    function test_ConfigFullAllocationAndCapitalBounds() public {
        IAmmFeeVault.AmmConfig memory ac = _ammConfig();
        ac.operatorBps = 999;
        vm.prank(admin);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        amm.publishAmmConfig(ac);
        IBookFeeVault.BookConfig memory bc = _bookConfig();
        bc.protocolBps = 1000;
        vm.prank(protocol);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        book.publishBookConfig(bc);
        ac = IAmmFeeVault.AmmConfig(100, 10_000, 0, 0, 1, operatorRecipient);
        vm.prank(admin);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        amm.publishAmmConfig(ac);
        IAmmFeeVault.Init memory init = IAmmFeeVault.Init(
            address(ammEngine), address(this), address(nodeRoles), operatorRecipient, ac
        );
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        new AmmFeeVault(init);
        ac.capitalBps = 10_001;
        ac.operatorBps = 0;
        vm.prank(admin);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        amm.publishAmmConfig(ac);
    }

    function test_TwoSameTokenMarketsLiabilitiesStaySeparate() public {
        _deposit(500, 1000);
        FeeTestMarket second = _market();
        uint256 secondPosition = ammEngine.seed(address(second), bob);
        token.mint(address(ammEngine), 1000);
        ammEngine.deposit(address(amm), address(second), token, 1000, bob);
        market.settle(1);
        _claimLP(alice, position);
        amm.claimOperatorFees(address(market));
        amm.claimResolutionFees(address(market));
        assertEq(amm.marketLiabilitiesOf(address(second), address(token)), 1000);
        assertEq(token.balanceOf(address(amm)), 1000);
        second.settle(0);
        vm.prank(bob);
        assertEq(amm.claimLPDividendForPosition(address(second), secondPosition), 600);
        _assertSolvent();
    }

    function testFuzz_BookSplitAndPayerRefundConserveNativeUnits(
        uint128 a,
        uint128 b,
        uint16 resolutionBps,
        bool firstPayerFirst
    ) public {
        uint256 x = bound(uint256(a), 1, 1e24);
        uint256 y = bound(uint256(b), 1, 1e24);
        uint16 rate = uint16(bound(uint256(resolutionBps), 0, 10_000));
        IBookFeeVault.BookConfig memory bc =
            IBookFeeVault.BookConfig(100, rate, 10_000 - rate, protocolRecipient);
        vm.prank(protocol);
        book.publishBookConfig(bc);
        FeeTestMarket m = _market();
        token.mint(address(bookEngine), x + y);
        bookEngine.deposit(address(book), address(m), token, x, alice);
        bookEngine.deposit(address(book), address(m), token, y, bob);
        uint256 r1 = x * rate / 10_000;
        uint256 r2 = y * rate / 10_000;
        vm.warp(uint256(m.deadline()) + m.invalidationBuffer());
        if (firstPayerFirst) {
            assertEq(book.claimTimeoutRefund(address(m), alice), r1);
            assertEq(book.claimProtocolFees(address(m)), x + y - r1 - r2);
            assertEq(book.claimTimeoutRefund(address(m), bob), r2);
        } else {
            assertEq(book.claimProtocolFees(address(m)), x + y - r1 - r2);
            assertEq(book.claimTimeoutRefund(address(m), bob), r2);
            assertEq(book.claimTimeoutRefund(address(m), alice), r1);
        }
        assertEq(book.totalLiabilitiesOf(address(token)), 0);
        assertEq(token.balanceOf(address(book)), 0);
    }
}
