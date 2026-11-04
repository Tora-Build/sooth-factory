// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {FactoryFixture} from "../factory/FactoryFixture.sol";
import {NodeTypes} from "../../src/factory/NodeTypes.sol";
import {NodeFactory} from "../../src/factory/NodeFactory.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IOrderEngine} from "../../src/interfaces/IOrderEngine.sol";
import {OrderEngine} from "../../src/OrderEngine.sol";
import {ManualAdjudicator} from "../../src/adjudicators/ManualAdjudicator.sol";

/// @notice Access checks that had no failing-path test at 1aa5fc8.
contract FactoryAccessGapsTest is FactoryFixture {
    NodeTypes.Addresses internal a;
    ManualAdjudicator internal adjudicator;
    MarketFactory internal marketFactory;

    function setUp() public override {
        super.setUp();
        a = _deployNode(admin, bytes32(uint256(100)));
        adjudicator = _activate(a, admin);
        marketFactory = MarketFactory(a.marketFactory);
        _fund(admin, a.marketFactory, stable);
    }

    function test_strangerCannotCreate() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        address stranger = address(0x57A);
        _fund(stranger, a.marketFactory, stable);
        vm.prank(stranger);
        vm.expectRevert(MarketFactory.Unauthorized.selector);
        marketFactory.createMarket(p);
    }

    function test_frozenBoundButUnadmittedProfileRejected() public {
        ManualAdjudicator other = new ManualAdjudicator(admin, a.marketFactory, 1 hours);
        vm.startPrank(admin);
        other.approveResolver(resolver);
        other.setResolutionRecipient(resolver);
        other.freezeProfile();
        vm.stopPrank();
        IMarketFactory.MarketParams memory p = _params(a, other, address(stable));
        vm.prank(admin);
        vm.expectRevert(MarketFactory.InvalidProfile.selector);
        marketFactory.createMarket(p);
    }

    function test_revokedProfileRejected() public {
        vm.prank(admin);
        marketFactory.setAdjudicatorAllowed(address(adjudicator), false);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        vm.prank(admin);
        vm.expectRevert(MarketFactory.InvalidProfile.selector);
        marketFactory.createMarket(p);
    }

    function test_thirdPartyCannotSubmitAnothersRequest() public {
        NodeTypes.Request memory r = _request(admin, bytes32(uint256(55)));
        vm.prank(address(0x57A));
        vm.expectRevert(NodeFactory.Unauthorized.selector);
        factory.beginNode(r);
    }

    function test_restingExpiryCannotOutliveTheMarket() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        vm.prank(admin);
        (address market,) = marketFactory.createMarket(p);
        IOrderEngine.OrderParams memory o;
        o.outcome = 1;
        o.priceTick = 500;
        o.amount = 1e18;
        o.matchLimit = 1;
        o.validUntil = uint64(block.timestamp + 1);
        o.expiry = p.deadline + 1;
        o.rest = true;
        o.maxTokenIn = 1e6;
        vm.prank(admin);
        vm.expectRevert(OrderEngine.InvalidExpiry.selector);
        IOrderEngine(a.book).placeOrder(market, o);
    }
}
