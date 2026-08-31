// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockMinterYieldStrategy
 * @notice Minimal custody sink for {PhusdStableMinter}, which calls only `deposit` on the strategy
 *         it has registered for a stablecoin. Deliberately NOT the vault-RM `IYieldStrategy` this
 *         repo's {MockYieldStrategy} implements: the minter resolves its own copy of the interface
 *         whose `deposit` returns nothing, and it is a different actor entirely from the strategy
 *         that custodies StableStaker principal. Keeping the two mocks separate stops an
 *         AutoAnnihilate test from accidentally sharing custody between the staker and the minter.
 */
contract MockMinterYieldStrategy {
    using SafeERC20 for IERC20;

    /// @notice token => recipient => principal deposited.
    mapping(address => mapping(address => uint256)) public principal;

    function deposit(address token, uint256 amount, address recipient) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        principal[token][recipient] += amount;
    }

    function setClient(address, bool) external {}
}
