// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";

/// @notice The privileged custody entry points must stay unreachable from outside.
/// @dev Before the merge these were `external onlyFiller`: only SoothBook could call
///      them. Merging the book in removed the filler, and simply dropping the modifier
///      would have left them external and UNGATED — anyone could have credited
///      themselves outcome shares against no collateral. They are internal instead.
///
///      Neither the compiler nor the behavioural suite catches that regression: an
///      ungated `creditShares` breaks no existing test, because no existing test tries
///      to call it. This asserts the absence directly, by selector.
contract MergedBookAuthorizationTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    /// Each signature is the one the function had while it was external.
    function _assertUnreachable(string memory signature, bytes memory args) internal {
        bytes memory payload = abi.encodePacked(bytes4(keccak256(bytes(signature))), args);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(orderEngine).call(payload);
        assertFalse(ok, signature);
    }

    /// Control: the helper must be able to tell reachable from unreachable. Without
    /// this, a typo in any signature below would also "pass" and prove nothing.
    function test_helperDetectsAReachableFunction() public {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("isMarketRegistered(address)")), abi.encode(market)
        );
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(orderEngine).call(payload);
        assertTrue(ok, "a genuinely external function must be reachable");
    }

    function test_custodyEntryPointsAreNotExternallyCallable() public {
        address attacker = address(0xBAD);

        _assertUnreachable(
            "creditShares(address,address,uint8,uint256)",
            abi.encode(market, attacker, uint8(1), uint256(1e18))
        );
        _assertUnreachable(
            "debitShares(address,address,uint8,uint256)",
            abi.encode(market, attacker, uint8(1), uint256(1e18))
        );
        _assertUnreachable(
            "debitSharesBeforeDeadline(address,address,uint8,uint256)",
            abi.encode(market, attacker, uint8(1), uint256(1e18))
        );
        _assertUnreachable(
            "mintFromFiller(address,address,uint256)",
            abi.encode(market, attacker, uint256(1e18))
        );
        _assertUnreachable(
            "mergeFromFiller(address,address,uint256)",
            abi.encode(market, attacker, uint256(1e18))
        );
        _assertUnreachable(
            "deposit(address,address,uint256)", abi.encode(market, attacker, uint256(1e6))
        );
        _assertUnreachable(
            "withdraw(address,address,uint256)",
            abi.encode(market, attacker, uint256(1e6))
        );
        _assertUnreachable(
            "fillOrder(address,address,address,uint8,uint128,uint16,uint16,bool,bool)",
            abi.encode(
                market,
                attacker,
                attacker,
                uint8(1),
                uint128(1e18),
                uint16(600),
                uint16(400),
                false,
                false
            )
        );
    }

    /// Credit is the one that mints value from nothing, so pin it specifically:
    /// a direct call must not move the attacker's position.
    function test_creditSharesCannotBeUsedToMintPositions() public {
        address attacker = address(0xBAD);
        (uint256 yes0, uint256 no0) = orderEngine.getPosition(market, attacker);

        _assertUnreachable(
            "creditShares(address,address,uint8,uint256)",
            abi.encode(market, attacker, uint8(1), uint256(1_000_000e18))
        );

        (uint256 yes1, uint256 no1) = orderEngine.getPosition(market, attacker);
        assertEq(yes1, yes0, "no YES minted");
        assertEq(no1, no0, "no NO minted");
    }

    /// The old off-chain CLOB surface is gone too (ADR-0007), not merely unused.
    function test_signedOrderSurfaceIsGone() public {
        _assertUnreachable("setOperator(address,bool)", abi.encode(address(0xBAD), true));
        _assertUnreachable("invalidateNonces(uint256)", abi.encode(uint256(1)));
        _assertUnreachable("cancelSignedOrder(uint256)", abi.encode(uint256(1)));
    }
}
