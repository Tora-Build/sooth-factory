// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {ReentrantToken} from "../mocks/HostileTokens.sol";

/// @dev Minimal ERC-1820 stand-in. Etched at the canonical registry address.
contract FakeERC1820 {
    mapping(address => mapping(bytes32 => address)) public implementer;

    function set(address account, bytes32 interfaceHash, address impl) external {
        implementer[account][interfaceHash] = impl;
    }

    function getInterfaceImplementer(address account, bytes32 interfaceHash)
        external
        view
        returns (address)
    {
        return implementer[account][interfaceHash];
    }
}

contract PausableProbeToken is ERC20 {
    bool public paused;

    constructor() ERC20("Pause probe", "PAUSE") {}

    function setPaused(bool value) external {
        paused = value;
    }
}

contract BlacklistProbeToken is ERC20 {
    mapping(address => bool) public isBlacklisted;

    constructor() ERC20("Blacklist probe", "BLIST") {}

    function setBlacklisted(address account, bool value) external {
        isBlacklisted[account] = value;
    }
}

/// @notice O-5. Admission is an allowlist. Probes reject the hazards they can
///         see. A custom transfer hook is still admitted, because bytecode
///         inspection cannot prove its absence.
contract TokenAdmissionGuardsTest is DualTokenBase {
    address internal constant ERC1820 = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

    function _ack() internal view returns (bytes32) {
        return marketFactory.TOKEN_RISK_ACKNOWLEDGEMENT();
    }

    /// Not a revoke. The two-argument call with `true` is the admission the
    /// function rejects. The call stays so that rejection remains tested.
    function test_AdmissionWithoutAcknowledgementReverts() public {
        PausableProbeToken token = new PausableProbeToken();
        vm.expectRevert(MarketFactory.TokenRiskUnacknowledged.selector);
        marketFactory.setTokenAllowed(address(token), true);
        assertFalse(marketFactory.allowedTokens(address(token)));
    }

    function test_WrongAcknowledgementReverts() public {
        PausableProbeToken token = new PausableProbeToken();
        vm.expectRevert(MarketFactory.TokenRiskUnacknowledged.selector);
        marketFactory.setTokenAllowed(address(token), true, bytes32(uint256(1)));
    }

    function test_PlainTokenIsAdmittedWithAcknowledgement() public {
        PausableProbeToken token = new PausableProbeToken();
        marketFactory.setTokenAllowed(address(token), true, _ack());
        assertTrue(marketFactory.allowedTokens(address(token)));
        marketFactory.setTokenAllowed(address(token), false);
        assertFalse(marketFactory.allowedTokens(address(token)));
    }

    function test_CurrentlyPausedTokenIsRejected() public {
        PausableProbeToken token = new PausableProbeToken();
        token.setPaused(true);
        bytes32 ack = _ack();
        vm.expectRevert(MarketFactory.TokenPaused.selector);
        marketFactory.setTokenAllowed(address(token), true, ack);
        token.setPaused(false);
        marketFactory.setTokenAllowed(address(token), true, _ack());
        assertTrue(marketFactory.allowedTokens(address(token)));
    }

    function test_TokenThatBlacklistsTheAmmIsRejected() public {
        BlacklistProbeToken token = new BlacklistProbeToken();
        token.setBlacklisted(address(amm), true);
        bytes32 ack = _ack();
        vm.expectRevert(MarketFactory.TokenBlacklisted.selector);
        marketFactory.setTokenAllowed(address(token), true, ack);
        token.setBlacklisted(address(amm), false);
        marketFactory.setTokenAllowed(address(token), true, _ack());
    }

    function test_RegisteredErc777TokenIsRejected() public {
        PausableProbeToken token = new PausableProbeToken();
        vm.etch(ERC1820, address(new FakeERC1820()).code);
        FakeERC1820(ERC1820).set(address(token), keccak256("ERC777Token"), address(token));
        bytes32 ack = _ack();
        vm.expectRevert(MarketFactory.TokenHasTransferHook.selector);
        marketFactory.setTokenAllowed(address(token), true, ack);
    }

    /// A hook that does not register as ERC-777 is not visible at admission.
    function test_CustomTransferHookIsNotDetected() public {
        ReentrantToken token = new ReentrantToken();
        marketFactory.setTokenAllowed(address(token), true, _ack());
        assertTrue(
            marketFactory.allowedTokens(address(token)),
            "custom hooks stay an admin acknowledgement, not a bytecode proof"
        );
    }
}
