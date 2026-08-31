// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A plain, honest ERC4626 vault: OpenZeppelin's reference implementation with a donation
///         helper so a test can push the share price off 1:1.
/// @dev Deliberately NOT a bespoke mock. The defect this fixture exists to catch — the double
///      round-down in `ERC4626YieldStrategy._disposeShares` (`convertToShares` floors, then
///      `redeem` -> `convertToAssets` floors again) — only appears against a real ERC4626
///      implementation at a non-integral share price. A hand-written mock that returns exactly
///      what it was asked for defines the bug away, which is precisely how it reached review.
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Vault", "mVLT") {}

    /// @notice Accrue yield the way a real vault does: assets appear without shares being minted,
    ///         so the share price rises and stops being an integer multiple of the asset unit.
    function accrue(uint256 assets) external {
        // The caller must have approved this vault; the transfer is the donation itself.
        SafeERC20Lite.transferFrom(asset(), msg.sender, address(this), assets);
    }
}

/// @dev Minimal transferFrom helper used only by `accrue`. This saves nothing in bytecode terms —
///      OpenZeppelin's ERC4626, inherited above, already imports SafeERC20 — it just keeps the
///      donation path's return-data handling visible in this file.
library SafeERC20Lite {
    function transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "MockERC4626Vault: transferFrom failed");
    }
}
