// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";

/**
 * @title MockYieldStrategy
 * @notice Controllable IYieldStrategy mock for StableStaker unit tests. Holds REAL ERC20:
 *         deposit pulls via transferFrom, withdraw pays out via transfer. Tracks per-client
 *         principal and exposes a settable "value factor" (in basis points, 10000 = par) so
 *         totalBalanceOf can be pushed BELOW principalOf (underwater) or above par (yield).
 *
 * @dev Mirrors ERC4626YieldStrategy's accounting semantics that StableStaker depends on:
 *      - deposit pulls `amount` from msg.sender, credits clientBalances[token][recipient].
 *      - withdraw debits AND pays the SAME `recipient`; caps requested to available principal;
 *        decrements principal by the REQUESTED amount, pays out the VALUE of that principal
 *        (requested * valueFactor / 10000), so a below-par factor delivers a haircut and an
 *        above-par factor would (if it paid yield) deliver extra — but principal-capped redeem
 *        means a normal withdraw of `amount` at par returns exactly `amount`.
 *
 *      Client authorization mirrors the real strategy: deposit/withdraw require the caller to be
 *      an authorized client (set via setClient), so tests must authorize the staker in setUp.
 */
contract MockYieldStrategy is IYieldStrategy {
    using SafeERC20 for IERC20;

    address public owner;

    /// @notice Per-token, per-client principal (deposits only, no yield).
    mapping(address => mapping(address => uint256)) public principal;

    /// @notice Total principal per token across all clients.
    mapping(address => uint256) public totalPrincipal;

    /// @notice Authorized clients allowed to deposit/withdraw.
    mapping(address => bool) public clients;

    /// @notice Value factor in basis points. 10000 = par; <10000 = underwater; >10000 = yield.
    uint256 public valueFactorBps = 10_000;

    /// @notice Deposit slippage in basis points. 0 = full credit (default, preserves old behaviour).
    uint256 public depositSlippageBps;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyClient() {
        require(clients[msg.sender], "MockYieldStrategy: unauthorized");
        _;
    }

    // ============ TEST CONTROLS ============

    /// @notice Authorize/deauthorize a client (mirrors AYieldStrategy.setClient).
    function setClient(address client, bool _auth) external override {
        clients[client] = _auth;
    }

    /// @notice Set the value factor (basis points). 10000 = par, <10000 = below par, >10000 = above par.
    function setValueFactorBps(uint256 bps) external {
        valueFactorBps = bps;
    }

    /// @notice Set the deposit slippage (basis points). 0 = full credit; >0 books less than `amount`.
    function setDepositSlippageBps(uint256 bps) external {
        depositSlippageBps = bps;
    }

    // ============ IYieldStrategy CORE ============

    function deposit(address token, uint256 amount, address recipient)
        external
        override
        onlyClient
        returns (uint256 creditedPrincipal)
    {
        require(amount > 0, "MockYieldStrategy: amount=0");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount); // full amount pulled in
        creditedPrincipal = (amount * (10_000 - depositSlippageBps)) / 10_000;
        principal[token][recipient] += creditedPrincipal; // only the haircut is booked
        totalPrincipal[token] += creditedPrincipal;
        return creditedPrincipal;
    }

    function withdraw(address token, uint256 amount, address recipient) external override onlyClient {
        require(amount > 0, "MockYieldStrategy: amount=0");

        // Cap requested to available principal (mirrors ERC4626YieldStrategy).
        uint256 available = principal[token][recipient];
        if (amount > available) {
            amount = available;
        }

        // Mirror the ERC4626 redeem semantics: converting `amount` of assets to shares and back to
        // assets is an identity above par (yield stays as un-redeemed surplus, so the user gets back
        // exactly `amount`), but below par the holder's shares are only worth `principal * factor`, so
        // redeeming the requested principal delivers a proportional haircut. Model this as the value
        // of the requested principal capped at par: payout = min(amount, amount * factor / 10000).
        uint256 valued = (amount * valueFactorBps) / 10_000;
        uint256 payout = valued < amount ? valued : amount;

        // Decrement principal by the REQUESTED amount (any difference is protocol-owned yield/loss).
        principal[token][recipient] -= amount;
        totalPrincipal[token] -= amount;

        if (payout > 0) {
            IERC20(token).safeTransfer(recipient, payout);
        }
    }

    // ============ IYieldStrategy VIEWS ============

    function principalOf(address token, address account) external view override returns (uint256) {
        return principal[token][account];
    }

    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        return (principal[token][account] * valueFactorBps) / 10_000;
    }

    function balanceOf(address token, address account) external view override returns (uint256) {
        return principal[token][account];
    }

    // ============ IYieldStrategy UNUSED-BY-STAKER STUBS ============

    function emergencyWithdraw(uint256) external override {}

    function totalWithdrawal(address, address) external override {}

    function skimSurplus(address, address) external pure override returns (uint256) {
        return 0;
    }

    function getAuthorizedClients() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function setSetAsideBuffer(address, uint256) external override {}

    function setAsideBufferSize(address) external pure override returns (uint256) {
        return 0;
    }
}
