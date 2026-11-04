// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Badly-behaved ERC-20s for testing permissionless Token A.
/// @dev ADR-0006 made Token A permissionless on-chain and deleted TokenARegistry, so any
///      ERC-20 a creator picks reaches the engine's custody paths. Until these existed
///      the entire mock inventory was MockUSDC and MockMinimalAdjudicator — every
///      Token-A test ran on a well-behaved token, and the measured-receipt defences
///      (_collectExactTokenA, _requireTokenSolvent) were never exercised against
///      anything hostile.
///
///      These are deliberately minimal and each isolates ONE misbehaviour, so a failing
///      test names the property that broke.

/// @notice Takes a cut on every transfer: the recipient receives less than was sent.
/// @dev The classic exact-receipt breaker. Engine paths must measure the balance delta
///      and reject the shortfall rather than crediting the requested amount.
contract FeeOnTransferToken is ERC20 {
    uint256 public feeBps;

    constructor(uint256 feeBps_) ERC20("FeeOnTransfer", "FOT") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0xFEE), fee);
    }
}

/// @notice Transfers can be switched to revert, to prove failures roll back cleanly.
contract RevertingToken is ERC20 {
    bool public failTransfers;

    constructor() ERC20("Reverting", "RVT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!failTransfers || from == address(0), "TRANSFER_FAILED");
        super._update(from, to, value);
    }
}

/// @notice Calls an arbitrary target mid-transfer, the ERC-777/callback hazard.
/// @dev Set the target and calldata, then any transfer re-enters. Used to prove the
///      engine's guards hold when Token A hands control back during custody movement.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentered;
    bytes public lastReturnData;
    bool public lastCallSucceeded;

    constructor() ERC20("Reentrant", "RET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && target != address(0)) {
            // One shot: the callback must not recurse forever.
            armed = false;
            reentered = true;
            (bool ok, bytes memory data) = target.call(payload);
            lastCallSucceeded = ok;
            lastReturnData = data;
        }
    }
}

/// @notice Returns false instead of reverting, the pre-SafeERC20 hazard.
contract ReturnsFalseToken is ERC20 {
    bool public returnFalse;

    constructor() ERC20("ReturnsFalse", "RFT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReturnFalse(bool value) external {
        returnFalse = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        returns (bool)
    {
        if (returnFalse) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @notice A token that LIES about one address's balance, inflating it by a fixed
///         amount. Every other ERC-20 behaviour is honest.
/// @dev A *constant* over-report cancels in
///      `after - before`, so this mock does not by itself produce a false
///      deposit delta. It exists to keep that fact under test. The protocol
///      path — a withheld inbound transfer that still reports a receipt — is
///      `WithholdingReceiptToken` below. Admitting a Token A is an off-chain
///      curation decision; see the token trust section of SECURITY.md.
contract LyingBalanceToken is ERC20 {
    address public inflatedAccount;
    uint256 public inflation;

    constructor() ERC20("Lying balance token", "LIAR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Report `account`'s balance as `amount` higher than it really is.
    function lieAbout(address account, uint256 amount) external {
        inflatedAccount = account;
        inflation = amount;
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 real = super.balanceOf(account);
        return account == inflatedAccount ? real + inflation : real;
    }
}

/// @notice Withholds inbound transfers to a designated vault while reporting
///         that the tokens arrived. Outbound transfers stay honest.
/// @dev This is the T-1 protocol case: `notifyDeposit` credits the observed
///      delta, so a fabricated receipt can consume real fee cash pooled in the
///      same token. Not a defect to fix — a stated trust assumption.
contract WithholdingReceiptToken is ERC20 {
    address public vault;
    bool public lying;
    mapping(address => uint256) public phantom;

    constructor() ERC20("Withholding receipt", "WITH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setLying(bool value) external {
        lying = value;
    }

    function realBalanceOf(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + phantom[account];
    }

    function _update(address from, address to, uint256 value) internal override {
        if (lying && vault != address(0) && to == vault && from != address(0)) {
            phantom[to] += value;
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice Refuses transfers to or from specific addresses, the way a real
///         compliance-gated stablecoin does.
/// @dev Distinct from `RevertingToken`, whose switch is global: a blocklist breaks
///      ONE counterparty while the rest of the market keeps trading, which is the
///      shape that matters for a book that pushes collateral to third parties from
///      inside its matching loop. Used by
///      `test/integration/BlockedMakerDoS.t.sol`.
contract BlocklistToken is ERC20 {
    mapping(address => bool) public blocked;

    error Blocked(address account);

    constructor() ERC20("Blocklist token", "BLOCK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from], Blocked(from));
        require(!blocked[to], Blocked(to));
        super._update(from, to, value);
    }
}
